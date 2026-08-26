#!/usr/bin/env bash
# Runs before WebUI: persist models, heal venv/CLIP, repair ORT/ultralytics, refill assets.
set -euo pipefail

WEBUI_ROOT="${WEBUI_ROOT:-/stable-diffusion-webui}"
WORKSPACE="${WORKSPACE:-/workspace}"
RUN_USER="${RUN_USER:-runpod}"
VENV="${WEBUI_ROOT}/venv"
# Never use /workspace/venv — that path is ignored on purpose
ORT_CUDA12_INDEX="${ORT_CUDA12_INDEX:-https://aiinfra.pkgs.visualstudio.com/PublicPackages/_packaging/onnxruntime-cuda-12/pypi/simple/}"
INSIGHTFACE_HOME="${INSIGHTFACE_HOME:-/opt/insightface}"
CLIP_PACKAGE="${CLIP_PACKAGE:-https://github.com/openai/CLIP/archive/d50d76daa670286dd6cacf3bcd80b5e4823fc8e1.zip}"
export PIP_NO_BUILD_ISOLATION="${PIP_NO_BUILD_ISOLATION:-1}"
export PIP_USE_PEP517="${PIP_USE_PEP517:-0}"

if [[ ! -x "${VENV}/bin/python" ]]; then
  echo "[pre_start] ERROR: missing ${VENV}/bin/python — image venv required" >&2
  exit 1
fi

# Soft-heal pip / setuptools / packaging / CLIP (avoid A1111 PEP517 zip install crash)
heal_clip_stack() {
  local py="${VENV}/bin/python"
  if ! "${py}" -m pip --version >/dev/null 2>&1; then
    echo "[pre_start] pip broken — ensurepip..."
    "${py}" -m ensurepip --upgrade || true
  fi
  "${py}" -m pip install -U "pip==25.2" "setuptools==69.5.1" "wheel==0.45.1" "packaging" || true

  if ! "${py}" -c "import pkg_resources" >/dev/null 2>&1; then
    echo "[pre_start] pkg_resources missing — reinstalling setuptools==69.5.1..."
    "${py}" -m pip install --force-reinstall "setuptools==69.5.1"
  fi

  if ! "${py}" -c "import clip" >/dev/null 2>&1; then
    echo "[pre_start] clip missing — installing with --no-build-isolation --no-use-pep517..."
    "${py}" -m pip install --no-build-isolation --no-use-pep517 "${CLIP_PACKAGE}"
  fi

  # HF_HUB_ENABLE_HF_TRANSFER=1 requires hf_transfer in the A1111 venv
  if ! "${py}" -c "import hf_transfer" >/dev/null 2>&1; then
    echo "[pre_start] hf_transfer missing — installing..."
    if ! "${py}" -m pip install -U hf_transfer; then
      echo "[pre_start] hf_transfer install failed — will disable HF transfer in start.sh" >&2
    fi
  fi

  "${py}" -c "import pkg_resources, clip, packaging; print('[pre_start] clip/pkg_resources/packaging OK')"
  if "${py}" -c "import hf_transfer" >/dev/null 2>&1; then
    echo "[pre_start] hf_transfer OK"
  else
    echo "[pre_start] hf_transfer still missing"
  fi
}

heal_clip_stack

source "${VENV}/bin/activate"

# Persist outputs / checkpoints on RunPod network volume when present
if [[ -d "${WORKSPACE}" ]]; then
  mkdir -p \
    "${WORKSPACE}/models/Stable-diffusion" \
    "${WORKSPACE}/models/Lora" \
    "${WORKSPACE}/models/insightface" \
    "${WORKSPACE}/models/reactor/faces" \
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
  link_dir "${WEBUI_ROOT}/models/reactor" "${WORKSPACE}/models/reactor"
  link_dir "${WEBUI_ROOT}/models/adetailer" "${WORKSPACE}/models/adetailer"
  link_dir "${WEBUI_ROOT}/outputs" "${WORKSPACE}/outputs"

  # pre_start runs as root; WebUI (runpod) must write face models + volume assets
  if id -u "${RUN_USER}" >/dev/null 2>&1; then
    chown -R "${RUN_USER}:${RUN_USER}" "${WORKSPACE}" 2>/dev/null || true
  fi
else
  # No network volume — still ensure ReActor face-model dir exists (reactor_globals skips faces/ if reactor/ exists)
  mkdir -p "${WEBUI_ROOT}/models/reactor/faces"
fi

# Re-download assets if wiped (support legacy /root/.insightface path)
BUFFALO_OK=0
if [[ -f "${INSIGHTFACE_HOME}/models/buffalo_l/det_10g.onnx" ]] \
  || [[ -f /root/.insightface/models/buffalo_l/det_10g.onnx ]]; then
  BUFFALO_OK=1
fi
if [[ ! -f "${WEBUI_ROOT}/models/insightface/inswapper_128.onnx" ]] || [[ "${BUFFALO_OK}" -eq 0 ]]; then
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
