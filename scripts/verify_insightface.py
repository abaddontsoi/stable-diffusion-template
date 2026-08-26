#!/usr/bin/env python3
"""Build-time checks for ReActor / InsightFace dependencies and models."""
from __future__ import annotations

import os
import sys

WEBUI_ROOT = os.environ.get("WEBUI_ROOT", "/stable-diffusion-webui")
INSIGHTFACE_HOME = os.environ.get("INSIGHTFACE_HOME", "/opt/insightface")


def main() -> None:
    import numpy

    print(f"numpy {numpy.__version__}")
    if not numpy.__version__.startswith("1."):
        print(
            f"ERROR: numpy {numpy.__version__} is incompatible with onnxruntime-gpu==1.17.1 "
            "(expect numpy 1.26.x; numpy 2.x → AttributeError: _ARRAY_API not found)",
            file=sys.stderr,
        )
        sys.exit(1)

    import insightface
    import onnxruntime as ort

    assert insightface.__version__ == "0.7.3", insightface.__version__

    providers = ort.get_available_providers()
    print(f"onnxruntime providers: {providers}")
    # At image build there is often no GPU — CPUExecutionProvider is enough to prove ORT loads.
    # On the pod, CUDAExecutionProvider must appear (pre_start.sh re-checks when GPU is present).
    assert "CPUExecutionProvider" in providers or "CUDAExecutionProvider" in providers

    # Ensure CPU-only onnxruntime package is not installed alongside gpu
    try:
        import importlib.metadata as md

        dists = {d.metadata["Name"].lower() for d in md.distributions()}
    except Exception:
        dists = set()

    # pip name for the GPU wheel is still imported as `onnxruntime`
    if "onnxruntime" in dists and "onnxruntime-gpu" not in dists:
        # Pure CPU package only — fail so we don't ship a CPU-shadowed image
        print("ERROR: installed package is onnxruntime (CPU), expected onnxruntime-gpu", file=sys.stderr)
        sys.exit(1)

    swap = os.path.join(WEBUI_ROOT, "models", "insightface", "inswapper_128.onnx")
    buffalo = os.path.join(INSIGHTFACE_HOME, "models", "buffalo_l", "det_10g.onnx")
    for path in (swap, buffalo):
        if not os.path.isfile(path):
            print(f"ERROR: missing model file: {path}", file=sys.stderr)
            sys.exit(1)
        size = os.path.getsize(path)
        if size < 1_000_000:
            print(f"ERROR: model too small ({size}): {path}", file=sys.stderr)
            sys.exit(1)

    last_device = os.path.join(WEBUI_ROOT, "extensions", "sd-webui-reactor", "last_device.txt")
    with open(last_device) as f:
        device = f.read().strip()
    assert device == "CUDA", f"last_device.txt={device!r}"

    print("insightface OK")
    print(f"inswapper: {swap} ({os.path.getsize(swap)} bytes)")
    print(f"buffalo_l: {os.path.dirname(buffalo)}")
    print("verify_insightface: PASS")


if __name__ == "__main__":
    main()
