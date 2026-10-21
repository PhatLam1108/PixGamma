"""Convert open-source Real-ESRGAN weights to Core ML tile models for PixGamma.

Run:  uv run --python 3.12 --with torch --with coremltools --with numpy tools/convert_models.py
Output: PixGamma/Models/*.mlpackage  (input/output are RGB images, 4x upscale)
"""
import os
import sys
import urllib.request

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEIGHTS_DIR = os.path.join(ROOT, "tools", "weights")
OUT_DIR = os.path.join(ROOT, "PixGamma", "Models")
TILE = 256  # input tile edge; output tile is TILE * 4

RELEASE = "https://github.com/xinntao/Real-ESRGAN/releases/download"
MODELS = {
    # name in app: (url, architecture kwargs)
    "Standard": (f"{RELEASE}/v0.1.0/RealESRGAN_x4plus.pth", ("rrdb", dict(num_block=23))),
    "ArtCGI": (f"{RELEASE}/v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth", ("rrdb", dict(num_block=6))),
    "LowRes": (f"{RELEASE}/v0.2.5.0/realesr-general-x4v3.pth", ("srvgg", dict(num_conv=32))),
}


# ---- Architectures (same layout as BasicSR so the official weights load) ----

class ResidualDenseBlock(nn.Module):
    def __init__(self, nf=64, gc=32):
        super().__init__()
        self.conv1 = nn.Conv2d(nf, gc, 3, 1, 1)
        self.conv2 = nn.Conv2d(nf + gc, gc, 3, 1, 1)
        self.conv3 = nn.Conv2d(nf + 2 * gc, gc, 3, 1, 1)
        self.conv4 = nn.Conv2d(nf + 3 * gc, gc, 3, 1, 1)
        self.conv5 = nn.Conv2d(nf + 4 * gc, nf, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(0.2, inplace=True)

    def forward(self, x):
        x1 = self.lrelu(self.conv1(x))
        x2 = self.lrelu(self.conv2(torch.cat((x, x1), 1)))
        x3 = self.lrelu(self.conv3(torch.cat((x, x1, x2), 1)))
        x4 = self.lrelu(self.conv4(torch.cat((x, x1, x2, x3), 1)))
        x5 = self.conv5(torch.cat((x, x1, x2, x3, x4), 1))
        return x5 * 0.2 + x


class RRDB(nn.Module):
    def __init__(self, nf, gc=32):
        super().__init__()
        self.rdb1 = ResidualDenseBlock(nf, gc)
        self.rdb2 = ResidualDenseBlock(nf, gc)
        self.rdb3 = ResidualDenseBlock(nf, gc)

    def forward(self, x):
        return self.rdb3(self.rdb2(self.rdb1(x))) * 0.2 + x


class RRDBNet(nn.Module):
    def __init__(self, num_block=23, nf=64):
        super().__init__()
        self.conv_first = nn.Conv2d(3, nf, 3, 1, 1)
        self.body = nn.Sequential(*[RRDB(nf) for _ in range(num_block)])
        self.conv_body = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_up1 = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_up2 = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_hr = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_last = nn.Conv2d(nf, 3, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(0.2, inplace=True)

    def forward(self, x):
        feat = self.conv_first(x)
        feat = feat + self.conv_body(self.body(feat))
        feat = self.lrelu(self.conv_up1(F.interpolate(feat, scale_factor=2, mode="nearest")))
        feat = self.lrelu(self.conv_up2(F.interpolate(feat, scale_factor=2, mode="nearest")))
        return self.conv_last(self.lrelu(self.conv_hr(feat)))


class SRVGGNetCompact(nn.Module):
    def __init__(self, num_feat=64, num_conv=32, upscale=4):
        super().__init__()
        self.upscale = upscale
        body = [nn.Conv2d(3, num_feat, 3, 1, 1), nn.PReLU(num_parameters=num_feat)]
        for _ in range(num_conv):
            body += [nn.Conv2d(num_feat, num_feat, 3, 1, 1), nn.PReLU(num_parameters=num_feat)]
        body.append(nn.Conv2d(num_feat, 3 * upscale * upscale, 3, 1, 1))
        self.body = nn.ModuleList(body)
        self.upsampler = nn.PixelShuffle(upscale)

    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        out = self.upsampler(out)
        return out + F.interpolate(x, scale_factor=self.upscale, mode="nearest")


class ImageWrapper(nn.Module):
    """Takes 0..1 RGB from Core ML, returns 0..255 so the output can be an image."""

    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, x):
        return torch.clamp(self.net(x), 0.0, 1.0) * 255.0


def load_weights(path):
    state = torch.load(path, map_location="cpu", weights_only=True)
    for key in ("params_ema", "params"):
        if key in state:
            return state[key]
    return state


def download(url):
    os.makedirs(WEIGHTS_DIR, exist_ok=True)
    dest = os.path.join(WEIGHTS_DIR, os.path.basename(url))
    if not os.path.exists(dest):
        print(f"Downloading {url}")
        urllib.request.urlretrieve(url, dest)
    return dest


def convert(name, url, arch):
    kind, kwargs = arch
    net = RRDBNet(**kwargs) if kind == "rrdb" else SRVGGNetCompact(**kwargs)
    net.load_state_dict(load_weights(download(url)), strict=True)
    model = ImageWrapper(net).eval()

    example = torch.rand(1, 3, TILE, TILE)
    traced = torch.jit.trace(model, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="input", shape=example.shape, scale=1 / 255.0,
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name="output", color_layout=ct.colorlayout.RGB)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
        convert_to="mlprogram",
    )
    mlmodel.short_description = f"PixGamma {name} 4x upscaler (Real-ESRGAN, BSD-3-Clause)"
    mlmodel.user_defined_metadata["tile"] = str(TILE)
    mlmodel.user_defined_metadata["scale"] = "4"

    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, f"{name}.mlpackage")
    mlmodel.save(out)

    # Sanity check: Core ML output should match PyTorch on the same tile.
    from PIL import Image
    arr = (np.random.rand(TILE, TILE, 3) * 255).astype(np.uint8)
    pred = np.asarray(mlmodel.predict({"input": Image.fromarray(arr)})["output"], dtype=np.float32)
    with torch.no_grad():
        ref = model(torch.from_numpy(arr).permute(2, 0, 1)[None].float() / 255.0)[0].permute(1, 2, 0).numpy()
    print(f"{name}: saved {out}, mean abs diff vs PyTorch = {np.abs(pred[..., :3] - ref).mean():.2f}/255")


if __name__ == "__main__":
    selected = sys.argv[1:] or list(MODELS)
    for name in selected:
        url, arch = MODELS[name]
        convert(name, url, arch)
