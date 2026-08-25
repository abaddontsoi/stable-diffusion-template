#!/usr/bin/env bash
# Pre-download ADetailer YOLO detectors (avoids HF download failures on first use).
set -euo pipefail

WEBUI_ROOT="${WEBUI_ROOT:-/stable-diffusion-webui}"
AD_DIR="${WEBUI_ROOT}/models/adetailer"
mkdir -p "${AD_DIR}"

BASE_URL="${ADETAILER_HF_BASE:-https://huggingface.co/Bingsu/adetailer/resolve/main}"

MODELS=(
  face_yolov8n.pt
  face_yolov8s.pt
  hand_yolov8n.pt
  person_yolov8n-seg.pt
  person_yolov8s-seg.pt
)

download() {
  local url="$1"
  local out="$2"
  echo "Downloading: ${url}"
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --retry 5 --retry-delay 3 -o "${out}" "${url}"
  else
    wget -O "${out}" "${url}"
  fi
}

for name in "${MODELS[@]}"; do
  dest="${AD_DIR}/${name}"
  if [[ -f "${dest}" ]]; then
    size=$(stat -c%s "${dest}" 2>/dev/null || stat -f%z "${dest}")
    if [[ "${size}" -gt 100000 ]]; then
      echo "already present: ${name}"
      continue
    fi
    rm -f "${dest}"
  fi
  download "${BASE_URL}/${name}" "${dest}"
  size=$(stat -c%s "${dest}" 2>/dev/null || stat -f%z "${dest}")
  if [[ "${size}" -lt 100000 ]]; then
    echo "ERROR: ${name} looks corrupt (${size} bytes)" >&2
    exit 1
  fi
done

echo "ADetailer models ready:"
ls -lh "${AD_DIR}"
