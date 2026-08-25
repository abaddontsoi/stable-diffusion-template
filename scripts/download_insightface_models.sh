#!/usr/bin/env bash
# Pre-download InsightFace models so ReActor does not fail on first use.
set -euo pipefail

WEBUI_ROOT="${WEBUI_ROOT:-/stable-diffusion-webui}"
INSIGHTFACE_HOME="${INSIGHTFACE_HOME:-/root/.insightface}"

SWAP_DIR="${WEBUI_ROOT}/models/insightface"
BUFFALO_DIR="${INSIGHTFACE_HOME}/models"
mkdir -p "${SWAP_DIR}" "${BUFFALO_DIR}"

INSWAPPER_URL="${INSWAPPER_URL:-https://huggingface.co/datasets/Gourieff/ReActor/resolve/main/models/inswapper_128.onnx}"
BUFFALO_URL="${BUFFALO_URL:-https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip}"

INSWAPPER_PATH="${SWAP_DIR}/inswapper_128.onnx"
BUFFALO_ZIP="/tmp/buffalo_l.zip"

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

if [[ ! -f "${INSWAPPER_PATH}" ]]; then
  download "${INSWAPPER_URL}" "${INSWAPPER_PATH}"
else
  echo "inswapper_128.onnx already present"
fi

# Expected size ~555MB; reject tiny / HTML error pages
INSWAPPER_SIZE=$(stat -c%s "${INSWAPPER_PATH}" 2>/dev/null || stat -f%z "${INSWAPPER_PATH}")
if [[ "${INSWAPPER_SIZE}" -lt 100000000 ]]; then
  echo "ERROR: inswapper_128.onnx looks corrupt (${INSWAPPER_SIZE} bytes)" >&2
  exit 1
fi

if [[ ! -d "${BUFFALO_DIR}/buffalo_l" ]] || [[ ! -f "${BUFFALO_DIR}/buffalo_l/det_10g.onnx" ]]; then
  download "${BUFFALO_URL}" "${BUFFALO_ZIP}"
  # Official zip unpacks ONNX files flat (no buffalo_l/ folder). Normalize layout.
  TMP_BUFFALO="$(mktemp -d)"
  unzip -o "${BUFFALO_ZIP}" -d "${TMP_BUFFALO}"
  rm -f "${BUFFALO_ZIP}"

  mkdir -p "${BUFFALO_DIR}/buffalo_l"

  # Case A: zip contains buffalo_l/*
  if [[ -d "${TMP_BUFFALO}/buffalo_l" ]]; then
    cp -a "${TMP_BUFFALO}/buffalo_l/." "${BUFFALO_DIR}/buffalo_l/"
  # Case B: zip contains models/buffalo_l/*
  elif [[ -d "${TMP_BUFFALO}/models/buffalo_l" ]]; then
    cp -a "${TMP_BUFFALO}/models/buffalo_l/." "${BUFFALO_DIR}/buffalo_l/"
  # Case C: flat *.onnx at zip root (actual GitHub release layout)
  else
    shopt -s nullglob
    onnx_files=("${TMP_BUFFALO}"/*.onnx)
    if [[ ${#onnx_files[@]} -eq 0 ]]; then
      # one more nested level sometimes
      onnx_files=("${TMP_BUFFALO}"/*/*.onnx)
    fi
    if [[ ${#onnx_files[@]} -eq 0 ]]; then
      echo "ERROR: no .onnx files found in buffalo_l.zip" >&2
      find "${TMP_BUFFALO}" -maxdepth 3 -type f | head -50 >&2
      rm -rf "${TMP_BUFFALO}"
      exit 1
    fi
    cp -a "${onnx_files[@]}" "${BUFFALO_DIR}/buffalo_l/"
    shopt -u nullglob
  fi

  # Cleanup accidental flat extracts into models/ from older runs
  for f in det_10g.onnx w600k_r50.onnx 2d106det.onnx genderage.onnx 1k3d68.onnx; do
    if [[ -f "${BUFFALO_DIR}/${f}" ]] && [[ -f "${BUFFALO_DIR}/buffalo_l/${f}" ]]; then
      rm -f "${BUFFALO_DIR}/${f}"
    fi
  done

  rm -rf "${TMP_BUFFALO}"
else
  echo "buffalo_l already present"
fi

# Required ONNX files inside buffalo_l
for f in det_10g.onnx w600k_r50.onnx 2d106det.onnx genderage.onnx 1k3d68.onnx; do
  if [[ ! -f "${BUFFALO_DIR}/buffalo_l/${f}" ]]; then
    echo "ERROR: missing buffalo_l/${f}" >&2
    exit 1
  fi
done

# Also expose buffalo under WebUI models tree (some forks look here)
mkdir -p "${SWAP_DIR}/models"
if [[ ! -e "${SWAP_DIR}/models/buffalo_l" ]]; then
  ln -sfn "${BUFFALO_DIR}/buffalo_l" "${SWAP_DIR}/models/buffalo_l"
fi

echo "InsightFace models ready:"
ls -lh "${INSWAPPER_PATH}"
ls -lh "${BUFFALO_DIR}/buffalo_l" | head
