#!/bin/zsh
# Builds PixGamma's Recover model set: Realistic Vision 5.1 (SD 1.5) + ControlNet Tile, Core ML.
# Output: generative/models.nosync/rv51-tile/Resources, linked as PixGamma/Models/Recover.
set -e
cd "$(dirname "$0")"
if [ ! -d ml-stable-diffusion.nosync ]; then
  git clone --depth 1 https://github.com/apple/ml-stable-diffusion.git ml-stable-diffusion.nosync
  ln -sfn ml-stable-diffusion.nosync ml-stable-diffusion
  (cd ml-stable-diffusion && git apply ../patches/ml-stable-diffusion.patch)
fi
cd ml-stable-diffusion
if [ ! -x .venv/bin/python ]; then
  uv venv -q --python 3.11 .venv
  # torch 2.4.x is the newest version coremltools 8.1 is tested with.
  uv pip install -q --python .venv/bin/python "torch==2.4.1" "torchvision==0.19.1" "coremltools==8.1" "numpy<1.24" -e .
fi
mkdir -p ../models.nosync/rv51-tile
.venv/bin/python -W ignore -m python_coreml_stable_diffusion.torch2coreml \
  --model-version SG161222/Realistic_Vision_V5.1_noVAE --custom-vae-version stabilityai/sd-vae-ft-mse \
  --convert-unet --unet-support-controlnet --convert-controlnet lllyasviel/control_v11f1e_sd15_tile \
  --convert-text-encoder --convert-vae-decoder --convert-vae-encoder \
  --attention-implementation ORIGINAL --compute-unit CPU_AND_GPU --bundle-resources-for-swift-cli \
  -o ../models.nosync/rv51-tile
ln -sfn "../../generative/models.nosync/rv51-tile/Resources" ../../PixGamma/Models/Recover
echo "✓ Recover: PixGamma/Models/Recover"
