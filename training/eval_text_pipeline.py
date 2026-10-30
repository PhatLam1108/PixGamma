"""Scores the full PixGamma pipeline (detection + Text model + blending) on the eval_text banners
(all 8 sampling phases, like eval_text.py).

Usage (from training/traiNNer-redux):
  .venv/bin/python ../eval_text_pipeline.py --pixgamma ../../PixGamma/.build/release/pixgamma --models ../../PixGamma/Models \
      [--label NAME] [--out DIR] [-- extra pixgamma flags]
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
    ap.add_argument("--pixgamma", required=True)
    ap.add_argument("--models", required=True)
    ap.add_argument("--label", default="pixgamma")
    ap.add_argument("--out", default=tempfile.mkdtemp(prefix="eval_pipe_"))
    ap.add_argument("rest", nargs="*")
    a = ap.parse_args()
    lr_dir, out_dir = os.path.join(a.out, "lr"), os.path.join(a.out, a.label)
    os.makedirs(lr_dir, exist_ok=True)
    os.makedirs(out_dir, exist_ok=True)
    cs = E.cases()
    for fname, p, gt, lr, ring in cs:
        lr.save(os.path.join(lr_dir, f"{fname}_{p}.png"))
    env = dict(os.environ, PIXGAMMA_MODELS=os.path.abspath(a.models))
    subprocess.run([a.pixgamma, lr_dir, "-m", "std", "--scale", "4", "-o", out_dir, "-f", "png", *a.rest],
                   env=env, check=True, capture_output=True)
    entries, sharp, psnr = [], [], []
    for fname, p, gt, lr, ring in cs:
        sr = E.unshift(Image.open(os.path.join(out_dir, f"{fname}_{p}.png")).convert("RGB"), *E.PHASES[p])
        sharp.append(E.gradient_energy(sr, ring) / E.gradient_energy(gt, ring))
        g, s_ = np.asarray(gt, np.float64), np.asarray(sr, np.float64)
        psnr.append(10 * np.log10(255 ** 2 / ((g - s_) ** 2).mean()))
        entries.append((a.label, sr))
    agg, marks = E.ocr_by_size(entries, out_dir)
    E.report(agg, {a.label: (np.mean(psnr), np.mean(sharp))}, [a.label], marks)


if __name__ == "__main__":
    main()
