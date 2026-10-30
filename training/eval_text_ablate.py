"""Raw-model OCR with the app's self-ensemble (1, 2 = +180°, 8 passes), to separate the model from the pipeline."""
import os, sys
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import eval_text as E
from evaluate import load_model, run

OPS = [lambda i: i, lambda i: i.transpose(Image.ROTATE_180), lambda i: i.transpose(Image.FLIP_LEFT_RIGHT), lambda i: i.transpose(Image.FLIP_TOP_BOTTOM),
       lambda i: i.transpose(Image.TRANSPOSE), lambda i: i.transpose(Image.TRANSVERSE), lambda i: i.transpose(Image.ROTATE_90), lambda i: i.transpose(Image.ROTATE_270)]
INV = [lambda i: i, lambda i: i.transpose(Image.ROTATE_180), lambda i: i.transpose(Image.FLIP_LEFT_RIGHT), lambda i: i.transpose(Image.FLIP_TOP_BOTTOM),
       lambda i: i.transpose(Image.TRANSPOSE), lambda i: i.transpose(Image.TRANSVERSE), lambda i: i.transpose(Image.ROTATE_270), lambda i: i.transpose(Image.ROTATE_90)]

def ens(net, lr, n):
    acc = None
    for k in range(n):
        o = np.asarray(INV[k](run(net, OPS[k](lr))), np.float64)
        acc = o if acc is None else acc + o
    return Image.fromarray(np.clip(acc / n + 0.5, 0, 255).astype(np.uint8))

def main():
    out = sys.argv[1]
    cases = [(f[0], *E.banner(f)) for f in E.FONTS]
    entries, extra, names = [], {}, []
    for spec in sys.argv[2:]:
        name, path = spec.split("=", 1)
        net = load_model(path)[0]
        for n in (1, 2, 8):
            key = f"{name}_x{n}"; names.append(key); ps = []
            for fname, gt, mask in cases:
                sr = ens(net, E.web_copy(gt), n)
                ps.append(10 * np.log10(255 ** 2 / ((np.asarray(gt, float) - np.asarray(sr, float)) ** 2).mean()))
                entries.append((key, sr))
            extra[key] = (np.mean(ps), 0)
    agg, marks = E.ocr_by_size(entries, out)
    E.report(agg, extra, names, marks)


if __name__ == "__main__":
    main()
