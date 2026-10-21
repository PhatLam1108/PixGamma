"""Synthetic text dataset for Pixora's text model (Vietnamese + English).

Renders 512x512 HR tiles of crisp text in many system fonts, sizes, colours and layouts
(banners, spec labels, captions, keyboard keycaps) over solid, gradient and photo
backgrounds, then makes the x4 LR copy with the same web degradations as prepare_dataset.py.
Synthetic text is unlimited and free of licensing issues, and the model learns straight,
thin strokes and complete Vietnamese diacritics (ả ơ ữ ặ đ …) instead of guessing them.

Usage:
  uv run --with pillow --with numpy --with fonttools python training/make_text_dataset.py \
      --count 6000 --name text [--photos training/datasets/raw_cc0]
"""
import argparse
import glob
import os
import random
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import io
import unicodedata

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

from prepare_dataset import degrade

ROOT = Path(__file__).resolve().parent
SIZE = 512
SMALL = 0.6   # share of lines drawn small (11–40 px HR)
CHAIN = 0.35  # share of LR copies made by the two-step web chain
THIN = 0.0    # share of lines in a light/regular face, light on a flat saturated banner colour
VN_TEST = "ẢẮỮỢđƯơ"

VN_TEXT = """
Laptop mỏng nhẹ hiệu năng vượt trội pin dùng cả ngày màn hình sắc nét bàn phím có đèn nền
Giá chỉ từ trả góp lãi suất ưu đãi đặc biệt bảo hành chính hãng giao hàng miễn phí toàn quốc
Điều kiện áp dụng xem chi tiết tại cửa hàng số lượng có hạn khuyến mãi tháng này mua ngay
Bộ vi xử lý thế hệ mới tiết kiệm điện năng card đồ họa rời ổ cứng thể rắn tốc độ cao
Thiết kế sang trọng vỏ nhôm nguyên khối bản lề chắc chắn trọng lượng chỉ một ký rưỡi
Cổng kết nối đa dạng sạc nhanh âm thanh sống động webcam độ phân giải cao micro khử ồn
Hướng dẫn sử dụng thông số kỹ thuật cấu hình chi tiết đánh giá sản phẩm so sánh giá
Xin chào quý khách cảm ơn đã tin tưởng ủng hộ chúng tôi luôn sẵn sàng hỗ trợ tư vấn
Phím tắt điều chỉnh độ sáng âm lượng tắt tiếng chế độ máy bay khóa màn hình chụp ảnh
Người dùng văn phòng sinh viên lập trình viên thiết kế đồ họa chơi game giải trí đa phương tiện
Ưu đãi lớn nhất năm giảm giá sốc quà tặng hấp dẫn đổi trả trong bảy ngày hoàn tiền nếu lỗi
Đặt hàng trực tuyến nhận hàng nhanh chóng thanh toán linh hoạt bằng thẻ hoặc tiền mặt
"""
EN_TEXT = """
Ultra thin and light performance all day battery brilliant display backlit keyboard
Next generation processor dedicated graphics fast storage aluminium unibody design
Ports charging speakers webcam microphone wireless connectivity specifications warranty
Model Serial Number Made in Input Rated Power Battery Capacity Wh Charger Output
"""
KEYS = list("QWERTYUIOPASDFGHJKLZXCVBNM1234567890") + [
    "Esc", "Tab", "Caps Lock", "Shift", "Ctrl", "Alt", "Fn", "Enter", "Backspace", "Home", "End",
    "PgUp", "PgDn", "Del", "Ins", "PrtSc", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10",
    "F11", "F12", "~", "!", "@", "#", "$", "%", "^", "&", "*", "(", ")", "-", "+", "=", "{", "}", "[", "]",
    ";", ":", "'", '"', ",", ".", "/", "?", "<", ">", "\\", "|", "⌘", "⌥", "⇧", "⌃", "←", "→", "↑", "↓",
]


def _renders(path, index):
    """Some system faces crash FreeType at certain sizes (Courier.ttc #2): test-render first."""
    try:
        for size in (9, 40, 140):
            f = ImageFont.truetype(path, size, index=index)
            ImageDraw.Draw(Image.new("RGB", (64, 64))).text((0, 0), "Hiệu ẢẮỮỢđ 18.990₫", font=f, fill="white")
        return True
    except Exception:
        return False


def _marks_ok(path, index):
    """Rejects faces whose precomposed Vietnamese glyphs are much wider than the base letter
    (marks placed beside the letter instead of above it)."""
    try:
        f = ImageFont.truetype(path, 64, index=index)
        for base, marked in (("o", "ồ"), ("a", "ẫ"), ("e", "ể")):
            if f.getlength(marked) > 1.35 * f.getlength(base):
                return False
        return True
    except Exception:
        return False


def fits(text, cmap):
    return all(ord(c) in cmap or c == " " for c in text)


def vn_fonts():
    from fontTools.ttLib import TTFont
    paths = sorted(set(glob.glob("/System/Library/Fonts/*.tt[fc]") + glob.glob("/System/Library/Fonts/Supplemental/*.tt[fc]")
                       + glob.glob("/Library/Fonts/*.tt[fc]")))
    out = []
    for p in paths:
        # Script/handwriting faces are not what product shots and UI use.
        if any(k in p for k in ("Brush", "Savoye", "Snell", "SignPainter", "Luminari", "Papyrus", "Marker", "Noteworthy", "Chalkboard", "Zapfino")):
            continue
        try:
            n = 1
            if p.endswith(".ttc"):
                from fontTools.ttLib import TTCollection
                n = len(TTCollection(p).fonts)
            for i in range(min(n, 6)):
                cmap = TTFont(p, fontNumber=i, lazy=True).getBestCmap()
                if all(ord(c) in cmap for c in VN_TEST) and _renders(p, i) and _marks_ok(p, i):
                    style = (TTFont(p, fontNumber=i, lazy=True)["name"].getDebugName(2) or "") + os.path.basename(p)
                    light = not any(k in style for k in ("Bold", "Black", "Heavy", "Semibold", "Medium", "Condensed"))
                    out.append((p, i, frozenset(cmap), light))
        except Exception:
            continue
    return out


# Random but well-formed Vietnamese syllables: the fixed phrases above cover few tone/vowel
# combinations, so the model guessed marks it had rarely seen ("thế" came out as "thổ").
ONSETS = ["", "b", "c", "ch", "d", "đ", "g", "gi", "h", "k", "kh", "l", "m", "n", "ng", "nh", "p", "ph",
          "qu", "r", "s", "t", "th", "tr", "v", "x"]
NUCLEI = ["a", "ă", "â", "e", "ê", "i", "o", "ô", "ơ", "u", "ư", "y", "ai", "ao", "au", "ay", "âu", "ây",
          "eo", "êu", "ia", "iê", "iu", "oa", "oă", "oe", "oi", "ôi", "ơi", "ua", "uâ", "uê", "ui", "uô",
          "uơ", "uy", "ưa", "ưi", "ươ", "ưu", "yê"]
CODAS = ["", "", "", "c", "ch", "m", "n", "ng", "nh", "p", "t"]
TONES = ["", "\u0301", "\u0300", "\u0309", "\u0303", "\u0323"]  # sắc huyền hỏi ngã nặng


def syllable(rng):
    nuc = rng.choice(NUCLEI)
    coda = rng.choice(CODAS) if not nuc.endswith(("i", "o", "u", "y")) or len(nuc) == 1 else ""
    tone = rng.choice(TONES[4:] + TONES[:4] if coda in ("c", "ch", "p", "t") else TONES)
    if coda in ("c", "ch", "p", "t") and tone not in ("\u0301", "\u0323"):
        tone = rng.choice(["\u0301", "\u0323"])
    # The tone mark sits on the main vowel: the one with a hat/horn, else the second of a pair.
    chars = list(nuc)
    k = next((j for j, c in enumerate(chars) if c in "ăâêôơư"), None)
    if k is None:
        k = 1 if len(chars) > 1 and (coda or nuc in ("oa", "oe", "uy")) else 0
    chars[k] = unicodedata.normalize("NFC", chars[k] + tone)
    return rng.choice(ONSETS) + "".join(chars) + coda


def words(rng, vn_ratio=0.75):
    if rng.random() < 0.4:
        phrase = " ".join(syllable(rng) for _ in range(rng.randint(1, 9)))
        r = rng.random()
        if r < 0.15:
            phrase = phrase.upper()
        elif r < 0.5:
            phrase = phrase[:1].upper() + phrase[1:]
        return phrase
    src = VN_TEXT if rng.random() < vn_ratio else EN_TEXT
    w = src.split()
    n = rng.randint(1, 8)
    i = rng.randrange(len(w))
    phrase = " ".join(w[(i + k) % len(w)] for k in range(n))
    r = rng.random()
    if r < 0.15:
        phrase = phrase.upper()
    elif r < 0.45:
        phrase = phrase[:1].upper() + phrase[1:]
    if rng.random() < 0.15:
        phrase += rng.choice([f" {rng.randint(1, 99)}.{rng.randint(100, 999)}.000₫", f" {rng.randint(8, 64)}GB",
                              f" {rng.randint(1, 4)}TB", f" {rng.randint(11, 18)}.{rng.randint(0, 9)} inch", " 0%", " –30%"])
    return phrase


def background(rng, photos):
    if rng.random() < THIN:
        # Banner colours: saturated, mid-dark (white text on blue/red/green promos).
        h = rng.random()
        import colorsys
        c = colorsys.hsv_to_rgb(h, rng.uniform(0.5, 1.0), rng.uniform(0.25, 0.7))
        a = np.array([v * 255 for v in c], np.float32)
        b = np.clip(a * rng.uniform(0.6, 1.4), 0, 255)
        t = np.linspace(0, 1, SIZE, dtype=np.float32)[:, None, None]
        img = np.repeat(a * (1 - t) + b * t, SIZE, axis=1)
        return Image.fromarray(img.clip(0, 255).astype(np.uint8))
    kind = rng.random()
    if kind < 0.3 or not photos:
        c = tuple(rng.randint(0, 255) for _ in range(3))
        return Image.new("RGB", (SIZE, SIZE), c)
    if kind < 0.6:
        a = np.array([rng.randint(0, 255) for _ in range(3)], np.float32)
        b = np.array([rng.randint(0, 255) for _ in range(3)], np.float32)
        t = np.linspace(0, 1, SIZE, dtype=np.float32)[:, None, None]
        g = a * (1 - t) + b * t
        img = np.repeat(g, SIZE, axis=1)
        if rng.random() < 0.5:
            img = img.transpose(1, 0, 2)
        return Image.fromarray(img.clip(0, 255).astype(np.uint8))
    p = rng.choice(photos)
    try:
        im = Image.open(p).convert("RGB")
    except Exception:
        return Image.new("RGB", (SIZE, SIZE), (128, 128, 128))
    s = rng.uniform(0.25, 0.6)
    im = im.resize((max(SIZE, int(im.width * s)), max(SIZE, int(im.height * s))), Image.LANCZOS)
    x, y = rng.randint(0, im.width - SIZE), rng.randint(0, im.height - SIZE)
    im = im.crop((x, y, x + SIZE, y + SIZE))
    if rng.random() < 0.6:
        im = im.filter(ImageFilter.GaussianBlur(rng.uniform(1, 6)))
    return im


def contrast_colour(bg_rgb, rng):
    lum = 0.299 * bg_rgb[0] + 0.587 * bg_rgb[1] + 0.114 * bg_rgb[2]
    if rng.random() < 0.2:
        return tuple(rng.randint(0, 255) for _ in range(3))
    base = rng.randint(0, 50) if lum > 128 else rng.randint(205, 255)
    tint = [rng.randint(-25, 25) for _ in range(3)]
    return tuple(int(np.clip(base + t, 0, 255)) for t in tint)


def draw_text_block(img, rng, fonts):
    d = ImageDraw.Draw(img)
    y = rng.randint(4, 60)
    while y < SIZE - 10:
        text = words(rng)
        thin = rng.random() < THIN
        path, idx, cmap, _ = rng.choice([f for f in fonts if f[3]] if thin else fonts)
        if not fits(text, cmap):
            continue
        # Most web text ends up 3–10 px tall in the LR image, where marks are 1–2 px: favour it.
        size = int(rng.uniform(11, 40)) if rng.random() < SMALL else int(np.clip(rng.lognormvariate(3.1, 0.55), 9, 140))
        try:
            font = ImageFont.truetype(path, size, index=idx)
        except Exception:
            continue
        x = rng.randint(-20, 120)
        box = d.textbbox((x, y), text, font=font)
        if box[2] <= box[0] + 1 or box[3] <= box[1] + 1:
            y += 8
            continue
        cx0, cy0 = min(SIZE - 1, max(0, box[0])), min(SIZE - 1, max(0, box[1]))
        cx1, cy1 = max(cx0 + 1, min(SIZE, box[2] + 1)), max(cy0 + 1, min(SIZE, box[3] + 1))
        mean = np.asarray(img.crop((cx0, cy0, cx1, cy1))).reshape(-1, 3).mean(0)
        col = tuple(rng.randint(225, 255) for _ in range(3)) if thin and mean.mean() < 150 else contrast_colour(mean, rng)
        if rng.random() < 0.15:  # shadow or outline, common in banners
            sh = tuple(255 - c for c in col)
            d.text((x + max(1, size // 18), y + max(1, size // 18)), text, font=font, fill=sh)
        if rng.random() < 0.15:  # label plate behind the text
            pad = max(2, size // 5)
            d.rounded_rectangle((box[0] - pad, box[1] - pad, box[2] + pad, box[3] + pad), radius=pad, fill=tuple(255 - c for c in col))
        d.text((x, y), text, font=font, fill=col)
        y = box[3] + rng.randint(max(2, size // 4), max(4, size))


def draw_keyboard(img, rng, fonts):
    d = ImageDraw.Draw(img)
    dark = rng.random() < 0.7
    key_c = tuple(rng.randint(15, 60) for _ in range(3)) if dark else tuple(rng.randint(190, 240) for _ in range(3))
    leg_c = tuple(rng.randint(200, 255) for _ in range(3)) if dark else tuple(rng.randint(10, 60) for _ in range(3))
    k = rng.randint(34, 110)
    gap = max(3, k // 9)
    path, idx, cmap, _ = rng.choice(fonts)
    keys = [k_ for k_ in KEYS if fits(k_, cmap)]
    font = ImageFont.truetype(path, max(8, int(k * rng.uniform(0.22, 0.42))), index=idx)
    small = ImageFont.truetype(path, max(7, int(k * 0.18)), index=idx)
    y = rng.randint(-k // 2, gap)
    while y < SIZE:
        x = rng.randint(-k, 0)
        while x < SIZE:
            w = k * rng.choice([1, 1, 1, 1, 1.5, 2])
            d.rounded_rectangle((x, y, x + w, y + k), radius=max(2, k // 8), fill=key_c)
            label = rng.choice(keys)
            pos = rng.random()
            if pos < 0.5:
                tb = d.textbbox((0, 0), label, font=font)
                d.text((x + (w - (tb[2] - tb[0])) / 2, y + (k - (tb[3] - tb[1])) / 2 - tb[1]), label, font=font, fill=leg_c)
            else:
                d.text((x + k * 0.14, y + k * 0.1), label, font=font, fill=leg_c)
                if rng.random() < 0.5:
                    d.text((x + k * 0.14, y + k * 0.62), rng.choice(keys[36:] or keys), font=small, fill=leg_c)
            x += w + gap
        y += k + gap


def degrade_text(img, rng):
    """Web text is often scaled and re-compressed twice (banner → thumbnail), which smears thin
    marks into the letter below them: add that chain to the usual web degradations."""
    if rng.random() >= CHAIN:
        return degrade(img, rng)
    def jpeg(im, q):
        buf = io.BytesIO()
        im.save(buf, "JPEG", quality=q)
        buf.seek(0)
        return Image.open(buf).convert("RGB")
    k = [Image.BICUBIC, Image.BILINEAR, Image.LANCZOS, Image.BOX]
    mid = img.resize((SIZE // 2, SIZE // 2), rng.choice(k))
    if rng.random() < 0.6:
        mid = mid.filter(ImageFilter.GaussianBlur(rng.uniform(0.3, 0.9)))
    mid = jpeg(mid, rng.randint(45, 90))
    return jpeg(mid.resize((SIZE // 4, SIZE // 4), rng.choice(k)), rng.randint(60, 95))


def make(args):
    """Renders one sample; FreeType occasionally fails on odd sizes, so retry with a new seed."""
    i, out, seed, fonts, photos, cfg = args
    # Worker processes are spawned fresh (macOS), so the mix travels with each job.
    global SMALL, CHAIN, THIN
    SMALL, CHAIN, THIN = cfg
    for attempt in range(8):
        try:
            return _make(i, out, seed + attempt * 7_919_000, fonts, photos)
        except (OSError, ValueError, ZeroDivisionError):
            continue


def _make(i, out, seed, fonts, photos):
    rng = random.Random(seed)
    img = background(rng, photos)
    if rng.random() < 0.3:
        draw_keyboard(img, rng, fonts)
    else:
        draw_text_block(img, rng, fonts)
    if rng.random() < 0.25:
        img = img.rotate(rng.uniform(-4, 4), resample=Image.BICUBIC, expand=False, fillcolor=img.getpixel((0, 0)))
    name = f"t{i:06d}.png"
    img.save(out / "hr" / name, compress_level=1)
    degrade_text(img, rng).save(out / "lr" / name, compress_level=1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=6000)
    ap.add_argument("--val", type=int, default=24)
    ap.add_argument("--name", default="text")
    ap.add_argument("--photos", default=str(ROOT / "datasets" / "raw_cc0"))
    ap.add_argument("--seed", type=int, default=1108)
    ap.add_argument("--small", type=float, default=SMALL)
    ap.add_argument("--chain", type=float, default=CHAIN)
    ap.add_argument("--thin", type=float, default=THIN)
    a = ap.parse_args()
    fonts = vn_fonts()
    photos = sorted(glob.glob(os.path.join(a.photos, "*.jpg")))
    print(f"{len(fonts)} font hỗ trợ tiếng Việt, {len(photos)} ảnh nền")
    for split, n, off in (("val", a.val, 10_000_000), ("train", a.count, 0)):
        out = ROOT / "datasets" / a.name / split
        (out / "hr").mkdir(parents=True, exist_ok=True)
        (out / "lr").mkdir(parents=True, exist_ok=True)
        jobs = [(i, out, a.seed + off + i, fonts, photos, (a.small, a.chain, a.thin)) for i in range(n)]
        with ProcessPoolExecutor() as ex:
            list(ex.map(make, jobs, chunksize=32))
        print(f"{split}: {n} ô → {out}")


if __name__ == "__main__":
    main()
