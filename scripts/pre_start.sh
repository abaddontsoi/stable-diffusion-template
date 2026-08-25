#!/usr/bin/env bash
# Runs before WebUI: persist models, repair ORT/ultralytics, refill missing assets.
set -euo pipefail

WEBUI_ROOT="${WEBUI_ROOT:-/stable-diffusion-webui}"
WORKSPACE="${WORKSPACE:-/workspace}"
VENV="${WEBUI_ROOT}/venv"
ORT_CUDA12_INDEX="${ORT_CUDA12_INDEX:-https://aiinfra.pkgs.visualstudio.com/PublicPackages/_packaging/onnxruntime-cuda-12/pypi/simple/}"

source "${VENV}/bin/activate"

# Persist outputs / checkpoints on RunPod network volume when present
if [[ -d "${WORKSPACE}" ]]; then
  mkdir -p \
    "${WORKSPACE}/models/Stable-diffusion" \
    "${WORKSPACE}/models/Lora" \
    "${WORKSPACE}/models/insightface" \
    "${WORKSPACE}/models/adetailer" \
    "${WORKSPACE}/outputs" \
    "${WORKSPACE}/embeddings"

  link_dir() {
    local src="$1"
    local dest="$2"
    mkdir -p "${dest}"
    if [[ -d "${src}" && ! -L "${src}" ]]; then
      shopt -s nullglob
      for item in "${src}"/*; do
        base=$(basename "${item}")
        if [[ ! -e "${dest}/${base}" ]]; then
          cp -a "${item}" "${dest}/" 2>/dev/null || true
        fi
      done
      shopt -u nullglob
      rm -rf "${src}"
    fi
    ln -sfn "${dest}" "${src}"
  }

  link_dir "${WEBUI_ROOT}/models/Stable-diffusion" "${WORKSPACE}/models/Stable-diffusion"
  link_dir "${WEBUI_ROOT}/models/Lora" "${WORKSPACE}/models/Lora"
  link_dir "${WEBUI_ROOT}/models/insightface" "${WORKSPACE}/models/insightface"
  link_dir "${WEBUI_ROOT}/models/adetailer" "${WORKSPACE}/models/adetailer"
  link_dir "${WEBUI_ROOT}/outputs" "${WORKSPACE}/outputs"
fi

# Re-download assets if wiped
if [[ ! -f "${WEBUI_ROOT}/models/insightface/inswapper_128.onnx" ]] \
  || [[ ! -f /root/.insightface/models/buffalo_l/det_10g.onnx ]]; then
  echo "[pre_start] InsightFace models missing — downloading..."
  /usr/local/bin/download_insightface_models.sh || true
fi

if [[ ! -f "${WEBUI_ROOT}/models/adetailer/face_yolov8n.pt" ]]; then
  echo "[pre_start] ADetailer models missing — downloading..."
  /usr/local/bin/download_adetailer_models.sh || true
fi

echo "CUDA" > "${WEBUI_ROOT}/extensions/sd-webui-reactor/last_device.txt"

# Repair numpy + ultralytics + onnxruntime if something drifted versions
python - <<'PY'
import subprocess, sys

ORT_IDX = "https://aiinfra.pkgs.visualstudio.com/PublicPackages/_packaging/onnxruntime-cuda-12/pypi/simple/"
ULTRA_PIN = "ultralytics==8.3.75"
NUMPY_PIN = "numpy==1.26.4"

def pip_list() -> str:
    return subprocess.check_output([sys.executable, "-m", "pip", "list"], text=True)

def pkg_line(name: str, listing: str) -> str | None:
    needle = name.lower() + " "
    for line in listing.splitlines():
        if line.lower().startswith(needle):
            return line
    return None

listing = pip_list()

# numpy 2.x breaks onnxruntime-gpu 1.17.1 (_ARRAY_API not found)
np_line = pkg_line("numpy", listing)
print("[pre_start]", np_line or "numpy MISSING")
need_numpy = True
if np_line:
    parts = np_line.split()
    need_numpy = len(parts) < 2 or not parts[1].startswith("1.26.")
if need_numpy:
    print(f"[pre_start] Reinstalling {NUMPY_PIN} ...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "--force-reinstall", "--no-deps", NUMPY_PIN])

ultra = pkg_line("ultralytics", pip_list())
print("[pre_start]", ultra or "ultralytics MISSING")

need_ultra = True
if ultra:
    parts = ultra.split()
    need_ultra = len(parts) < 2 or parts[1] != "8.3.75"

if need_ultra:
    print(f"[pre_start] Reinstalling {ULTRA_PIN} ...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", ULTRA_PIN, "mediapipe>=0.10.13", "rich>=13", "pydantic<3"])
    # ultralytics may bump numpy again
    subprocess.check_call([sys.executable, "-m", "pip", "install", "--force-reinstall", "--no-deps", NUMPY_PIN])

# ORT check (ultralytics / adetailer install often pulls CPU onnxruntime)
ort_ok = False
providers = []
try:
    import onnxruntime as ort
    providers = ort.get_available_providers()
    print("[pre_start] onnxruntime providers:", providers)
    ort_ok = True
except Exception as e:
    print("[pre_start] onnxruntime import failed:", e)
    providers = []

listing = pip_list()
has_cpu = bool(pkg_line("onnxruntime", listing))
has_gpu = bool(pkg_line("onnxruntime-gpu", listing))
print(f"[pre_start] pip onnxruntime={has_cpu} onnxruntime-gpu={has_gpu}")

need_ort = (not ort_ok) or ("CUDAExecutionProvider" not in providers) or has_cpu or not has_gpu
if need_ort:
    print("[pre_start] Reinstalling onnxruntime-gpu==1.17.1 (CUDA 12 index)...")
    subprocess.check_call([sys.executable, "-m", "pip", "uninstall", "-y", "onnxruntime", "onnxruntime-gpu"])
    subprocess.check_call([
        sys.executable, "-m", "pip", "install", "onnxruntime-gpu==1.17.1",
        "--extra-index-url", ORT_IDX,
    ])
    import importlib
    import onnxruntime as ort2
    importlib.reload(ort2)
    print("[pre_start] providers after fix:", ort2.get_available_providers())

from ultralytics import YOLO  # noqa: F401
print("[pre_start] ultralytics.YOLO OK")
import insightface  # noqa: F401
print("[pre_start] insightface OK", insightface.__version__)
PY

echo "[pre_start] done"
