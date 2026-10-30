"""Scores text models on small Vietnamese text (diacritics and stroke sharpness).

Renders held-out banners (sentences not in the training corpus) in five fonts at 1600 px,
makes the web copy the way thumbnails are made (/2 bicubic + blur + JPEG 60, then /2 again) at 8 sampling
phases (scores pooled over all: one phase alone swings by several points),
upscales 4x and reports, per model:
  ocr    share of characters Apple Vision reads correctly (language correction off,
         so the score reflects the glyphs, not the dictionary)
  psnr   against the 1600 px original
  dấu    share of marked letters (ă â ê ô ơ ư đ and the five tones) read exactly, marks included
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
import unicodedata

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

from evaluate import load_model, run

ROOT = os.path.dirname(os.path.abspath(__file__))
SUP = "/System/Library/Fonts/Supplemental/"
FONTS = [("Arial", SUP + "Arial.ttf", SUP + "Arial Bold.ttf"),
         ("Verdana", SUP + "Verdana.ttf", SUP + "Verdana Bold.ttf"),
         ("Tahoma", SUP + "Tahoma.ttf", SUP + "Tahoma Bold.ttf"),
         ("Times", SUP + "Times New Roman.ttf", SUP + "Times New Roman Bold.ttf"),
         ("Georgia", SUP + "Georgia.ttf", SUP + "Georgia Bold.ttf")]  # not Trebuchet MS: it has no Vietnamese glyphs (boxes)
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
    let best = gt.first.map { g in lines.min { lev(Array($0), Array(g)) < lev(Array($1), Array(g)) } ?? "" } ?? ""
    print("\(path)\t" + zip(gt, errs).map { "\($0.count - $1)/\($0.count)" }.joined(separator: ",") + "\t" + best)
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


def strip_marks(t):
    """Base letters only: 'Thời lượng' -> 'Thoi luong' (đ -> d)."""
    t = unicodedata.normalize("NFD", t).replace("đ", "d").replace("Đ", "D")
    return "".join(c for c in t if not unicodedata.combining(c))


def mark_errors(gt, read):
    """(marked letters of gt not read exactly, marked letters in gt). Letters are aligned by edit
    distance; a marked letter (ă â ê ô ơ ư đ or a tone) counts only if read with the same base
    and the same marks, so 'lượng' read 'luợng' or 'lương' fails, and so does a lost word."""
    n, m = len(gt), len(read)
    d = [[i + j if i * j == 0 else 0 for j in range(m + 1)] for i in range(n + 1)]
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (gt[i - 1] != read[j - 1]))
    ok, i, j = set(), n, m
    while i and j:
        if d[i][j] == d[i - 1][j - 1] + (gt[i - 1] != read[j - 1]):
            if gt[i - 1] == read[j - 1]:
                ok.add(i - 1)
            i, j = i - 1, j - 1
        elif d[i][j] == d[i - 1][j] + 1:
            i -= 1
        else:
            j -= 1
    marked = [k for k, c in enumerate(gt) if strip_marks(c) != c]
    return sum(1 for k in marked if k not in ok), len(marked)


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
    agg, marks = {}, {}
    for (key, size), line, job in zip(meta, res, jobs):
        f = line.split("\t")
        ok, tot = map(int, f[1].split("/"))
        c = agg.setdefault(key, {}).setdefault(size, [0, 0]); c[0] += ok; c[1] += tot
        e, n = mark_errors(job["lines"][0], f[2] if len(f) > 2 else "")
        m = marks.setdefault(key, [0, 0]); m[0] += e; m[1] += n
    return agg, marks


def report(agg, extra, names, marks):
    sizes = sorted({sz for _, sz, _ in LINES})
    head = "".join(f"{f'{sz * 0.72 / 4:.1f}px':>8}" for sz in sizes)
    print(f"{'model':<14}{'ocr %':>7}{'dấu %':>7}{'psnr':>8}{'sharp':>7}   ocr theo cỡ chữ hoa ở ảnh nhỏ:{head}")
    for name in names:
        r = agg[name]
        ok, tot = sum(v[0] for v in r.values()), sum(v[1] for v in r.values())
        cols = "".join(f"{100 * r[sz][0] / r[sz][1]:>8.1f}" for sz in sizes)
        psnr, sharp = extra[name]
        e, n = marks[name]
        print(f"{name:<14}{100 * ok / tot:>7.1f}{100 * (1 - e / n):>7.1f}{psnr:>8.2f}{sharp:>7.2f}   {'':>30}{cols}")


def web_copy(gt):
    a = gt.resize((gt.width // 2, gt.height // 2), Image.BICUBIC).filter(ImageFilter.GaussianBlur(0.6))
    buf = io.BytesIO()
    a.save(buf, "JPEG", quality=60)
    buf.seek(0)
    a = Image.open(buf).convert("RGB")
    return a.resize((gt.width // 4, gt.height // 4), Image.BICUBIC)


# Sampling phases (dx, dy) of the 1600 px original before the web copy is made. On one phase a
# change of a fraction of a dB flipped Vision's reading of enough marks to swing "dấu" by 3 points
# (range 6 points over these 8 phases for the same model), so every score is pooled over all 8.
PHASES = [(0, 0), (1, 0), (2, 0), (3, 0), (0, 1), (0, 2), (1, 3), (2, 2)]


def shift(im, dx, dy):
    """Moves the image right/down by (dx, dy), repeating the edge."""
    a = np.pad(np.asarray(im), ((dy, 0), (dx, 0), (0, 0)), mode="edge")[:im.height, :im.width]
    return Image.fromarray(a)


def unshift(im, dx, dy):
    """Undoes `shift` on an upscaled result so the line crops line up with the original."""
    a = np.pad(np.asarray(im), ((0, dy), (0, dx), (0, 0)), mode="edge")[dy:, dx:]
    return Image.fromarray(a)


def cases():
    """[(name, phase, gt, web copy, ring)] for every font and sampling phase."""
    out = []
    for font in FONTS:
        gt, mask = banner(font)
        # Text pixels plus a 3 px ring, where blur and halos show.
        ring = np.asarray(mask.filter(ImageFilter.MaxFilter(7)), np.float64) / 255
        for p, (dx, dy) in enumerate(PHASES):
            out.append((font[0], p, gt, web_copy(shift(gt, dx, dy)), ring))
    return out


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
    cs = cases()
    for fname, p, gt, *_ in cs:
        if p == 0:
            gt.save(os.path.join(a.out, f"{fname}_gt.png"))
    models = [("bicubic", None), ("faithful", "faithful")] + [tuple(m.split("=", 1)) for m in a.model]
    entries, extra = [], {}
    for name, path in models:
        net = load_model(path)[0] if path and path != "faithful" else None
        ps, shs = [], []
        for fname, p, gt, lr, ring in cs:
            if path == "faithful":
                sr = faithful(lr)
            else:
                sr = lr.resize(gt.size, Image.BICUBIC) if net is None else run(net, lr)
            dx, dy = PHASES[p]
            sr = unshift(sr, dx, dy)
            if p == 0:
                sr.save(os.path.join(a.out, f"{fname}_{name}.png"))
            g, s_ = np.asarray(gt, np.float64), np.asarray(sr, np.float64)
            ps.append(10 * np.log10(255 ** 2 / ((g - s_) ** 2).mean()))
            shs.append(gradient_energy(sr, ring) / gradient_energy(gt, ring))
            entries.append((name, sr))
        extra[name] = (np.mean(ps), np.mean(shs))
    agg, marks = ocr_by_size(entries, a.out)
    report(agg, extra, [n for n, _ in models], marks)
    print(f"ảnh: {a.out}")


if __name__ == "__main__":
    main()
