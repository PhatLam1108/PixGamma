# Model licenses and attributions

Core ML models in this folder are converted, unmodified-weight copies of the open-source
models below (conversion: `tools/convert_models.py`, `tools/convert_extra.py`).

## CC-BY-4.0 (attribution required)

| PixGamma model | Original model | Author | License | Source |
|---|---|---|---|---|
| PhotoV1.mlpackage | PixGamma Photo v1 (used for text regions): PixGamma fine-tune of 4xBHI_dat2_real (DAT2) on filtered CC0 photos and synthetic text (`training/configs/photo1.yml`) | Fine-tune: PixGamma; base model: Philip Hofmann (Phhofm / Helaman) | CC-BY-4.0 | Base: https://huggingface.co/Phips/4xBHI_dat2_real |
| Text.mlpackage | PixGamma fine-tune of 4xNomosWebPhoto_RealPLKSR on synthetic Vietnamese/English text (`training/make_text_dataset.py`, `training/configs/text.yml`, then `text2.yml`, then `text3.yml`) | Fine-tune: PixGamma; base model: Philip Hofmann (Phhofm / Helaman) | CC-BY-4.0 | Base: https://github.com/Phhofm/models/releases/tag/4xNomosWebPhoto_RealPLKSR |
| Photo2x.mlpackage | 2xNomosUni_span_multijpg_ldl | Philip Hofmann (Phhofm / Helaman) | CC-BY-4.0 | https://github.com/Phhofm/models/releases/tag/2xNomosUni_span_multijpg_ldl (https://openmodeldb.info/models/2x-NomosUni-span-multijpg-ldl) |

Changes: converted from PyTorch to Core ML (FP16), wrapped to take/return 8-bit RGB images.
PhotoV1.mlpackage (DAT2) is marked GPU-only; its window merge is rewritten for batch 1 (same math).
Until 0.2.0, Photo.mlpackage was 4xNomosWebPhoto_RealPLKSR (same author and license); the Text model is still a fine-tune of it.
Photo v2 (Photo.mlpackage in 0.3.x) had PhotoV1's weights trained 15,000 more iterations with a light GAN; Photo v3 replaces it.
PhotoV1.mlpackage has fine-tuned weights (15,000 iterations, Charbonnier + MS-SSIM + LDL + focal frequency + DISTS, no GAN).
Text.mlpackage additionally has fine-tuned weights (8,000 + 12,000 + 8,000 iterations, Charbonnier + MS-SSIM + Sobel + LDL, then focal frequency + gradient variance + line distiller).
License text: https://creativecommons.org/licenses/by/4.0/

## CC-BY-NC-SA-4.0 (attribution, non-commercial, share-alike)

| PixGamma model | Original model | Author | License | Source |
|---|---|---|---|---|
| Photo.mlpackage | PixGamma Photo v7: Photo v6 trained further with a GAN at 0.06 and DISTS at 0.3 (`training/configs/photo7.yml`). Photo v6: Photo v4 trained further with twice the share of clean tiles and clean fur close-ups (`training/configs/photo6.yml`). Photo v4: Photo v3 trained further on CC0 close-ups of feathers, hair and skin with a very light GAN (`training/configs/photo4.yml`). Photo v3: PixGamma fine-tune of 4x-UltraSharpV2 (DAT2) on filtered CC0 photos, clean bicubic tiles and synthetic text (`training/configs/photo3_us2.yml`) | Fine-tune: PixGamma; base model: Kim2091 | CC-BY-NC-SA-4.0 | Base: https://huggingface.co/Kim2091/UltraSharpV2 |

Changes: Photo v3 is 15,000 iterations from the UltraSharpV2 weights (Charbonnier + MS-SSIM + LDL + focal frequency + DISTS 0.25, no GAN);
Photo v4 adds 12,000 iterations from v3 with the same losses plus a vanilla GAN at 0.03 (U-Net discriminator);
Photo v6 adds 12,000 iterations from v4 with the same losses and more clean tiles;
Photo v7 adds 12,000 iterations from v6 on the same data with the GAN at 0.06 and DISTS at 0.3. All are
then converted to Core ML (FP16) and wrapped to take/return 8-bit RGB images; marked GPU-only, window merge rewritten
for batch 1 (same math). The last residual group's conv and skip are divided by 512 so FP16 does not overflow; the
LayerNorm after it ignores scale, so the output is the same.
The fine-tuned Photo v3, v4, v6 and v7 weights are shared under the same license (CC-BY-NC-SA-4.0): free for non-commercial use, with
attribution to Kim2091 and PixGamma. License text: https://creativecommons.org/licenses/by-nc-sa/4.0/

## Other licenses

| PixGamma model | Original model | Author | License | Source |
|---|---|---|---|---|
| Standard, ArtCGI, LowRes, Standard2x, HighFidelity | RealESRGAN_x4plus, RealESRGAN_x4plus_anime_6B, realesr-general-x4v3 + realesr-general-wdn-x4v3, RealESRGAN_x2plus, RealESRNet_x4plus | Xintao Wang et al. | BSD-3-Clause | https://github.com/xinntao/Real-ESRGAN |
| FaceRestore | GFPGAN v1.4 | Tencent ARC (Xintao Wang et al.) | Apache-2.0 | https://github.com/TencentARC/GFPGAN |
| FaceRealistic | CodeFormer | Shangchen Zhou et al., S-Lab, NTU | S-Lab License 1.0 (NON-COMMERCIAL use only) | https://github.com/sczhou/CodeFormer |

## Recover (diffusion), built with `generative/convert_recover.sh`

| PixGamma model | Original model | Author | License | Source |
|---|---|---|---|---|
| Recover/ControlledUnet, TextEncoder | Realistic Vision V5.1 (noVAE), a Stable Diffusion 1.5 fine-tune | SG161222 | CreativeML OpenRAIL-M | https://huggingface.co/SG161222/Realistic_Vision_V5.1_noVAE |
| Recover/VAEEncoder, VAEDecoder | sd-vae-ft-mse | Stability AI | MIT | https://huggingface.co/stabilityai/sd-vae-ft-mse |
| Recover/controlnet/LllyasvielControlV11F1ESd15Tile | ControlNet 1.1 Tile | Lvmin Zhang (lllyasviel) | CreativeML OpenRAIL-M | https://huggingface.co/lllyasviel/control_v11f1e_sd15_tile |

OpenRAIL-M carries use restrictions (no illegal or harmful use, no impersonation, and so on);
they pass on to anyone using these weights. Converted to Core ML with Apple's ml-stable-diffusion.

