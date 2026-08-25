#!/usr/bin/env bash
# Sourced by webui.sh — keep torch install command stable so WebUI does not
# reinstall packages that can pull CPU onnxruntime back in.
export venv_dir="venv"
export python_cmd="python"
export TORCH_COMMAND="pip install torch==2.4.1 torchvision==0.19.1 --index-url https://download.pytorch.org/whl/cu124"
# CLI flags are passed from /start.sh; keep this empty to avoid duplicates
export COMMANDLINE_ARGS="${COMMANDLINE_ARGS:-}"
