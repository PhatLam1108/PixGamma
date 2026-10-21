"""Run traiNNer-redux on the Apple Silicon GPU (MPS).

traiNNer-redux assumes CUDA in a few utility calls (memory stats, device info, cache).
This launcher swaps those for MPS equivalents, then runs train.py unchanged.
Model placement on MPS comes from patches/traiNNer-mps.patch (TRAINNER_MPS=1, num_gpu: 0).

Usage (from training/traiNNer-redux):
  PYTORCH_ENABLE_MPS_FALLBACK=1 .venv/bin/python ../train_mps.py -opt ../configs/phase1_trial.yml
"""
import os
import runpy
import sys
from types import SimpleNamespace

os.environ.setdefault("TRAINNER_MPS", "1")
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import torch  # noqa: E402

if not torch.backends.mps.is_available():
    sys.exit("MPS không khả dụng trên máy này.")

c = torch.cuda
c.empty_cache = torch.mps.empty_cache
c.synchronize = torch.mps.synchronize
c.set_per_process_memory_fraction = lambda *a, **k: None
c.max_memory_allocated = lambda *a, **k: torch.mps.driver_allocated_memory()
c.reset_peak_memory_stats = lambda *a, **k: None
c.current_device = lambda: 0
c.set_device = lambda *a, **k: None
c.is_bf16_supported = lambda *a, **k: False
c.get_device_properties = lambda *a, **k: SimpleNamespace(
    name="Apple Silicon GPU (MPS)", total_memory=torch.mps.recommended_max_memory(),
    major=0, minor=0, multi_processor_count=0,
)

sys.argv[0] = "train.py"
sys.path.insert(0, os.getcwd())
runpy.run_path("train.py", run_name="__main__")
