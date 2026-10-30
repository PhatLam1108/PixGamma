"""Visual report for a training round: whole photo plus zoomed crops where two models differ most.

For each held-out case the photo is cut to 1600 px wide, downscaled 4 times (clean: bicubic; web: bicubic +
JPEG 75; thumb: the eval_text.py web copy), upscaled 4x by every model, and laid out as one sheet:
  top row     whole result per model and the original, yellow boxes on the zoomed areas
  bottom row  the boxes enlarged (crop 200 px shown at 2x)
The boxes are picked automatically where the last two --model entries (old, new) differ most.
--set text uses Vietnamese banners from eval_text.py and held-out sign photos instead of the texture cases.

Usage (from training/traiNNer-redux):
  PYTHONPATH=.:.. .venv/bin/python ../compare_sheets.py --model "Photo v6=experiments/.../net_g_ema_12000.safetensors" \
      --model "Photo v7=experiments/.../net_g_ema_latest.safetensors" [--extra "UltraSharpV2=..."] --out DIR
"""
import argparse
import io
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

import eval_text as T
import evaluate as E

ROOT = os.path.dirname(os.path.abspath(__file__))
D = os.path.join(ROOT, "datasets.nosync")
SAMPLES = os.path.join(os.path.dirname(ROOT), "docs", "samples", "source")
CASES = [  # name, file, degradation
    ("vet-do", f"{D}/raw_texture_eval/006.jpg", "clean"),
    ("toc-dai", f"{D}/raw_texture_eval/053.jpg", "clean"),
    ("long-may-da", f"{D}/raw_texture_eval/049.jpg", "clean"),
    ("mat-long-mi", f"{D}/raw_texture_eval/021.jpg", "clean"),
    ("vet-xanh", f"{D}/raw_texture_eval/005.jpg", "clean"),
    ("meo", f"{SAMPLES}/cat.jpg", "clean"),
    ("bien-chu", f"{SAMPLES}/sign.jpg", "clean"),
    ("vet-do-web", f"{D}/raw_texture_eval/006.jpg", "web"),
    ("toc-dai-web", f"{D}/raw_texture_eval/053.jpg", "web"),
]
TEXT_CASES = [  # name, file or banner:<font>, degradation, crop (fractions of the photo)
    ("banner-arial", "banner:Arial", "thumb"),
    ("banner-times", "banner:Times", "thumb"),
    ("bang-xanh", f"{D}/raw_text_eval/022.jpg", "clean", (0.15, 0.1, 0.95, 0.7)),
    ("bang-xanh-web", f"{D}/raw_text_eval/022.jpg", "web", (0.15, 0.1, 0.95, 0.7)),
    ("thong-bao", f"{D}/raw_text_eval/043.jpg", "clean", (0.25, 0.25, 0.85, 0.95)),
    ("bien-hieu", f"{D}/raw_text_eval/050.jpg", "clean", (0.0, 0.3, 1.0, 0.65)),
    ("bang-den", f"{D}/raw_text_eval/054.jpg", "clean"),
    ("nhan-dan", f"{D}/raw_text_eval/060.jpg", "clean", (0.1, 0.1, 0.9, 0.95)),
]
CROP, ZOOM, W = 200, 2, 1600
FONT = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 22)


def degrade(gt, kind):
    if kind == "thumb":  # eval_text.py web copy: /2 + blur + JPEG 60, /2 again
        return T.web_copy(gt)
    lr = gt.resize((gt.width // 4, gt.height // 4), Image.BICUBIC)
    if kind == "web":
        buf = io.BytesIO()
        lr.save(buf, "JPEG", quality=75)
        lr = Image.open(io.BytesIO(buf.getvalue())).convert("RGB")
    return lr


def pick_boxes(a, b, n=2):
    """Top-n non-overlapping CROP windows by mean |a-b| (luma, slightly blurred)."""
    d = np.abs(E.luma(np.asarray(a)) - E.luma(np.asarray(b)))
    d = np.asarray(Image.fromarray(np.clip(d * 8, 0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(6))).astype(float)
    h, w = d.shape
    ii = np.pad(d, ((1, 0), (1, 0))).cumsum(0).cumsum(1)
    s = ii[CROP:, CROP:] - ii[:-CROP, CROP:] - ii[CROP:, :-CROP] + ii[:-CROP, :-CROP]
    boxes = []
    for _ in range(n):
        y, x = np.unravel_index(np.argmax(s), s.shape)
        boxes.append((int(x), int(y)))
        s[max(0, y - CROP):y + CROP, max(0, x - CROP):x + CROP] = -1
    return boxes


def sheet(cols, boxes, title):
    """cols: [(label, image, highlight)] all W wide."""
    n = len(cols)
    cw = 470
    th = round(cols[0][1].height * cw / W)
    zw = (cw - 10) // 2
    out = Image.new("RGB", (10 + n * (cw + 10), 44 + th + 10 + zw + 10), (14, 16, 22))
    d = ImageDraw.Draw(out)
    d.text((10, 10), title, fill=(160, 170, 180), font=FONT)
    for j, (lab, im, hi) in enumerate(cols):
        x0 = 10 + j * (cw + 10)
        t = im.resize((cw, th), Image.LANCZOS)
        dd = ImageDraw.Draw(t)
        for bx, by in boxes:
            dd.rectangle([bx * cw / W, by * cw / W, (bx + CROP) * cw / W, (by + CROP) * cw / W], outline=(255, 210, 0), width=2)
        out.paste(t, (x0, 44))
        lw = d.textlength(lab, font=FONT)
        d.rectangle([x0, 44, x0 + lw + 16, 44 + 32], fill=(58, 210, 240) if hi else (20, 24, 30))
        d.text((x0 + 8, 48), lab, fill=(6, 8, 11) if hi else (240, 240, 245), font=FONT)
        for i, (bx, by) in enumerate(boxes):
            c = im.crop((bx, by, bx + CROP, by + CROP)).resize((zw, zw), Image.LANCZOS)
            out.paste(c, (x0 + i * (zw + 10), 44 + th + 10))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", action="append", required=True, help='"Label=path"; the last two are old, new')
    ap.add_argument("--extra", action="append", default=[], help='"Label=path" shown after new (e.g. UltraSharpV2)')
    ap.add_argument("--out", required=True)
    ap.add_argument("--set", choices=["photo", "text"], default="photo")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    specs = [m.split("=", 1) for m in a.model + a.extra]
    nets = {lab: E.load_model(p)[0] for lab, p in specs}
    old, new = specs[len(a.model) - 2][0], specs[len(a.model) - 1][0]
    for name, f, kind, *crop in (TEXT_CASES if a.set == "text" else CASES):
        if f.startswith("banner:"):
            im = T.banner(next(x for x in T.FONTS if x[0] == f[7:]))[0]
        elif os.path.exists(f):
            im = Image.open(f).convert("RGB")
        else:
            print("skip", name)
            continue
        if crop:
            x0, y0, x1, y1 = crop[0]
            im = im.crop((round(x0 * im.width), round(y0 * im.height), round(x1 * im.width), round(y1 * im.height)))
        gt = im.resize((W, round(im.height * W / im.width) // 4 * 4), Image.LANCZOS)
        lr = degrade(gt, kind)
        outs = {lab: E.run(net, lr, scale=4).resize(gt.size, Image.LANCZOS) for lab, net in nets.items()}
        boxes = pick_boxes(outs[old], outs[new])
        cols = [(lab, outs[lab], lab == new) for lab, _ in specs] + [("Ảnh gốc", gt, False)]
        deg = {"web": "nén JPEG 75", "thumb": "ảnh thu nhỏ, mờ, JPEG 60"}.get(kind, "sạch")
        title = f"{name} · ảnh vào {lr.width} px ({deg}) → 4x · khung vàng: chỗ {old} và {new} khác nhau nhiều nhất"
        sheet(cols, boxes, title).save(os.path.join(a.out, f"{name}.jpg"), quality=90)
        print(name, flush=True)


if __name__ == "__main__":
    main()
