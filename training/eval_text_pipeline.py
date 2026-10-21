"""Scores the full Pixora pipeline (detection + Text model + blending) on the eval_text banners.

Usage (from training/traiNNer-redux):
  .venv/bin/python ../eval_text_pipeline.py --pixora ../../Pixora/.build/release/pixora --models ../../Pixora/Models \
      [--label NAME] [--out DIR] [-- extra pixora flags]
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import eval_text as E  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pixora", required=True)
    ap.add_argument("--models", required=True)
    ap.add_argument("--label", default="pixora")
    ap.add_argument("--out", default=tempfile.mkdtemp(prefix="eval_pipe_"))
    ap.add_argument("rest", nargs="*")
    a = ap.parse_args()
    lr_dir, out_dir = os.path.join(a.out, "lr"), os.path.join(a.out, a.label)
    os.makedirs(lr_dir, exist_ok=True)
    os.makedirs(out_dir, exist_ok=True)
    gts = {}
    for font in E.FONTS:
        gt, mask = E.banner(font)
        E.web_copy(gt).save(os.path.join(lr_dir, f"{font[0]}.png"))
        gts[font[0]] = (gt, mask)
    env = dict(os.environ, PIXORA_MODELS=os.path.abspath(a.models))
    subprocess.run([a.pixora, lr_dir, "-m", "std", "--scale", "4", "-o", out_dir, "-f", "png", *a.rest],
                   env=env, check=True, capture_output=True)
    entries, sharp, psnr = [], [], []
    for name, (gt, mask) in gts.items():
        sr = Image.open(os.path.join(out_dir, f"{name}.png")).convert("RGB")
        ring = np.asarray(mask.filter(E.ImageFilter.MaxFilter(7)), np.float64) / 255
        sharp.append(E.gradient_energy(sr, ring) / E.gradient_energy(gt, ring))
        g, s_ = np.asarray(gt, np.float64), np.asarray(sr, np.float64)
        psnr.append(10 * np.log10(255 ** 2 / ((g - s_) ** 2).mean()))
        entries.append((a.label, sr))
    E.report(E.ocr_by_size(entries, out_dir), {a.label: (np.mean(psnr), np.mean(sharp))}, [a.label])


if __name__ == "__main__":
    main()
