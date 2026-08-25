#!/usr/bin/env python3
"""Build-time checks for ADetailer / ultralytics."""
from __future__ import annotations

import os
import sys
from importlib.metadata import PackageNotFoundError, version

WEBUI_ROOT = os.environ.get("WEBUI_ROOT", "/stable-diffusion-webui")
REQUIRED_MODELS = (
    "face_yolov8n.pt",
    "face_yolov8s.pt",
    "hand_yolov8n.pt",
    "person_yolov8n-seg.pt",
    "person_yolov8s-seg.pt",
)


def pkg_version(name: str) -> str:
    try:
        return version(name)
    except PackageNotFoundError as e:
        raise SystemExit(f"ERROR: missing package {name}") from e


def main() -> None:
    ultra_v = pkg_version("ultralytics")
    print(f"ultralytics {ultra_v}")
    # ADetailer install.py requires >= 8.3.75
    from packaging.version import parse

    if parse(ultra_v) < parse("8.3.75"):
        raise SystemExit(f"ERROR: ultralytics {ultra_v} < 8.3.75")

    for name in ("mediapipe", "rich", "pydantic"):
        print(f"{name} {pkg_version(name)}")

    from ultralytics import YOLO  # noqa: F401

    print("ultralytics.YOLO import OK")

    ad_dir = os.path.join(WEBUI_ROOT, "models", "adetailer")
    for name in REQUIRED_MODELS:
        path = os.path.join(ad_dir, name)
        if not os.path.isfile(path):
            raise SystemExit(f"ERROR: missing ADetailer model: {path}")
        if os.path.getsize(path) < 100_000:
            raise SystemExit(f"ERROR: model too small: {path}")

    # ultralytics must not have replaced ORT with CPU-only wheel
    import onnxruntime as ort

    providers = ort.get_available_providers()
    print(f"onnxruntime providers after ADetailer deps: {providers}")

    print("verify_adetailer: PASS")


if __name__ == "__main__":
    main()
