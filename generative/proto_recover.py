"""Prototype of Pixora Recover (PyTorch/MPS) to tune quality before the Core ML port.

Pipeline:
  1. photo network upscale (4xNomosWebPhoto RealPLKSR) to the target size
  2. tiled VAE encode -> latent canvas, noised to `strength`
  3. MultiDiffusion denoise: at every step each overlapping 64x64 latent window runs
     ControlNet Tile + UNet (CFG); noise predictions are feather-averaged into one canvas
     and a single scheduler step is taken on the whole canvas, so tiles never disagree
  4. tiled VAE decode with feathered blending
  5. low-frequency colour from the network output (keeps tone exactly)

Usage:
  .venv/bin/python ../proto_recover.py --input a.jpg --scale 4 --out out.png \
      [--model SG161222/Realistic_Vision_V5.1_noVAE] [--strength 0.5] [--cn 0.7]
"""
import argparse
import math
import time

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image

DEV = "mps"
DT = torch.float16
TILE_L = 64            # latent tile (512 px)
STRIDE_L = 48          # latent stride (128 px overlap)

PROMPT = ("high quality photograph, sharp focus, highly detailed, realistic skin texture, "
          "natural hair strands, fine fabric fibres, film grain, natural lighting")
NEG = ("blurry, painting, illustration, cartoon, cgi, 3d render, oversmoothed, plastic skin, waxy, "
       "watermark, text, deformed, jpeg artifacts, oversharpened, halo, lowres")


def windows(n, tile, stride):
    if n <= tile:
        return [0]
    o = list(range(0, n - tile, stride))
    o.append(n - tile)
    return o


def feather(h, w, ov, top, bottom, left, right, device):
    y = torch.ones(h, device=device)
    x = torch.ones(w, device=device)
    r = torch.arange(ov, device=device, dtype=torch.float32)
    ramp = (r + 0.5) / ov
    if not top: y[:ov] = torch.minimum(y[:ov], ramp)
    if not bottom: y[-ov:] = torch.minimum(y[-ov:], ramp.flip(0))
    if not left: x[:ov] = torch.minimum(x[:ov], ramp)
    if not right: x[-ov:] = torch.minimum(x[-ov:], ramp.flip(0))
    return (y[:, None] * x[None, :])


def photo_upscale(img, scale, weights="../../tools/weights/4xNomosWebPhoto_RealPLKSR.pth"):
    import spandrel
    m = spandrel.ModelLoader().load_from_file(weights).model.eval().to(DEV)
    x = torch.from_numpy(np.asarray(img)).permute(2, 0, 1)[None].float().div(255).to(DEV)
    _, _, h, w = x.shape
    out = torch.zeros(1, 3, h * 4, w * 4, device=DEV)
    t, p = 192, 16
    with torch.inference_mode():
        for y in range(0, h, t):
            for x0 in range(0, w, t):
                y1, x1 = min(y + t, h), min(x0 + t, w)
                ya, xa, yb, xb = max(y - p, 0), max(x0 - p, 0), min(y1 + p, h), min(x1 + p, w)
                o = m(x[..., ya:yb, xa:xb]).clamp(0, 1)
                out[..., y * 4:y1 * 4, x0 * 4:x1 * 4] = o[..., (y - ya) * 4:(y1 - ya) * 4, (x0 - xa) * 4:(x1 - xa) * 4]
    arr = (out[0].permute(1, 2, 0).cpu().numpy() * 255).round().astype(np.uint8)
    up = Image.fromarray(arr)
    tw, th = int(img.width * scale), int(img.height * scale)
    return up.resize((tw, th), Image.LANCZOS) if up.size != (tw, th) else up


def flow_smooth(img, amount, sigma=3.0, length=9):
    """Coherence-enhancing smoothing: average along the local stroke direction (structure
    tensor minor eigenvector), weighted by coherence, so broken hair strands become
    continuous lines without blurring across them."""
    from scipy import ndimage
    a = np.asarray(img).astype(np.float32) / 255
    g = a.mean(2)
    gx = ndimage.sobel(g, 1); gy = ndimage.sobel(g, 0)
    jxx = ndimage.gaussian_filter(gx * gx, sigma); jyy = ndimage.gaussian_filter(gy * gy, sigma)
    jxy = ndimage.gaussian_filter(gx * gy, sigma)
    tmp = np.sqrt((jxx - jyy) ** 2 + 4 * jxy ** 2)
    l1 = (jxx + jyy + tmp) / 2; l2 = (jxx + jyy - tmp) / 2
    coh = ((l1 - l2) / (l1 + l2 + 1e-6)) ** 2
    theta = 0.5 * np.arctan2(2 * jxy, jxx - jyy) + np.pi / 2   # along the stroke
    dx, dy = np.cos(theta), np.sin(theta)
    H, W = g.shape
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    acc = np.zeros_like(a); wsum = 0
    for t in np.linspace(-length / 2, length / 2, length):
        w = np.exp(-(t / (length / 3)) ** 2)
        coords = [yy + t * dy, xx + t * dx]
        for c in range(3):
            acc[..., c] += w * ndimage.map_coordinates(a[..., c], coords, order=1, mode="nearest")
        wsum += w
    smooth = acc / wsum
    k = (amount * coh)[..., None]
    return Image.fromarray(((a * (1 - k) + smooth * k).clip(0, 1) * 255).round().astype(np.uint8))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--scale", type=float, default=4)
    ap.add_argument("--model", default="stable-diffusion-v1-5/stable-diffusion-v1-5")
    ap.add_argument("--vae", default=None)
    ap.add_argument("--strength", type=float, default=0.5)
    ap.add_argument("--cn", type=float, default=0.7, help="ControlNet Tile conditioning scale")
    ap.add_argument("--cfg", type=float, default=5.0)
    ap.add_argument("--steps", type=int, default=24)
    ap.add_argument("--prompt", default=PROMPT)
    ap.add_argument("--seed", type=int, default=1108)
    ap.add_argument("--save-base", default=None)
    ap.add_argument("--base", default="photo", choices=["photo", "lanczos", "esrnet"])
    ap.add_argument("--neg-extra", default="")
    ap.add_argument("--flat-hold", type=float, default=0, help="fraction of steps flat areas stay on the base")
    ap.add_argument("--flat-std", type=float, default=0.03)
    ap.add_argument("--flow", type=float, default=0, help="flow-aligned smoothing strength of the base (hair)")
    a = ap.parse_args()

    from diffusers import AutoencoderKL, ControlNetModel, DPMSolverMultistepScheduler, StableDiffusionControlNetPipeline

    t0 = time.time()
    src = Image.open(a.input).convert("RGB")
    if a.base == "photo":
        base = photo_upscale(src, a.scale)
    elif a.base == "esrnet":
        base = photo_upscale(src, a.scale, "../../tools/weights/RealESRNet_x4plus.pth")
    else:
        base = src.resize((int(src.width * a.scale), int(src.height * a.scale)), Image.LANCZOS)
    if a.flow > 0:
        base = flow_smooth(base, a.flow)
    W, H = base.width // 8 * 8, base.height // 8 * 8
    base = base.crop((0, 0, W, H))
    if a.save_base:
        base.save(a.save_base)
    print(f"base {W}x{H} in {time.time() - t0:.1f}s")

    cn = ControlNetModel.from_pretrained("lllyasviel/control_v11f1e_sd15_tile", torch_dtype=DT)
    kw = {}
    if a.vae:
        kw["vae"] = AutoencoderKL.from_pretrained(a.vae, torch_dtype=DT)
    pipe = StableDiffusionControlNetPipeline.from_pretrained(a.model, controlnet=cn, torch_dtype=DT,
                                                             safety_checker=None, **kw).to(DEV)
    sched = DPMSolverMultistepScheduler.from_config(pipe.scheduler.config, use_karras_sigmas=True,
                                                    algorithm_type="sde-dpmsolver++")
    unet, vae, ctrl = pipe.unet, pipe.vae, pipe.controlnet

    with torch.inference_mode():
        emb, neg = pipe.encode_prompt(a.prompt, DEV, 1, True, NEG + (", " + a.neg_extra if a.neg_extra else ""))
        cond = torch.cat([neg, emb])

        img = torch.from_numpy(np.asarray(base)).permute(2, 0, 1)[None].to(DEV, DT) / 255
        Hl, Wl = H // 8, W // 8
        ys, xs = windows(Hl, TILE_L, STRIDE_L), windows(Wl, TILE_L, STRIDE_L)
        ov = TILE_L - STRIDE_L

        # Tiled VAE encode (latent-space feather blend).
        lat = torch.zeros(1, 4, Hl, Wl, device=DEV, dtype=torch.float32)
        wsum = torch.zeros(1, 1, Hl, Wl, device=DEV)
        for y in ys:
            for x in xs:
                h, w = min(TILE_L, Hl - y), min(TILE_L, Wl - x)
                patch = img[..., y * 8:(y + h) * 8, x * 8:(x + w) * 8] * 2 - 1
                z = vae.encode(patch).latent_dist.mean.float() * vae.config.scaling_factor
                f = feather(h, w, ov, y == 0, y + h >= Hl, x == 0, x + w >= Wl, DEV)
                lat[..., y:y + h, x:x + w] += z * f
                wsum[..., y:y + h, x:x + w] += f
        lat /= wsum

        sched.set_timesteps(a.steps, device=DEV)
        start = int(a.steps * (1 - a.strength))
        timesteps = sched.timesteps[start:]
        g = torch.Generator("cpu").manual_seed(a.seed)
        noise = torch.randn(lat.shape, generator=g).to(DEV)
        latents = sched.add_noise(lat, noise, timesteps[:1])
        sched.set_begin_index(start) if hasattr(sched, "set_begin_index") else None

        print(f"{len(ys) * len(xs)} tiles x {len(timesteps)} steps")
        flat = None
        if a.flat_hold > 0:
            g = img.float().mean(1, keepdim=True)
            k = 17
            mu = F.avg_pool2d(F.pad(g, (k // 2,) * 4, mode="reflect"), k, 1)
            var = F.avg_pool2d(F.pad(g * g, (k // 2,) * 4, mode="reflect"), k, 1) - mu * mu
            std = var.clamp(min=0).sqrt()
            flat = (1 - (std / a.flat_std).clamp(0, 1)) ** 2  # 1 where the base is flat
            flat = F.interpolate(flat, size=(Hl, Wl), mode="area")
            flat = F.avg_pool2d(F.pad(flat, (2, 2, 2, 2), mode="replicate"), 5, 1)
            hold_steps = max(1, round(len(timesteps) * a.flat_hold))
        for i, t in enumerate(timesteps):
            eps = torch.zeros_like(latents)
            ws = torch.zeros(1, 1, Hl, Wl, device=DEV)
            for y in ys:
                for x in xs:
                    h, w = min(TILE_L, Hl - y), min(TILE_L, Wl - x)
                    lt = latents[..., y:y + h, x:x + w]
                    li = sched.scale_model_input(torch.cat([lt, lt]), t).to(DT)
                    ci = img[..., y * 8:(y + h) * 8, x * 8:(x + w) * 8]
                    ci = torch.cat([ci, ci])
                    down, mid = ctrl(li, t, encoder_hidden_states=cond, controlnet_cond=ci,
                                     conditioning_scale=a.cn, return_dict=False)
                    n = unet(li, t, encoder_hidden_states=cond, down_block_additional_residuals=down,
                             mid_block_additional_residual=mid, return_dict=False)[0].float()
                    nu, nt = n.chunk(2)
                    n = nu + a.cfg * (nt - nu)
                    f = feather(h, w, ov, y == 0, y + h >= Hl, x == 0, x + w >= Wl, DEV)
                    eps[..., y:y + h, x:x + w] += n * f
                    ws[..., y:y + h, x:x + w] += f
            latents = sched.step(eps / ws, t, latents).prev_sample
            if flat is not None and i < hold_steps and i + 1 < len(timesteps):
                ref = sched.add_noise(lat, noise, timesteps[i + 1:i + 2])
                latents = latents + flat * (ref - latents)
            print(f"  step {i + 1}/{len(timesteps)}  {time.time() - t0:.0f}s", flush=True)

        # Tiled VAE decode (pixel-space feather blend).
        out = torch.zeros(1, 3, H, W, device=DEV)
        wp = torch.zeros(1, 1, H, W, device=DEV)
        for y in ys:
            for x in xs:
                h, w = min(TILE_L, Hl - y), min(TILE_L, Wl - x)
                d = vae.decode((latents[..., y:y + h, x:x + w] / vae.config.scaling_factor).to(DT)).sample.float()
                f = feather(h * 8, w * 8, ov * 8, y == 0, y + h >= Hl, x == 0, x + w >= Wl, DEV)
                out[..., y * 8:(y + h) * 8, x * 8:(x + w) * 8] += (d.clamp(-1, 1) + 1) / 2 * f
                wp[..., y * 8:(y + h) * 8, x * 8:(x + w) * 8] += f
        out /= wp

        # Keep the network's low-frequency colour/tone.
        k = max(9, int(min(W, H) / 64) | 1)
        blur = lambda z: F.avg_pool2d(F.pad(z, (k // 2,) * 4, mode="reflect"), k, 1)
        out = (out + blur(img.float()) - blur(out)).clamp(0, 1)

    arr = (out[0].permute(1, 2, 0).cpu().numpy() * 255).round().astype(np.uint8)
    Image.fromarray(arr).save(a.out)
    print(f"done {a.out} in {time.time() - t0:.0f}s")


if __name__ == "__main__":
    main()
