#!/usr/bin/env bash
set -euo pipefail

export WEBUI_ROOT="${WEBUI_ROOT:-/stable-diffusion-webui}"
export WORKSPACE="${WORKSPACE:-/workspace}"
# Helps ultralytics / ADetailer load YOLO .pt under stricter torch.load defaults
export TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD="${TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD:-1}"

/pre_start.sh

cd "${WEBUI_ROOT}"
# webui.sh activates venv itself; ensure executable
chmod +x webui.sh || true

exec bash webui.sh \
  --listen \
  --port 3000 \
  --enable-insecure-extension-access \
  --api \
  --xformers \
  ${CLI_ARGS:-}
