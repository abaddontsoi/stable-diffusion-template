#!/usr/bin/env bash
# Sourced by webui.sh — keep torch + setuptools pins aligned with A1111.
# A1111 expects setuptools==69.5.1 (pkg_resources; setuptools>=81 breaks CLIP).
# CLIP is preinstalled with --no-build-isolation --no-use-pep517; keep pip flags set.
export venv_dir="venv"
export python_cmd="python"
export TORCH_COMMAND="pip install torch==2.4.1 torchvision==0.19.1 --index-url https://download.pytorch.org/whl/cu124"
export COMMANDLINE_ARGS="${COMMANDLINE_ARGS:-}"
export PIP_CONSTRAINT="${PIP_CONSTRAINT:-/etc/pip-constraints-a1111.txt}"
export CLIP_PACKAGE="${CLIP_PACKAGE:-https://github.com/openai/CLIP/archive/d50d76daa670286dd6cacf3bcd80b5e4823fc8e1.zip}"
export PIP_NO_BUILD_ISOLATION="${PIP_NO_BUILD_ISOLATION:-1}"
export PIP_USE_PEP517="${PIP_USE_PEP517:-0}"
# Official Stability-AI repo is gone; use community mirror (A1111 env override)
export STABLE_DIFFUSION_REPO="${STABLE_DIFFUSION_REPO:-https://github.com/w-e-w/stablediffusion.git}"
