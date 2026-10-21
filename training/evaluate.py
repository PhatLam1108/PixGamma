"""Score Pixora photo models against the acceptance bar on held-out images.

Two scenarios per test image (GT = clean image, long side 1024):
  4x  web copy: GT /4 bicubic + JPEG q80        -> 4x model                 -> compare GT
  2x  web copy: GT /2 bicubic + JPEG q85        -> 4x model, Lanczos /2    -> compare GT
                (2x reference: 2xNomosUni SPAN, the current Standard 2x default)

Metrics (lower DISTS = closer texture to the real photo):
  psnr, dists, hf (high-frequency energy / GT; 1.0 = same amount of fine detail,
  <1 plastic, >1 over-sharpened), dY (mean luma shift), dYdark (shift where GT luma < 60).

Usage (from training/traiNNer-redux):
  .venv/bin/python ../evaluate.py --test ../datasets/test_src \
      --model base=../../tools/weights/4xNomosWebPhoto_RealPLKSR.pth \
      --model tuned=experiments/<run>/models/net_g_ema_latest.safetensors
"""
import argparse
import glob
import io
import json
import os
import warnings

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image

warnings.filterwarnings("ignore")
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
DEV = "mps" if torch.backends.mps.is_available() else "cpu"
ROOT = os.path.dirname(os.path.abspath(__file__))
SPAN_2X = os.path.join(ROOT, "..", "tools", "weights", "2xNomosUni_span_multijpg_ldl.pth")


def load_model(path):
    import spandrel
    d = spandrel.ModelLoader().load_from_file(path)
    return d.model.eval().to(DEV), d.scale


def web_copy(gt: Image.Image, factor: int, q: int) -> Image.Image:
    lr = gt.resize((gt.width // factor, gt.height // factor), Image.BICUBIC)
    buf = io.BytesIO()
    lr.save(buf, "JPEG", quality=q)
    buf.seek(0)
    return Image.open(buf).convert("RGB")


def to_t(im):
    return torch.from_numpy(np.asarray(im)).permute(2, 0, 1)[None].float().div(255).to(DEV)


@torch.inference_mode()
def run(model, lr, tile=192, pad=16, scale=4):
    """Tiled inference with context padding, like Pixora's TileEngine."""
    x = to_t(lr)
    _, _, h, w = x.shape
    out = torch.zeros(1, 3, h * scale, w * scale, device=DEV)
    for y in range(0, h, tile):
        for x0 in range(0, w, tile):
            y1, x1 = min(y + tile, h), min(x0 + tile, w)
            ya, xa = max(y - pad, 0), max(x0 - pad, 0)
            yb, xb = min(y1 + pad, h), min(x1 + pad, w)
            o = model(x[..., ya:yb, xa:xb]).clamp(0, 1)
            out[..., y * scale:y1 * scale, x0 * scale:x1 * scale] = \
                o[..., (y - ya) * scale:(y1 - ya) * scale, (x0 - xa) * scale:(x1 - xa) * scale]
    arr = (out[0].permute(1, 2, 0).cpu().numpy() * 255).round().clip(0, 255).astype(np.uint8)
    return Image.fromarray(arr)


def luma(a):
    a = a.astype(np.float64)
    return 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]


def hf_energy(y):
    lap = -4 * y[1:-1, 1:-1] + y[:-2, 1:-1] + y[2:, 1:-1] + y[1:-1, :-2] + y[1:-1, 2:]
    return float((lap ** 2).mean())


_dists = None


def dists(a, b):
    global _dists
    if _dists is None:
        from traiNNer.losses.dists_loss import DISTSLoss
        _dists = DISTSLoss(loss_weight=1.0, as_loss=False).to(DEV).eval()
    vals = []
    with torch.inference_mode():
        for y in range(0, a.shape[0] - 255, 256):
            for x in range(0, a.shape[1] - 255, 256):
                ta = torch.from_numpy(a[y:y + 256, x:x + 256]).permute(2, 0, 1)[None].float().div(255).to(DEV)
                tb = torch.from_numpy(b[y:y + 256, x:x + 256]).permute(2, 0, 1)[None].float().div(255).to(DEV)
                vals.append(float(_dists(ta, tb).mean()))
    return float(np.mean(vals))


def score(out: Image.Image, gt: Image.Image):
    o = np.asarray(out.convert("RGB"))[4:-4, 4:-4]
    g = np.asarray(gt)[4:-4, 4:-4]
    mse = ((o.astype(np.float64) - g) ** 2).mean()
    yo, yg = luma(o), luma(g)
    dark = yg < 60
    return {
        "psnr": 10 * np.log10(255 ** 2 / mse),
        "dists": dists(o, g),
        "hf": hf_energy(yo) / max(hf_energy(yg), 1e-6),
        "dY": float((yo - yg).mean()),
        "dYdark": float((yo - yg)[dark].mean()) if dark.mean() > 0.01 else 0.0,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--test", required=True)
    ap.add_argument("--model", action="append", required=True, help="name=path (any spandrel 2x/4x model)")
    ap.add_argument("--save", help="folder to write outputs for visual checks")
    ap.add_argument("--json", help="write per-model averages here")
    a = ap.parse_args()

    files = sorted(glob.glob(os.path.join(a.test, "*.jpg")) + glob.glob(os.path.join(a.test, "*.png")))
    gts = []
    for f in files:
        im = Image.open(f).convert("RGB")
        s = min(1.0, 1024 / max(im.size))  # never enlarge the reference
        im = im.resize((int(im.width * s) // 4 * 4, int(im.height * s) // 4 * 4), Image.LANCZOS)
        gts.append((os.path.splitext(os.path.basename(f))[0], im))

    models = [(n, *load_model(p)) for n, p in (m.split("=", 1) for m in a.model)]
    span, _ = load_model(SPAN_2X)
    results = {}
    for name, model, scale in models + [("span2x", span, 2)]:
        rows = {"4x": [], "2x": []}
        for stem, gt in gts:
            for sc, (factor, q) in (("4x", (4, 80)), ("2x", (2, 85))):
                if scale == 2 and sc == "4x":  # 2x models are scored on the 2x case only
                    continue
                lr = web_copy(gt, factor, q)
                out = run(model, lr, scale=scale)
                if out.size != gt.size:
                    out = out.resize(gt.size, Image.LANCZOS)
                rows[sc].append(score(out, gt))
                if a.save:
                    os.makedirs(os.path.join(a.save, name), exist_ok=True)
                    out.save(os.path.join(a.save, name, f"{stem}_{sc}.png"), compress_level=1)
        results[name] = {sc: {k: float(np.mean([r[k] for r in v])) for k in v[0]} for sc, v in rows.items() if v}

    print(f"{'model':<14}{'case':<5}{'PSNR':>8}{'DISTS':>8}{'HF':>7}{'dY':>7}{'dYdark':>8}")
    for name, by in results.items():
        for sc, m in by.items():
            print(f"{name:<14}{sc:<5}{m['psnr']:8.2f}{m['dists']:8.4f}{m['hf']:7.2f}{m['dY']:7.2f}{m['dYdark']:8.2f}")
    if a.json:
        json.dump(results, open(a.json, "w"), indent=2)


if __name__ == "__main__":
    main()
