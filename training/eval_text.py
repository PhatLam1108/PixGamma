"""Scores text models on small Vietnamese text (diacritics and stroke sharpness).

Renders held-out banners (sentences not in the training corpus) in five fonts at 1600 px,
makes the web copy the way thumbnails are made (/2 bicubic + blur + JPEG 60, then /2 again),
upscales 4x and reports, per model:
  ocr    share of characters Apple Vision reads correctly (language correction off,
         so the score reflects the glyphs, not the dictionary)
  psnr   against the 1600 px original
  sharp  gradient energy on text pixels / original (1.0 = as crisp as the original)

Usage (from training/traiNNer-redux):
  .venv/bin/python ../eval_text.py --model old=experiments/pixora_text/models/net_g_ema_latest.safetensors \
      --model new=experiments/pixora_text2/models/net_g_ema_latest.safetensors [--out DIR]
"""
import argparse
import io
import json
import os
import subprocess
import tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

from evaluate import load_model, run

ROOT = os.path.dirname(os.path.abspath(__file__))
SUP = "/System/Library/Fonts/Supplemental/"
FONTS = [("Arial", SUP + "Arial.ttf", SUP + "Arial Bold.ttf"),
         ("Verdana", SUP + "Verdana.ttf", SUP + "Verdana Bold.ttf"),
         ("Tahoma", SUP + "Tahoma.ttf", SUP + "Tahoma Bold.ttf"),
         ("Times", SUP + "Times New Roman.ttf", SUP + "Times New Roman Bold.ttf"),
         ("Trebuchet", SUP + "Trebuchet MS.ttf", SUP + "Trebuchet MS Bold.ttf")]
LINES = [  # (text, size at 1600 px, bold)
    ("Thời lượng pin lên đến 18 giờ", 48, False),
    ("Hỗ trợ trả trước 30%, nhận máy ngay", 40, True),
    ("• Màn hình cảm ứng xoay gập linh hoạt", 30, False),
    ("• Tặng kèm chuột không dây, túi chống sốc", 30, False),
    ("• Đổi mới miễn phí trong mười hai tháng", 30, False),
    ("Phiên bản giới hạn – quà tặng hấp dẫn", 24, False),
    ("Khám phá ngay hôm nay! Liên hệ tổng đài để được tư vấn kỹ hơn.", 20, False),
]
OCR_SWIFT = r'''
import Vision; import AppKit; import Foundation
func lev(_ a: [Character], _ b: [Character]) -> Int {
    if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
    var d = Array(0...b.count)
    for i in 1...a.count { var prev = d[0]; d[0] = i
        for j in 1...b.count { let t = d[j]; d[j] = min(d[j] + 1, d[j-1] + 1, prev + (a[i-1] == b[j-1] ? 0 : 1)); prev = t } }
    return d[b.count]
}
let jobs = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
for job in jobs {
    let path = job["image"] as! String, gt = job["lines"] as! [String]
    let img = NSImage(contentsOfFile: path)!; var r = CGRect(origin: .zero, size: img.size)
    let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil)!
    let req = VNRecognizeTextRequest(); req.recognitionLevel = .accurate
    req.recognitionLanguages = ["vi-VT", "en-US"]; req.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: cg).perform([req])
    let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    let errs = gt.map { g in min(lines.map { lev(Array($0), Array(g)) }.min() ?? g.count, g.count) }
    print("\(path)\t" + zip(gt, errs).map { "\($0.count - $1)/\($0.count)" }.joined(separator: ","))
}
'''


def faithful(lr, scale=4, iters=12, step=1.0, margin=0.04):
    """Sharpens without inventing shapes: iterative back-projection (the result, shrunk the
    way the web copy was, must give back the LR pixels) then each pixel is clamped to the
    range of its 3x3 LR neighbourhood, so no ring or halo can appear."""
    import torch
    import torch.nn.functional as F
    x0 = torch.from_numpy(np.asarray(lr, np.float32) / 255).permute(2, 0, 1)[None]
    H, W = x0.shape[-2] * scale, x0.shape[-1] * scale
    up = lambda t: F.interpolate(t, size=(H, W), mode="bicubic", align_corners=False)
    down = lambda t: F.interpolate(t, size=x0.shape[-2:], mode="bicubic", align_corners=False, antialias=True)
    x = up(x0)
    for _ in range(iters):
        x = x + step * up(x0 - down(x))
    lo = up(-F.max_pool2d(-x0, 3, 1, 1)) - margin
    hi = up(F.max_pool2d(x0, 3, 1, 1)) + margin
    x = torch.maximum(torch.minimum(x, hi), lo).clamp(0, 1)
    return Image.fromarray((x[0].permute(1, 2, 0).numpy() * 255).round().astype(np.uint8))


def banner(font):
    _, reg, bold = font
    W, H = 1600, 760
    im = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(im)
    for y in range(H):
        d.line([(0, y), (W, y)], fill=(int(20 + 30 * y / H), int(30 + 40 * y / H), int(70 + 90 * y / H)))
    mask = Image.new("L", (W, H))
    m = ImageDraw.Draw(mask)
    y = 50
    for text, size, b in LINES:
        f = ImageFont.truetype(bold if b else reg, size)
        col = (255, 210, 90) if b else (235, 240, 255)
        d.text((70, y), text, font=f, fill=col)
        m.text((70, y), text, font=f, fill=255)
        y += int(size * 1.75)
    return im, mask


def line_rows():
    """(text, size, top, bottom) of each line in the 1600 px banner."""
    rows, y = [], 50
    for text, size, _ in LINES:
        rows.append((text, size, max(0, y - int(0.3 * size)), y + int(1.45 * size)))
        y += int(size * 1.75)
    return rows


def ocr_by_size(entries, out):
    """OCR every line on its own crop (Vision reads a line differently depending on its
    neighbours, which made whole-banner scores jump for pixel-identical lines).
    entries: [(key, image at 1600 px)] -> {key: {size: [ok, total]}}"""
    jobs, meta = [], []
    for n, (key, im) in enumerate(entries):
        for k, (text, size, y0, y1) in enumerate(line_rows()):
            p = os.path.join(out, f"line_{n}_{k}.png")
            im.crop((0, y0, im.width, y1)).save(p)
            jobs.append({"image": p, "lines": [text]})
            meta.append((key, size))
    jf, sw = os.path.join(out, "jobs.json"), os.path.join(out, "ocr.swift")
    json.dump(jobs, open(jf, "w"), ensure_ascii=False)
    open(sw, "w").write(OCR_SWIFT)
    res = subprocess.run(["swift", sw, jf], capture_output=True, text=True, check=True).stdout.strip().splitlines()
    agg = {}
    for (key, size), line in zip(meta, res):
        ok, tot = map(int, line.split("\t")[1].split("/"))
        c = agg.setdefault(key, {}).setdefault(size, [0, 0]); c[0] += ok; c[1] += tot
    return agg


def report(agg, extra, names):
    sizes = sorted({sz for _, sz, _ in LINES})
    head = "".join(f"{f'{sz * 0.72 / 4:.1f}px':>8}" for sz in sizes)
    print(f"{'model':<14}{'ocr %':>7}{'psnr':>8}{'sharp':>7}   ocr theo cỡ chữ hoa ở ảnh nhỏ:{head}")
    for name in names:
        r = agg[name]
        ok, tot = sum(v[0] for v in r.values()), sum(v[1] for v in r.values())
        cols = "".join(f"{100 * r[sz][0] / r[sz][1]:>8.1f}" for sz in sizes)
        psnr, sharp = extra[name]
        print(f"{name:<14}{100 * ok / tot:>7.1f}{psnr:>8.2f}{sharp:>7.2f}   {'':>30}{cols}")


def web_copy(gt):
    a = gt.resize((gt.width // 2, gt.height // 2), Image.BICUBIC).filter(ImageFilter.GaussianBlur(0.6))
    buf = io.BytesIO()
    a.save(buf, "JPEG", quality=60)
    buf.seek(0)
    a = Image.open(buf).convert("RGB")
    return a.resize((gt.width // 4, gt.height // 4), Image.BICUBIC)


def gradient_energy(a, mask):
    y = np.asarray(a.convert("L"), np.float64)
    gx, gy = np.diff(y, axis=1)[:-1], np.diff(y, axis=0)[:, :-1]
    return float(((gx ** 2 + gy ** 2) * mask[:-1, :-1]).sum())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", action="append", default=[], help="name=path (bicubic is always included)")
    ap.add_argument("--out", default=tempfile.mkdtemp(prefix="eval_text_"))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    cases = []
    for font in FONTS:
        gt, mask = banner(font)
        # Text pixels plus a 3 px ring, where blur and halos show.
        ring = np.asarray(mask.filter(ImageFilter.MaxFilter(7)), np.float64) / 255
        cases.append((font[0], gt, web_copy(gt), ring))
        gt.save(os.path.join(a.out, f"{font[0]}_gt.png"))
    models = [("bicubic", None), ("faithful", "faithful")] + [tuple(m.split("=", 1)) for m in a.model]
    entries, extra = [], {}
    for name, path in models:
        net = load_model(path)[0] if path and path != "faithful" else None
        ps, shs = [], []
        for fname, gt, lr, ring in cases:
            if path == "faithful":
                sr = faithful(lr)
            else:
                sr = lr.resize(gt.size, Image.BICUBIC) if net is None else run(net, lr)
            sr.save(os.path.join(a.out, f"{fname}_{name}.png"))
            g, s_ = np.asarray(gt, np.float64), np.asarray(sr, np.float64)
            ps.append(10 * np.log10(255 ** 2 / ((g - s_) ** 2).mean()))
            shs.append(gradient_energy(sr, ring) / gradient_energy(gt, ring))
            entries.append((name, sr))
        extra[name] = (np.mean(ps), np.mean(shs))
    report(ocr_by_size(entries, a.out), extra, [n for n, _ in models])
    print(f"ảnh: {a.out}")


if __name__ == "__main__":
    main()
