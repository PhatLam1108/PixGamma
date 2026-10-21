"""Convert extra open-source models to Core ML for Pixora.

Produces (in Pixora/Models/):
  Standard2x.mlpackage   RealESRGAN_x2plus (BSD-3-Clause), 256 -> 512
  LowRes.mlpackage       realesr-general-x4v3 + wdn-x4v3 DNI blend with a "denoise" input
                         (falls back to fixed LowRes_dnXXX variants if dynamic weights fail)
  FaceRestore.mlpackage  GFPGAN v1.4 (Apache-2.0), 512 -> 512
  HighFidelity.mlpackage RealESRNet_x4plus (PSNR-oriented), 256 -> 1024
  Photo.mlpackage        4xBHI_dat2_real (Phhofm, CC-BY-4.0), DAT2, 256 -> 1024      [needs --with spandrel]
                         (PIXORA_PHOTO_WEIGHTS: any RealPLKSR or DAT checkpoint, e.g. a fine-tune)
  Photo2x.mlpackage      2xNomosUni_span_multijpg_ldl (Phhofm, CC-BY-4.0), 256 -> 512 [needs --with spandrel]
  FaceRealistic.mlpackage CodeFormer (S-Lab License 1.0, NON-COMMERCIAL) with a "fidelity" input

Run from the project root:
  uv run --python 3.12 --with torch --with coremltools --with numpy --with pillow \
      python tools/convert_extra.py [Standard2x] [LowRes] [FaceRestore] [HighFidelity] [FaceRealistic]
  (add `--with spandrel` for [Photo] [Photo2x]); hang/timing check of saved models:
  ... python tools/convert_extra.py --unit-check HighFidelity FaceRealistic ...
"""
import os
import shutil
import sys
import types
import urllib.request

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS_DIR)
import convert_models as base  # noqa: E402  (RRDBNet, SRVGGNetCompact, ImageWrapper, load_weights)

ROOT = os.path.dirname(TOOLS_DIR)
WEIGHTS_DIR = os.path.join(ROOT, "tools", "weights")
OUT_DIR = os.environ.get("PIXORA_OUT_DIR") or os.path.join(ROOT, "Pixora", "Models")  # overrides base.OUT_DIR
TILE = 256
FACE = 512

URL_X2 = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth"
URL_GEN = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth"
URL_WDN = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-wdn-x4v3.pth"
URL_GFP = "https://github.com/TencentARC/GFPGAN/releases/download/v1.3.0/GFPGANv1.4.pth"
GFP_ARCH_RAW = "https://raw.githubusercontent.com/TencentARC/GFPGAN/master/gfpgan/archs"


def download(url, dest_dir=WEIGHTS_DIR):
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, os.path.basename(url))
    if not os.path.exists(dest):
        print(f"Downloading {url}")
        urllib.request.urlretrieve(url, dest)
    return dest


def save(mlmodel, name):
    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, f"{name}.mlpackage")
    if os.path.exists(out):
        shutil.rmtree(out)
    mlmodel.save(out)
    return out


def rand_image(size, seed=0):
    rng = np.random.default_rng(seed)
    return (rng.random((size, size, 3)) * 255).astype(np.uint8)


def to_tensor(arr):
    return torch.from_numpy(arr).permute(2, 0, 1)[None].float() / 255.0


def mlpredict(path, feeds, units=None):
    """Reload from disk (confirms loadability) and run one prediction."""
    m = ct.models.MLModel(path, compute_units=units or ct.ComputeUnit.ALL)
    out = m.predict(feeds)["output"]
    return np.asarray(out, dtype=np.float32)[..., :3]


def image_io(shape):
    return dict(
        inputs=[ct.ImageType(name="input", shape=shape, scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name="output", color_layout=ct.colorlayout.RGB)],
    )


# --------------------------------------------------------------------------- Standard2x

class RRDBNetX2(base.RRDBNet):
    """BasicSR RRDBNet with scale=2: pixel-unshuffle input by 2 -> 12 channels."""

    def __init__(self, num_block=23, nf=64):
        super().__init__(num_block=num_block, nf=nf)
        self.conv_first = nn.Conv2d(3 * 4, nf, 3, 1, 1)

    def forward(self, x):
        return super().forward(F.pixel_unshuffle(x, 2))


def convert_standard2x():
    net = RRDBNetX2(num_block=23)
    net.load_state_dict(base.load_weights(download(URL_X2)), strict=True)
    model = base.ImageWrapper(net).eval()
    example = torch.rand(1, 3, TILE, TILE)
    traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(traced, **image_io(example.shape),
                         compute_precision=ct.precision.FLOAT16,
                         minimum_deployment_target=ct.target.macOS14, convert_to="mlprogram")
    mlmodel.short_description = "Pixora Standard 2x upscaler (RealESRGAN_x2plus, BSD-3-Clause)"
    mlmodel.user_defined_metadata["tile"] = str(TILE)
    mlmodel.user_defined_metadata["scale"] = "2"
    out = save(mlmodel, "Standard2x")

    arr = rand_image(TILE)
    pred = mlpredict(out, {"input": Image.fromarray(arr)})
    with torch.no_grad():
        ref = model(to_tensor(arr))[0].permute(1, 2, 0).numpy()
    print(f"Standard2x: saved {out}, output {pred.shape}, mean abs diff vs PyTorch = "
          f"{np.abs(pred - ref).mean():.2f}/255")


# --------------------------------------------------------------------------- LowRes (DNI)

class BlendedSRVGG(nn.Module):
    """SRVGGNetCompact whose conv/PReLU params are d*A + (1-d)*B computed in forward."""

    def __init__(self, sd_a, sd_b, num_conv=32, upscale=4):
        super().__init__()
        self.upscale = upscale
        names = sorted({k.rsplit(".", 1)[0] for k in sd_a}, key=lambda s: int(s.split(".")[1]))
        self.layers = []  # (kind, key)
        for i, key in enumerate(names):
            w = sd_a[f"{key}.weight"]
            kind = "conv" if w.dim() == 4 else "prelu"
            safe = key.replace(".", "_")
            self.register_buffer(f"{safe}_wa", sd_a[f"{key}.weight"].clone())
            self.register_buffer(f"{safe}_wb", sd_b[f"{key}.weight"].clone())
            if kind == "conv":
                self.register_buffer(f"{safe}_ba", sd_a[f"{key}.bias"].clone())
                self.register_buffer(f"{safe}_bb", sd_b[f"{key}.bias"].clone())
            self.layers.append((kind, safe))

    def forward(self, x, d):
        d = d.reshape(1)
        e = 1.0 - d
        out = x
        for kind, safe in self.layers:
            w = getattr(self, f"{safe}_wa") * d + getattr(self, f"{safe}_wb") * e
            if kind == "conv":
                b = getattr(self, f"{safe}_ba") * d + getattr(self, f"{safe}_bb") * e
                out = F.conv2d(out, w, b, padding=1)
            else:
                # Manual PReLU: Core ML's prelu op requires a constant alpha.
                out = F.relu(out) + w.reshape(1, -1, 1, 1) * torch.clamp(out, max=0.0)
        out = F.pixel_shuffle(out, self.upscale)
        return out + F.interpolate(x, scale_factor=self.upscale, mode="nearest")


class BlendedWrapper(nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, x, denoise):
        return torch.clamp(self.net(x, denoise), 0.0, 1.0) * 255.0


def dni(sd_a, sd_b, d):
    return {k: d * sd_a[k] + (1 - d) * sd_b[k] for k in sd_a}


def fixed_srvgg(sd):
    net = base.SRVGGNetCompact(num_conv=32)
    net.load_state_dict(sd, strict=True)
    return base.ImageWrapper(net).eval()


def convert_lowres_fixed(sd_a, sd_b, d, name):
    model = fixed_srvgg(dni(sd_a, sd_b, d))
    example = torch.rand(1, 3, TILE, TILE)
    traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(traced, **image_io(example.shape),
                         compute_precision=ct.precision.FLOAT16,
                         minimum_deployment_target=ct.target.macOS14, convert_to="mlprogram")
    mlmodel.short_description = (f"Pixora LowRes 4x upscaler, denoise={d:.2f} "
                                 "(realesr-general-x4v3 / wdn-x4v3 DNI, BSD-3-Clause)")
    mlmodel.user_defined_metadata["tile"] = str(TILE)
    mlmodel.user_defined_metadata["scale"] = "4"
    mlmodel.user_defined_metadata["denoise"] = f"{d:.2f}"
    out = save(mlmodel, name)
    arr = rand_image(TILE)
    pred = mlpredict(out, {"input": Image.fromarray(arr)})
    with torch.no_grad():
        ref = model(to_tensor(arr))[0].permute(1, 2, 0).numpy()
    print(f"{name}: saved {out}, mean abs diff vs PyTorch = {np.abs(pred - ref).mean():.2f}/255")


def convert_lowres():
    sd_a = base.load_weights(download(URL_GEN))  # x4v3 (d=1)
    sd_b = base.load_weights(download(URL_WDN))  # wdn  (d=0)
    model = BlendedWrapper(BlendedSRVGG(sd_a, sd_b)).eval()

    # Self-check: blended functional net == standard net with DNI-merged weights.
    arr = rand_image(TILE)
    x = to_tensor(arr)
    with torch.no_grad():
        for d in (0.0, 0.5, 1.0):
            a = model(x, torch.tensor([d]))
            b = fixed_srvgg(dni(sd_a, sd_b, d))(x)
            assert (a - b).abs().max() < 1e-2, f"blend mismatch at d={d}"

    ok = False
    try:
        traced = torch.jit.trace(model, (torch.rand(1, 3, TILE, TILE), torch.tensor([0.5])))
        io = image_io((1, 3, TILE, TILE))
        io["inputs"].append(ct.TensorType(name="denoise", shape=(1,), dtype=np.float32))
        mlmodel = ct.convert(traced, **io, compute_precision=ct.precision.FLOAT16,
                             minimum_deployment_target=ct.target.macOS14, convert_to="mlprogram")
        mlmodel.short_description = ("Pixora LowRes 4x upscaler with denoise strength input 0..1 "
                                     "(realesr-general-x4v3 / wdn-x4v3 DNI, BSD-3-Clause)")
        mlmodel.input_description["denoise"] = "Denoise strength 0..1 (1 = strongest, plain x4v3)"
        mlmodel.user_defined_metadata["tile"] = str(TILE)
        mlmodel.user_defined_metadata["scale"] = "4"
        mlmodel.user_defined_metadata["denoise_input"] = "1"
        out = save(mlmodel, "LowRes")

        diffs = []
        for d in (0.0, 0.25, 0.5, 0.75, 1.0):
            pred = mlpredict(out, {"input": Image.fromarray(arr),
                                   "denoise": np.array([d], dtype=np.float32)})
            with torch.no_grad():
                ref = model(x, torch.tensor([d]))[0].permute(1, 2, 0).numpy()
            diffs.append(np.abs(pred - ref).mean())
            print(f"LowRes(dynamic) d={d:.2f}: mean abs diff vs PyTorch = {diffs[-1]:.2f}/255")
        # Make sure the denoise input actually changes the output.
        p0 = mlpredict(out, {"input": Image.fromarray(arr), "denoise": np.array([0.0], np.float32)})
        p1 = mlpredict(out, {"input": Image.fromarray(arr), "denoise": np.array([1.0], np.float32)})
        spread = np.abs(p0 - p1).mean()
        print(f"LowRes(dynamic): saved {out}, output {p0.shape}, d=0 vs d=1 differ by {spread:.2f}/255")
        ok = max(diffs) < 3.0 and spread > 0.1
        if not ok:
            print("LowRes(dynamic): accuracy check failed, falling back to fixed variants")
    except Exception as exc:  # noqa: BLE001
        print(f"LowRes(dynamic) failed: {exc!r}; falling back to fixed variants")

    if ok:
        for d in (0, 25, 50, 75, 100):  # remove stale fallbacks if any
            p = os.path.join(OUT_DIR, f"LowRes_dn{d:03d}.mlpackage")
            if os.path.exists(p):
                shutil.rmtree(p)
        return
    for d in (0, 25, 50, 75, 100):
        convert_lowres_fixed(sd_a, sd_b, d / 100, f"LowRes_dn{d:03d}")
    convert_lowres_fixed(sd_a, sd_b, 0.5, "LowRes")


# --------------------------------------------------------------------------- FaceRestore

def stub_basicsr():
    """Minimal stand-ins for the basicsr symbols the upstream arch files import."""
    if "basicsr" in sys.modules:
        return

    class _Registry:
        def register(self, *a, **k):
            if a and callable(a[0]):
                return a[0]
            return lambda obj: obj

    @torch.no_grad()
    def default_init_weights(module_list, scale=1, bias_fill=0, **kwargs):
        if not isinstance(module_list, list):
            module_list = [module_list]
        for module in module_list:
            for m in module.modules():
                if isinstance(m, (nn.Conv2d, nn.Linear)):
                    nn.init.kaiming_normal_(m.weight, **kwargs)
                    m.weight.data *= scale
                    if m.bias is not None:
                        m.bias.data.fill_(bias_fill)

    import logging
    mods = {
        "basicsr": types.ModuleType("basicsr"),
        "basicsr.utils": types.ModuleType("basicsr.utils"),
        "basicsr.utils.registry": types.ModuleType("basicsr.utils.registry"),
        "basicsr.archs": types.ModuleType("basicsr.archs"),
        "basicsr.archs.arch_util": types.ModuleType("basicsr.archs.arch_util"),
    }
    mods["basicsr"].__path__ = []
    mods["basicsr.archs"].__path__ = []
    mods["basicsr.utils"].__path__ = []
    mods["basicsr.utils.registry"].ARCH_REGISTRY = _Registry()
    mods["basicsr.utils"].get_root_logger = lambda *a, **k: logging.getLogger("basicsr")
    mods["basicsr.archs.arch_util"].default_init_weights = default_init_weights
    sys.modules.update(mods)


def load_gfpgan_arch():
    arch_dir = os.path.join(WEIGHTS_DIR, "gfpgan_arch")
    for f in ("gfpganv1_clean_arch.py", "stylegan2_clean_arch.py"):
        download(f"{GFP_ARCH_RAW}/{f}", arch_dir)
    stub_basicsr()

    pkg = types.ModuleType("gfpgan_arch")
    pkg.__path__ = [arch_dir]
    sys.modules["gfpgan_arch"] = pkg
    import importlib
    sg = importlib.import_module("gfpgan_arch.stylegan2_clean_arch")
    sg.ModulatedConv2d.forward = _modconv_forward_b1
    return importlib.import_module("gfpgan_arch.gfpganv1_clean_arch").GFPGANv1Clean


def _modconv_forward_b1(self, x, style):
    """ModulatedConv2d.forward specialised to batch 1 with static shapes.

    Same math as upstream, but avoids x.shape-derived ints (which coremltools
    cannot fold under torch 2.x tracing) and the grouped conv trick (groups=b=1).
    """
    style = self.modulation(style).view(1, 1, self.in_channels, 1, 1)
    weight = self.weight * style
    if self.demodulate:
        demod = torch.rsqrt(weight.pow(2).sum([2, 3, 4]) + self.eps)
        weight = weight * demod.view(1, self.out_channels, 1, 1, 1)
    weight = weight.view(self.out_channels, self.in_channels, self.kernel_size, self.kernel_size)
    if self.sample_mode == "upsample":
        x = F.interpolate(x, scale_factor=2, mode="bilinear", align_corners=False)
    elif self.sample_mode == "downsample":
        x = F.interpolate(x, scale_factor=0.5, mode="bilinear", align_corners=False)
    return F.conv2d(x, weight, padding=self.padding)


class FaceWrapper(nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, x):
        out = self.net(x * 2.0 - 1.0, return_rgb=False, randomize_noise=False)[0]
        return (out.clamp(-1.0, 1.0) + 1.0) / 2.0 * 255.0


def smooth_image(size):
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32) / size
    r = 0.55 + 0.35 * np.sin(xx * 3.1) * np.cos(yy * 2.3)
    g = 0.45 + 0.25 * np.cos(xx * 1.7 + yy * 2.9)
    b = 0.40 + 0.30 * np.sin((xx + yy) * 2.2)
    d = np.sqrt((xx - 0.5) ** 2 + (yy - 0.45) ** 2)
    face = np.clip(1.0 - d / 0.35, 0, 1)[..., None] * np.array([0.92, 0.72, 0.6], np.float32)
    img = np.clip(np.stack([r, g, b], -1) * 0.5 + face * 0.6, 0, 1)
    return (img * 255).astype(np.uint8)


def convert_face():
    GFPGANv1Clean = load_gfpgan_arch()
    net = GFPGANv1Clean(out_size=512, num_style_feat=512, channel_multiplier=2, decoder_load_path=None,
                        fix_decoder=False, num_mlp=8, input_is_latent=True, different_w=True,
                        narrow=1, sft_half=True)
    state = torch.load(download(URL_GFP), map_location="cpu", weights_only=True)
    net.load_state_dict(state["params_ema"], strict=True)
    model = FaceWrapper(net).eval()

    example = torch.rand(1, 3, FACE, FACE)
    with torch.no_grad():
        r1 = model(example)
        r2 = model(example)
    assert torch.equal(r1, r2), "GFPGAN forward is not deterministic"
    with torch.no_grad():
        traced = torch.jit.trace(model, example)

    tests = {"random": rand_image(FACE, seed=1), "smooth": smooth_image(FACE)}
    with torch.no_grad():
        refs = {k: model(to_tensor(v))[0].permute(1, 2, 0).numpy() for k, v in tests.items()}

    # Pure FP16 overflows in StyleGAN2 weight demodulation (sum of squared modulated
    # weights), so the middle option keeps just those reductions in FP32.
    fp32_ops = {"pow", "square", "reduce_sum", "rsqrt"}
    mixed = ct.transform.FP16ComputePrecision(op_selector=lambda op: op.op_type not in fp32_ops)
    for precision, label in ((ct.precision.FLOAT16, "FP16"), (mixed, "FP16+FP32demod"),
                             (ct.precision.FLOAT32, "FP32")):
        mlmodel = ct.convert(traced, **image_io(example.shape), compute_precision=precision,
                             minimum_deployment_target=ct.target.macOS14, convert_to="mlprogram")
        mlmodel.short_description = "Pixora face restoration (GFPGAN v1.4, Apache-2.0), 512x512 aligned face"
        mlmodel.user_defined_metadata["size"] = str(FACE)
        mlmodel.user_defined_metadata["precision"] = label
        out = save(mlmodel, "FaceRestore")
        diffs = {}
        for k, arr in tests.items():
            pred = mlpredict(out, {"input": Image.fromarray(arr)}, ct.ComputeUnit.CPU_AND_GPU if gpu_only else None)
            diffs[k] = np.abs(pred - refs[k]).mean()
            print(f"FaceRestore[{label}] {k}: output {pred.shape}, mean abs diff vs fp32 PyTorch = "
                  f"{diffs[k]:.2f}/255")
        if max(diffs.values()) < 2.0:
            print(f"FaceRestore: saved {out} ({label})")
            return
        print(f"FaceRestore: {label} exceeds 2/255, trying next precision")
    print("FaceRestore: WARNING FP32 also exceeded 2/255; kept FP32 model")


# --------------------------------------------------------------------------- shared helpers

PARROT = "/Library/User Pictures/Animals/Parrot.heic"
PORTRAIT = ("/Library/Developer/CoreSimulator/Volumes/iOS_24A5355p/Library/Developer/CoreSimulator/Profiles/"
            "Runtimes/iOS 27.0.simruntime/Contents/Resources/RuntimeRoot/System/Library/PrivateFrameworks/"
            "CoreIDVShared.framework/TestPortrait.jpg")


def load_test_image(path, size):
    """Center-crop to square and resize to `size`. HEIC goes through macOS `sips`. None if unavailable."""
    import subprocess
    import tempfile
    if not os.path.exists(path):
        return None
    src = path
    if path.lower().endswith(".heic"):
        src = os.path.join(tempfile.mkdtemp(), "img.png")
        subprocess.run(["sips", "-s", "format", "png", path, "--out", src], check=True, capture_output=True)
    img = Image.open(src).convert("RGB")
    w, h = img.size
    e = min(w, h)
    img = img.crop(((w - e) // 2, (h - e) // 2, (w - e) // 2 + e, (h - e) // 2 + e))
    return np.asarray(img.resize((size, size), Image.LANCZOS), dtype=np.uint8)


# --------------------------------------------------------------------------- HighFidelity

URL_ESRNET = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.1/RealESRNet_x4plus.pth"


def convert_fixed_sr(name, net, scale, description, extra_meta=None, real=None):
    # GPU-only models ("compute": "gpu") are checked on the GPU: compiling them for the Neural
    # Engine never finishes and leaves ANECompilerService spinning.
    gpu_only = (extra_meta or {}).get("compute") == "gpu"
    """Plain image->image SR tile model (FP16), verified vs PyTorch on a random and a real tile."""
    model = base.ImageWrapper(net).eval()
    example = torch.rand(1, 3, TILE, TILE)
    with torch.no_grad():
        traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(traced, **image_io(example.shape), compute_precision=ct.precision.FLOAT16,
                         minimum_deployment_target=ct.target.macOS14, convert_to="mlprogram")
    mlmodel.short_description = description
    mlmodel.user_defined_metadata["tile"] = str(TILE)
    mlmodel.user_defined_metadata["scale"] = str(scale)
    for k, v in (extra_meta or {}).items():
        mlmodel.user_defined_metadata[k] = v
    out = save(mlmodel, name)
    tests = {"random": rand_image(TILE)}
    if real is not None:
        tests["parrot"] = real
    for k, arr in tests.items():
        pred = mlpredict(out, {"input": Image.fromarray(arr)})
        with torch.no_grad():
            ref = model(to_tensor(arr))[0].permute(1, 2, 0).numpy()
        print(f"{name} {k}: output {pred.shape}, mean abs diff vs PyTorch = {np.abs(pred - ref).mean():.2f}/255")
    print(f"{name}: saved {out}")
    return out


def convert_highfidelity():
    # A dynamic-weight (network-interpolation) RRDB variant converted fine but hangs on the
    # GPU (MPSGraph) at prediction time, so this is a fixed RealESRNet_x4plus model; the app
    # blends its output with Standard (RealESRGAN_x4plus) for the Detail slider.
    net = base.RRDBNet(num_block=23)
    net.load_state_dict(base.load_weights(download(URL_ESRNET)), strict=True)
    out = convert_fixed_sr("HighFidelity", net.eval(), 4,
                           "Pixora High Fidelity 4x upscaler (RealESRNet_x4plus, PSNR-oriented, BSD-3-Clause)",
                           real=load_test_image(PARROT, TILE))
    unit_check(out)


# --------------------------------------------------------------------------- Photo / Photo2x (Phhofm, CC-BY-4.0)

# Photo since 0.2.0: 4xBHI_dat2_real scored best of ten public 4x models on Pixora's photo set
# (laptop shots, portraits, animals; training/evaluate.py): DISTS 0.173 vs 0.199 for NomosWebPhoto.
URL_PHOTO = "https://huggingface.co/Phips/4xBHI_dat2_real/resolve/main/4xBHI_dat2_real.safetensors"
URL_PHOTO_NOMOS = ("https://github.com/Phhofm/models/releases/download/4xNomosWebPhoto_RealPLKSR/"
                   "4xNomosWebPhoto_RealPLKSR.pth")
URL_PHOTO2X = ("https://github.com/Phhofm/models/releases/download/2xNomosUni_span_multijpg_ldl/"
               "2xNomosUni_span_multijpg_ldl.pth")


def _spandrel_load(path):
    try:
        import spandrel
    except ImportError:
        sys.exit("Photo models need spandrel: add `--with spandrel` to the uv command")
    return spandrel.ModelLoader().load_from_file(path).model.eval()


def _plk_forward_noinplace(self, x):
    """PLKConv2d inference path writes x[:, :idx] in place; use split/conv/cat (same math)."""
    return torch.cat([self.conv(x[:, : self.idx]), x[:, self.idx:]], dim=1)


def tile_seam_check(model, name, scale):
    """GroupNorm uses per-image statistics: compare one 512 pass vs four 256 tiles."""
    arr = load_test_image(PARROT, 2 * TILE)
    if arr is None:
        return
    x = to_tensor(arr)
    with torch.no_grad():
        full = model(x)
        tiled = torch.zeros_like(full)
        o = TILE * scale
        for i in range(2):
            for j in range(2):
                tiled[..., i * o:(i + 1) * o, j * o:(j + 1) * o] = model(
                    x[..., i * TILE:(i + 1) * TILE, j * TILE:(j + 1) * TILE])
    diff = (full - tiled).abs()
    shifts = [(full - tiled)[..., i * o:(i + 1) * o, j * o:(j + 1) * o].mean(dim=(2, 3))[0].tolist()
              for i in range(2) for j in range(2)]
    print(f"{name}: tiled(4x256) vs whole(512) mean abs diff = {diff.mean():.2f}/255, "
          f"per-tile mean RGB shift = {[[round(v, 2) for v in t] for t in shifts]}")


def _patch_dat_for_coreml():
    """DAT's window merge divides tensor shapes as floats, and coremltools casts 1-element
    arrays to int in a way NumPy 2 rejects. Pixora runs one fixed-size tile at a time."""
    import importlib
    import coremltools.converters.mil.frontend.torch.ops as ops
    from coremltools.converters.mil import Builder as mb
    dat = importlib.import_module("spandrel.architectures.DAT.__arch.DAT")

    def windows2img(img_splits_hw, H_sp, W_sp, H, W):
        img = img_splits_hw.view(1, H // H_sp, W // W_sp, H_sp, W_sp, -1)
        return img.permute(0, 1, 3, 2, 4, 5).contiguous().view(1, H, W, -1)
    dat.windows2img = windows2img
    if getattr(ops._cast, "_pixora", False):
        return
    orig = ops._cast

    def cast(context, node, dtype, dtype_name):
        x = ops._get_inputs(context, node, expected=1)[0]
        if x.can_be_folded_to_const() and np.size(x.val) == 1 and not isinstance(x.val, dtype):
            context.add(mb.const(val=dtype(np.asarray(x.val).reshape(-1)[0]), name=node.name), node.name)
            return
        return orig(context, node, dtype, dtype_name)
    cast._pixora = True
    ops._cast = cast


def convert_photo():
    # PIXORA_PHOTO_WEIGHTS / PIXORA_PHOTO_NAME export another checkpoint (a fine-tune in
    # training/experiments/*/models/*.safetensors, or NomosWebPhoto) instead of the stock one.
    weights = os.environ.get("PIXORA_PHOTO_WEIGHTS") or download(URL_PHOTO)
    name = os.environ.get("PIXORA_PHOTO_NAME", "Photo")
    net = _spandrel_load(weights)
    if type(net).__name__ == "DAT":
        _patch_dat_for_coreml()
        tile_seam_check(base.ImageWrapper(net).eval(), name, 4)
        desc = os.environ.get("PIXORA_PHOTO_DESC", "Pixora Photo 4x upscaler (4xBHI_dat2_real by Phhofm, CC-BY-4.0)")
        # "compute: gpu": the Neural Engine never finishes a DAT tile (attention); Pixora keeps it on the GPU.
        out = convert_fixed_sr(name, net, 4, desc, {"license": "CC-BY-4.0 4xBHI_dat2_real by Phhofm", "compute": "gpu"},
                               real=load_test_image(PARROT, TILE))
        unit_check(out, units=("CPU_AND_GPU",))
        return
    plk = sys.modules[type(net.feats[1].lk).__module__].PLKConv2d
    plk.forward = _plk_forward_noinplace
    # repeat_interleave(x, 16, dim=1) as per-channel expand+cat (same channel order, no
    # shape-derived ints, which coremltools cannot fold under torch 2.x tracing)
    r = 16
    net.repeat_op = lambda x: torch.cat([x[:, c:c + 1].expand(-1, r, -1, -1) for c in range(3)], dim=1)
    norms = sorted({type(m.norm).__name__ for m in net.feats if hasattr(m, "norm")})
    print(f"{name}: RealPLKSR norm layers = {norms}, upsampler = {type(net.to_img).__name__}")
    tile_seam_check(base.ImageWrapper(net).eval(), name, 4)
    desc = os.environ.get("PIXORA_PHOTO_DESC", "Pixora Photo 4x upscaler (RealPLKSR, CC-BY-4.0)")
    out = convert_fixed_sr(name, net, 4, desc,
                           {"license": "CC-BY-4.0, base RealPLKSR by Phhofm"},
                           real=load_test_image(PARROT, TILE))
    unit_check(out)


def _conv3xc_forward_eval(self, x):
    out = self.eval_conv(x)
    return F.leaky_relu(out, negative_slope=0.05) if self.has_relu else out


def convert_photo2x():
    net = _spandrel_load(download(URL_PHOTO2X))
    c3 = sys.modules[type(net.conv_1).__module__].Conv3XC
    for m in net.modules():
        if isinstance(m, c3):
            m.update_params()  # fuse the 1x1-3x3-1x1 + skip branches into eval_conv once
    c3.forward = _conv3xc_forward_eval
    out = convert_fixed_sr("Photo2x", net, 2,
                           "Pixora Photo 2x upscaler (2xNomosUni_span_multijpg_ldl by Phhofm, CC-BY-4.0)",
                           {"license": "CC-BY-4.0 2xNomosUni_span_multijpg_ldl by Phhofm"},
                           real=load_test_image(PARROT, TILE))
    unit_check(out)


# --------------------------------------------------------------------------- compute-unit hang check

UNITS = ("ALL", "CPU_AND_GPU", "CPU_AND_NE")


def _predict_once(path, unit):
    """Child process: load with a compute unit, run two predictions, print timings."""
    import time
    t0 = time.time()
    m = ct.models.MLModel(path, compute_units=getattr(ct.ComputeUnit, unit))
    t1 = time.time()
    feeds = {}
    for inp in m.get_spec().description.input:
        if inp.type.HasField("imageType"):
            it = inp.type.imageType
            feeds[inp.name] = Image.fromarray(rand_image(it.height)[: it.height, : it.width])
        else:
            feeds[inp.name] = np.array([0.5], np.float32)
    m.predict(feeds)
    t2 = time.time()
    m.predict(feeds)
    t3 = time.time()
    print(f"load {t1 - t0:.1f}s, first predict {t2 - t1:.2f}s, second predict {t3 - t2:.2f}s")


def unit_check(path, timeout=120, units=UNITS):
    import subprocess
    name = os.path.basename(path)
    for unit in units:
        try:
            r = subprocess.run([sys.executable, os.path.abspath(__file__), "--predict-once", path, unit],
                               capture_output=True, text=True, timeout=timeout)
            last = (r.stdout.strip().splitlines() or ["(no output)"])[-1]
            status = "OK" if r.returncode == 0 else f"FAILED rc={r.returncode}: {r.stderr.strip()[-300:]}"
            print(f"{name} [{unit}]: {status} {last if r.returncode == 0 else ''}")
        except subprocess.TimeoutExpired:
            print(f"{name} [{unit}]: HUNG (no result within {timeout}s, killed)")


# --------------------------------------------------------------------------- FaceRealistic (CodeFormer)

URL_CODEFORMER = "https://github.com/sczhou/CodeFormer/releases/download/v0.1.0/codeformer.pth"
CF_ARCH_RAW = "https://raw.githubusercontent.com/sczhou/CodeFormer/master/basicsr/archs"


def load_codeformer_arch():
    arch_dir = os.path.join(WEIGHTS_DIR, "codeformer_arch")
    for f in ("vqgan_arch.py", "codeformer_arch.py"):
        download(f"{CF_ARCH_RAW}/{f}", arch_dir)
    stub_basicsr()
    import importlib.util

    def load(modname, fname):
        spec = importlib.util.spec_from_file_location(modname, os.path.join(arch_dir, fname))
        mod = importlib.util.module_from_spec(spec)
        sys.modules[modname] = mod
        spec.loader.exec_module(mod)
        return mod

    vq = load("basicsr.archs.vqgan_arch", "vqgan_arch.py")
    vq.AttnBlock.forward = _vq_attn_forward_b1
    cf = load("codeformer_arch_mod", "codeformer_arch.py")
    cf.TransformerSALayer.forward = _sa_forward_b1
    return cf.CodeFormer


def _vq_attn_forward_b1(self, x):
    """vqgan AttnBlock without shape-derived ints (batch 1)."""
    c = self.in_channels
    h_ = self.norm(x)
    q = self.q(h_).reshape(1, c, -1).permute(0, 2, 1)
    k = self.k(h_).reshape(1, c, -1)
    v = self.v(h_).reshape(1, c, -1)
    w_ = F.softmax(torch.bmm(q, k) * (c ** -0.5), dim=2)
    h_ = torch.bmm(v, w_.permute(0, 2, 1)).reshape(x.shape)
    return x + self.proj_out(h_)


def _sa_forward_b1(self, tgt, tgt_mask=None, tgt_key_padding_mask=None, query_pos=None):
    """TransformerSALayer with nn.MultiheadAttention written out (batch 1, no masks, eval)."""
    a = self.self_attn
    e, nh = a.embed_dim, a.num_heads
    hd = e // nh
    t2 = self.norm1(tgt)[:, 0]                       # (L, E)
    qk = t2 + query_pos[:, 0]
    wq, wk, wv = a.in_proj_weight.chunk(3, dim=0)
    bq, bk, bv = a.in_proj_bias.chunk(3, dim=0)
    q = F.linear(qk, wq, bq).reshape(-1, nh, hd).transpose(0, 1)  # (H, L, hd)
    k = F.linear(qk, wk, bk).reshape(-1, nh, hd).transpose(0, 1)
    v = F.linear(t2, wv, bv).reshape(-1, nh, hd).transpose(0, 1)
    att = F.softmax(torch.matmul(q, k.transpose(1, 2)) * (hd ** -0.5), dim=-1)
    o = torch.matmul(att, v).transpose(0, 1).reshape(-1, e)
    tgt = tgt + a.out_proj(o).unsqueeze(1)
    tgt = tgt + self.linear2(self.activation(self.linear1(self.norm2(tgt))))
    return tgt


def _adain(content, style):
    """CodeFormer adaptive_instance_normalization (unbiased var, eps 1e-5) without aten::var."""
    def mean_std(f):
        m = f.mean(dim=(2, 3), keepdim=True)
        n = f.shape[2] * f.shape[3]
        var = ((f - m) ** 2).sum(dim=(2, 3), keepdim=True) / (n - 1) + 1e-5
        return m, var.sqrt()
    sm, ss = mean_std(style)
    cm, cs = mean_std(content)
    return (content - cm) / cs * ss + sm


def codeformer_run(net, x, w, codes_only=False):
    """CodeFormer.forward(x, w, adain=True) for batch 1 with a tensor `w`.

    topk(softmax(logits), 1) == argmax(logits); codebook lookup is an exact gather.
    """
    enc = {}
    enc_at = {net.fuse_encoder_block[f]: f for f in net.connect_list}
    for i, block in enumerate(net.encoder.blocks):
        x = block(x)
        if i in enc_at:
            assert x.shape[-1] == int(enc_at[i])
            enc[enc_at[i]] = x
    lq = x                                                     # (1, 256, 16, 16)
    pos = net.position_emb.unsqueeze(1)                        # (256, 1, 512)
    q = net.feat_emb(lq.flatten(2).permute(2, 0, 1))
    for layer in net.ft_layers:
        q = layer(q, query_pos=pos)
    logits = net.idx_pred_layer(q)[:, 0]                       # (256, 1024)
    idx = torch.argmax(logits, dim=1)                          # (256,)
    if codes_only:
        return idx
    quant = net.quantize.embedding.weight[idx]                 # (256, 256)
    quant = quant.reshape(1, 16, 16, 256).permute(0, 3, 1, 2)
    x = _adain(quant, lq)
    gen_at = {net.fuse_generator_block[f]: f for f in net.connect_list}
    for i, block in enumerate(net.generator.blocks):
        x = block(x)
        if i in gen_at:
            assert x.shape[-1] == int(gen_at[i])
            x = net.fuse_convs_dict[gen_at[i]](enc[gen_at[i]], x, w)
    return x, idx


class CodeFormerWrapper(nn.Module):
    def __init__(self, net, codes_only=False):
        super().__init__()
        self.net = net
        self.codes_only = codes_only

    def forward(self, x, fidelity):
        w = fidelity.reshape(1)
        if self.codes_only:
            return codeformer_run(self.net, x * 2.0 - 1.0, w, codes_only=True).to(torch.int32)
        out, _ = codeformer_run(self.net, x * 2.0 - 1.0, w)
        return (out.clamp(-1.0, 1.0) + 1.0) / 2.0 * 255.0


def convert_codeformer():
    CodeFormer = load_codeformer_arch()
    net = CodeFormer(dim_embd=512, codebook_size=1024, n_head=8, n_layers=9,
                     connect_list=["32", "64", "128", "256"])
    state = torch.load(download(URL_CODEFORMER), map_location="cpu", weights_only=True)
    net.load_state_dict(state["params_ema"], strict=True)
    net.eval()
    model = CodeFormerWrapper(net).eval()
    codes = CodeFormerWrapper(net, codes_only=True).eval()

    # Wrapper must match upstream CodeFormer.forward(x, w, adain=True).
    real = load_test_image(PORTRAIT, FACE)
    tests = {"random": rand_image(FACE, seed=2)}
    if real is not None:
        tests["portrait"] = real
    with torch.no_grad():
        xt = to_tensor(tests.get("portrait", tests["random"]))
        for w in (0.0, 0.5, 1.0):
            up = net(xt * 2 - 1, w=w, adain=True)[0]
            up = (up.clamp(-1, 1) + 1) / 2 * 255
            mine = model(xt, torch.tensor([w]))
            assert (up - mine).abs().max() < 0.5, f"wrapper mismatch at w={w}: {(up - mine).abs().max()}"

    ex = (torch.rand(1, 3, FACE, FACE), torch.tensor([0.5]))
    with torch.no_grad():
        traced = torch.jit.trace(model, ex)
        traced_codes = torch.jit.trace(codes, ex)
    ws = (0.0, 0.5, 1.0)
    with torch.no_grad():
        refs = {(k, w): model(to_tensor(v), torch.tensor([w]))[0].permute(1, 2, 0).numpy()
                for k, v in tests.items() for w in ws}
        ref_codes = {k: codes(to_tensor(v), torch.tensor([0.5])).numpy() for k, v in tests.items()}

    def io():
        d = image_io((1, 3, FACE, FACE))
        d["inputs"].append(ct.TensorType(name="fidelity", shape=(1,), dtype=np.float32))
        return d

    fp32_ops = {"pow", "square", "reduce_sum", "reduce_mean", "rsqrt", "sqrt", "real_div",
                "softmax", "layer_norm", "instance_norm", "batch_norm", "reduce_argmax"}
    mixed = ct.transform.FP16ComputePrecision(op_selector=lambda op: op.op_type not in fp32_ops)
    for precision, label in ((ct.precision.FLOAT16, "FP16"), (mixed, "FP16+FP32norm"),
                             (ct.precision.FLOAT32, "FP32")):
        # Code-index check: same graph prefix converted with the same precision policy.
        cm = ct.convert(traced_codes, inputs=io()["inputs"], outputs=[ct.TensorType(name="codes")],
                        compute_precision=precision, minimum_deployment_target=ct.target.macOS14,
                        convert_to="mlprogram")
        match = {}
        for k, arr in tests.items():
            got = np.asarray(cm.predict({"input": Image.fromarray(arr),
                                         "fidelity": np.array([0.5], np.float32)})["codes"]).reshape(-1)
            match[k] = float((got == ref_codes[k]).mean())
            print(f"FaceRealistic[{label}] {k}: code indices matching PyTorch = {match[k] * 100:.1f}% of 256")

        mlmodel = ct.convert(traced, **io(), compute_precision=precision,
                             minimum_deployment_target=ct.target.macOS14, convert_to="mlprogram")
        mlmodel.short_description = ("Pixora realistic face restoration (CodeFormer, S-Lab License 1.0 - "
                                     "NON-COMMERCIAL), 512x512 aligned face")
        mlmodel.input_description["fidelity"] = "CodeFormer w, 0..1: 0 = strongest restoration, 1 = most faithful"
        mlmodel.user_defined_metadata["size"] = str(FACE)
        mlmodel.user_defined_metadata["fidelity_input"] = "1"
        mlmodel.user_defined_metadata["precision"] = label
        mlmodel.user_defined_metadata["license"] = "S-Lab License 1.0 (non-commercial)"
        out = save(mlmodel, "FaceRealistic")
        diffs = []
        for k, arr in tests.items():
            for w in ws:
                pred = mlpredict(out, {"input": Image.fromarray(arr), "fidelity": np.array([w], np.float32)})
                diffs.append(np.abs(pred - refs[(k, w)]).mean())
                print(f"FaceRealistic[{label}] {k} w={w:.1f}: output {pred.shape}, "
                      f"mean abs diff vs fp32 PyTorch = {diffs[-1]:.2f}/255")
        if max(diffs) < 2.0 and min(match.values()) == 1.0:
            print(f"FaceRealistic: saved {out} ({label})")
            return
        print(f"FaceRealistic: {label} failed (diff or code mismatch), trying next precision")
    print("FaceRealistic: WARNING FP32 also failed checks; kept FP32 model")


STEPS = {"Standard2x": convert_standard2x, "LowRes": convert_lowres, "FaceRestore": convert_face,
         "HighFidelity": convert_highfidelity, "FaceRealistic": convert_codeformer,
         "Photo": convert_photo, "Photo2x": convert_photo2x}

if __name__ == "__main__":
    if sys.argv[1:2] == ["--predict-once"]:
        _predict_once(sys.argv[2], sys.argv[3])
        sys.exit(0)
    if sys.argv[1:2] == ["--unit-check"]:
        for p in sys.argv[2:]:
            unit_check(os.path.join(OUT_DIR, f"{p}.mlpackage"))
        sys.exit(0)
    torch.manual_seed(0)
    for name in sys.argv[1:] or list(STEPS):
        STEPS[name]()
