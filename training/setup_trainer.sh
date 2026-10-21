#!/bin/bash
# Clones traiNNer-redux (Apache-2.0), applies Pixora's Apple-GPU patch and installs it.
# The clone lives in training/traiNNer-redux.nosync (kept out of iCloud) with a symlink.
set -euo pipefail
cd "$(dirname "$0")"
if [ ! -d traiNNer-redux.nosync ]; then
  git clone --depth 1 https://github.com/the-database/traiNNer-redux traiNNer-redux.nosync
  ln -sfn traiNNer-redux.nosync traiNNer-redux
fi
cd traiNNer-redux.nosync
git apply --check ../patches/traiNNer-mps.patch 2>/dev/null && git apply ../patches/traiNNer-mps.patch || echo "patch đã áp dụng hoặc không khớp phiên bản"
[ -d .venv ] || uv venv --python 3.12 -q .venv
VIRTUAL_ENV=$PWD/.venv uv pip install -q --index-strategy unsafe-best-match torch torchvision
VIRTUAL_ENV=$PWD/.venv uv pip install -q --index-strategy unsafe-best-match -e .
.venv/bin/python -c 'import torch; print("torch", torch.__version__, "MPS", torch.backends.mps.is_available())'
