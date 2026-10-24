"""Scores 4x models on fine textures: parrot feathers, hair, eyebrows, lips and skin.

Held-out CC0 crops (datasets/texture_eval, 384 px at the photo's own resolution, named
<category>_<n>_<source>.png; sources in datasets/raw_texture_eval/CREDITS.tsv). Three copies:
  clean4  /4 bicubic, upscaled 4x
  clean2  /2 bicubic, upscaled 4x then Lanczos /2 (PixGamma's 2x path)
  web4    /4 bicubic + JPEG 75, upscaled 4x
Per category and model: PSNR, DISTS (whole crop, lower = closer) and tex (Laplacian energy vs
the original, 1.0 = as much fine detail as the photo; above 1 is invented or amplified grain).

Usage (from training/traiNNer-redux):
  PYTHONPATH=.:.. .venv/bin/python ../eval_texture.py --model v3=experiments/.../net_g_ema_latest.safetensors \
      [--model ...] [--out DIR]
"""
import argparse
import glob
import io
import os
from collections import defaultdict

import numpy as np
import torch
from PIL import Image

import evaluate as E

ROOT = os.path.dirname(os.path.abspath(__file__))
CASES = ("clean4", "clean2", "web4")


def degrade(gt, case):
    f = 2 if case == "clean2" else 4
    lr = gt.resize((gt.width // f, gt.height // f), Image.BICUBIC)
    if case == "web4":
        buf = io.BytesIO()
        lr.save(buf, "JPEG", quality=75)
        lr = Image.open(io.BytesIO(buf.getvalue())).convert("RGB")
    return lr


def dists_whole(a, b):
    E.dists(a[:256, :256], b[:256, :256])  # builds the DISTS model
    ta = torch.from_numpy(a).permute(2, 0, 1)[None].float().div(255).to(E.DEV)
    tb = torch.from_numpy(b).permute(2, 0, 1)[None].float().div(255).to(E.DEV)
    with torch.inference_mode():
        return float(E._dists(ta, tb).mean())


def score(out, gt):
    o = np.asarray(out.convert("RGB"))[4:-4, 4:-4]
    g = np.asarray(gt)[4:-4, 4:-4]
    mse = ((o.astype(np.float64) - g) ** 2).mean()
    return (10 * np.log10(255 ** 2 / max(mse, 1e-6)), dists_whole(o, g),
            E.hf_energy(E.luma(o)) / max(E.hf_energy(E.luma(g)), 1e-6))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", action="append", default=[], help="name=path (4x)")
    ap.add_argument("--test", default=os.path.join(ROOT, "datasets.nosync", "texture_eval"))
    ap.add_argument("--out", help="save every output here (<case>/<model>/<crop>.png)")
    a = ap.parse_args()
    crops = sorted(glob.glob(os.path.join(a.test, "*.png")))
    gts = {os.path.basename(p)[:-4]: Image.open(p).convert("RGB") for p in crops}
    res = defaultdict(list)  # (case, cat, model) -> [(psnr, dists, tex)]
    models = [("bicubic", None)] + [m.split("=", 1) for m in a.model]
    for name, path in models:
        net = E.load_model(path)[0] if path else None
        for case in CASES:
            for n, gt in gts.items():
                lr = degrade(gt, case)
                if net is None:
                    out = lr.resize(gt.size, Image.BICUBIC)
                else:
                    out = E.run(net, lr, scale=4)
                    if out.size != gt.size:
                        out = out.resize(gt.size, Image.LANCZOS)
                if a.out:
                    d = os.path.join(a.out, case, name)
                    os.makedirs(d, exist_ok=True)
                    out.save(os.path.join(d, n + ".png"))
                res[(case, n.split("_")[0], name)].append(score(out, gt))
        print(f"done {name}", flush=True)
    cats = sorted({k[1] for k in res})
    names = [m[0] for m in models]
    for case in CASES:
        print(f"\n== {case}   PSNR / DISTS / tex")
        print(f"{'model':14}" + "".join(f"{c:>24}" for c in cats + ['all']))
        for name in names:
            cells, allv = [], []
            for c in cats:
                v = res[(case, c, name)]
                allv += v
                p, d, t = np.mean(v, 0)
                cells.append(f"{p:6.2f} / {d:.3f} / {t:4.2f}")
            p, d, t = np.mean(allv, 0)
            cells.append(f"{p:6.2f} / {d:.3f} / {t:4.2f}")
            print(f"{name:14}" + "".join(f"{s:>24}" for s in cells))


if __name__ == "__main__":
    main()
