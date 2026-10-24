"""Download CC0 / public-domain photos from Wikimedia Commons for training.

Searches File: pages, keeps only CC0 or public-domain images at least --min-side px on the
short side, skips anything already in the output folder's CREDITS.tsv, and appends one
credit line per file (name, license, author, page title), same format as raw_cc0.

  uv run --with pillow --with requests python training/fetch_commons.py \
      --out training/datasets/raw_laptop --per-query 60 "laptop keyboard" "MacBook" ...
"""
import argparse
import html
import io
import os
import re
import time

import requests
from PIL import Image

API = "https://commons.wikimedia.org/w/api.php"
UA = {"User-Agent": "PixGammaTraining/0.2 (https://github.com/PhatLam1108/PixGamma) python-requests"}
# Structured-data licence filters: CC0 (P275=Q6938433) and public domain (P6216=Q19652).
LICENSES = ["haswbstatement:P275=Q6938433", "haswbstatement:P6216=Q19652"]
OK = re.compile(r"^(cc0|cc-zero|public domain|pd\b|pdm)", re.I)


def search(query, limit, width):
    # Originals answer 429 to scripts; the thumbnail service (iiurlwidth) is allowed.
    params = {"action": "query", "format": "json", "generator": "search", "gsrnamespace": 6,
              "gsrsearch": f"{query} filetype:bitmap", "gsrlimit": min(50, limit),
              "prop": "imageinfo", "iiprop": "url|size|extmetadata|mime", "iiurlwidth": width}
    got, cont = [], {}
    while len(got) < limit:
        r = requests.get(API, params={**params, **cont}, headers=UA, timeout=30).json()
        got += list(r.get("query", {}).get("pages", {}).values())
        if "continue" not in r:
            break
        cont = r["continue"]
    return got[:limit]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--per-query", type=int, default=50)
    ap.add_argument("--min-side", type=int, default=1200)
    ap.add_argument("--max-side", type=int, default=3000, help="thumbnail width requested")
    ap.add_argument("--skip", action="append", default=[], help="other CREDITS.tsv whose files to skip")
    ap.add_argument("queries", nargs="+")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    cred = os.path.join(a.out, "CREDITS.tsv")
    seen = set()
    if os.path.exists(cred):
        seen = {l.split("\t")[3].strip() for l in open(cred, encoding="utf-8") if l.count("\t") >= 3}
    n = len(seen)
    for other in a.skip:
        seen |= {l.split("\t")[3].strip() for l in open(other, encoding="utf-8") if l.count("\t") >= 3}
    for q in a.queries:
        kept = 0
        pages = [p for lic in LICENSES for p in search(f"{q} {lic}", a.per_query, a.max_side)]
        for p in pages:
            title = p.get("title", "")
            ii = (p.get("imageinfo") or [{}])[0]
            meta = ii.get("extmetadata", {})
            lic = html.unescape(re.sub("<[^>]+>", "", meta.get("LicenseShortName", {}).get("value", ""))).strip()
            if title in seen or not OK.match(lic) or ii.get("mime") not in ("image/jpeg", "image/png"):
                continue
            if min(ii.get("width", 0), ii.get("height", 0)) < a.min_side:
                continue
            try:
                resp = requests.get(ii.get("thumburl") or ii["url"], headers=UA, timeout=60)
                resp.raise_for_status()
                data = resp.content
                im = Image.open(io.BytesIO(data)).convert("RGB")
            except Exception as e:  # noqa: BLE001 - skip unreadable files
                print("skip", title, e)
                continue
            if max(im.size) > a.max_side:
                im.thumbnail((a.max_side, a.max_side), Image.LANCZOS)
            n += 1
            name = f"{n:03d}.jpg"
            im.save(os.path.join(a.out, name), quality=95)
            author = html.unescape(re.sub("<[^>]+>", "", meta.get("Artist", {}).get("value", "unknown"))).strip()
            with open(cred, "a", encoding="utf-8") as f:
                f.write(f"{name}\t{lic}\t{author[:80]}\t{title}\n")
            seen.add(title)
            kept += 1
            time.sleep(0.5)
        print(f"{q}: +{kept}")
    print("total", n)


if __name__ == "__main__":
    main()
