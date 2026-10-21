"""Build a paired super-resolution dataset (HR crops + realistic LR copies) for traiNNer-redux.

Degradations follow docs/finetune-research.md section 3.4: they imitate product photos that
were resized and re-compressed for the web, kept mild so the model learns to keep real texture
and printed text instead of smoothing or inventing it.

Usage:
  uv run --with pillow --with numpy python training/prepare_dataset.py \
      --input ~/Pictures/laptop-originals --name laptop --copies 3

Output (all under training/datasets/<name>/):
  hr/<id>.png       512x512 ground-truth crops
  lr/<id>.png       128x128 degraded inputs (x4), one file per HR copy
"""
import argparse
import hashlib
import io
import os
import random
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter, ImageOps

ROOT = Path(__file__).resolve().parent
EXTS = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".webp", ".heic"}
CROP, STEP, SCALE = 512, 256, 4


def laplacian_variance(gray: np.ndarray) -> float:
    """Low values mean flat tiles (white backdrop, walls) that teach the model nothing."""
    g = gray.astype(np.float32)
    lap = -4 * g[1:-1, 1:-1] + g[:-2, 1:-1] + g[2:, 1:-1] + g[1:-1, :-2] + g[1:-1, 2:]
    return float(lap.var())


def degrade(hr: Image.Image, rng: random.Random) -> Image.Image:
    """One realistic LR copy of a 512 HR crop → 128 px."""
    img = hr
    # Mild optical blur on about half the samples (sigma <= 1.5 keeps glyphs recoverable).
    if rng.random() < 0.5:
        img = img.filter(ImageFilter.GaussianBlur(radius=rng.uniform(0.2, 1.5)))
    # Downscale with a random kernel, sometimes via an intermediate size.
    kernels = [Image.BICUBIC, Image.BILINEAR, Image.LANCZOS, Image.BOX]
    target = (CROP // SCALE, CROP // SCALE)
    if rng.random() < 0.3:
        mid = int(CROP / rng.uniform(1.5, 3.0))
        img = img.resize((mid, mid), rng.choice(kernels))
    img = img.resize(target, rng.choice(kernels))
    arr = np.asarray(img).astype(np.float32)
    # Light noise on fewer than half the samples (heavy noise teaches "plastic" skin).
    if rng.random() < 0.4:
        if rng.random() < 0.5:
            arr += np.random.default_rng(rng.randrange(1 << 30)).normal(0, rng.uniform(1, 8), arr.shape)
        else:
            lam = rng.uniform(0.05, 1.0) * 255
            nrng = np.random.default_rng(rng.randrange(1 << 30))
            arr = nrng.poisson(np.clip(arr, 0, 255) / 255 * lam) / lam * 255
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    # Web re-compression: JPEG, sometimes twice, sometimes WebP.
    def encode(im, fmt, q):
        buf = io.BytesIO()
        im.save(buf, fmt, quality=q)
        buf.seek(0)
        return Image.open(buf).convert("RGB")
    if rng.random() < 0.3:
        img = encode(img, "WEBP", rng.randint(60, 90))
    else:
        img = encode(img, "JPEG", rng.randint(50, 95))
        if rng.random() < 0.4:
            img = encode(img, "JPEG", rng.randint(70, 95))
    return img


def degrade_chain(hr: Image.Image, rng: random.Random) -> Image.Image:
    """Web copies are often scaled and re-compressed twice (original → article → thumbnail)."""
    def jpeg(im, q):
        buf = io.BytesIO()
        im.save(buf, "JPEG", quality=q)
        buf.seek(0)
        return Image.open(buf).convert("RGB")
    k = [Image.BICUBIC, Image.BILINEAR, Image.LANCZOS, Image.BOX]
    mid = hr.resize((CROP // 2, CROP // 2), rng.choice(k))
    if rng.random() < 0.6:
        mid = mid.filter(ImageFilter.GaussianBlur(rng.uniform(0.3, 0.9)))
    mid = jpeg(mid, rng.randint(45, 90))
    return jpeg(mid.resize((CROP // SCALE, CROP // SCALE), rng.choice(k)), rng.randint(60, 95))


def process(args):
    path, out_dir, copies, seed, min_var, chain = args
    try:
        im = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    except Exception as e:  # unreadable file: skip, report
        return path, 0, str(e)
    rng = random.Random(seed)
    # Shrink originals so GT is free of sensor noise and JPEG blocks.
    s = rng.uniform(0.5, 0.75)
    if min(im.size) * s >= CROP:
        im = im.resize((int(im.width * s), int(im.height * s)), Image.LANCZOS)
    if min(im.size) < CROP:
        return path, 0, "too small"
    stem = hashlib.sha1(str(path).encode()).hexdigest()[:10]
    gray = np.asarray(im.convert("L"))
    count = 0
    for y in range(0, im.height - CROP + 1, STEP):
        for x in range(0, im.width - CROP + 1, STEP):
            if laplacian_variance(gray[y:y + CROP, x:x + CROP]) < min_var:
                continue
            hr = im.crop((x, y, x + CROP, y + CROP))
            for c in range(copies):
                name = f"{stem}_{x}_{y}_{c}.png"
                hr.save(out_dir / "hr" / name, compress_level=1)
                lr = degrade_chain(hr, rng) if rng.random() < chain else degrade(hr, rng)
                lr.save(out_dir / "lr" / name, compress_level=1)
            count += 1
    return path, count, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", nargs="+", required=True, help="Folders of original photos")
    ap.add_argument("--name", required=True, help="Dataset name under training/datasets/")
    ap.add_argument("--copies", type=int, default=3, help="LR variants per HR crop")
    ap.add_argument("--min-var", type=float, default=40.0, help="Laplacian variance cutoff for flat tiles")
    ap.add_argument("--val", type=int, default=20, help="Images held out for validation")
    ap.add_argument("--seed", type=int, default=1108)
    ap.add_argument("--chain", type=float, default=0.0, help="Share of LR copies made by the two-step web chain")
    ap.add_argument("--exclude", help="Text file of file names to leave out (held-out test images, paintings)")
    a = ap.parse_args()

    skip = set(Path(a.exclude).read_text().split()) if a.exclude else set()
    files = sorted(p for d in a.input for p in Path(os.path.expanduser(d)).rglob("*")
                   if p.suffix.lower() in EXTS and p.name not in skip)
    if not files:
        sys.exit("Không tìm thấy ảnh nào.")
    random.Random(a.seed).shuffle(files)
    splits = {"val": files[:a.val], "train": files[a.val:]}
    for split, items in splits.items():
        out = ROOT / "datasets" / a.name / split
        (out / "hr").mkdir(parents=True, exist_ok=True)
        (out / "lr").mkdir(parents=True, exist_ok=True)
        jobs = [(p, out, 1 if split == "val" else a.copies, a.seed + i, a.min_var, a.chain) for i, p in enumerate(items)]
        total = 0
        with ProcessPoolExecutor() as ex:
            for path, n, err in ex.map(process, jobs, chunksize=4):
                total += n
                if err:
                    print(f"  bỏ qua {Path(path).name}: {err}")
        print(f"{split}: {len(items)} ảnh → {total} ô HR → {out}")


if __name__ == "__main__":
    main()
