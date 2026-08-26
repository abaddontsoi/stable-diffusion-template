# A1111 + ReActor + ADetailer for RunPod
# InsightFace: baked models + onnxruntime-gpu (CUDA 12) only
# ADetailer: pinned ultralytics + baked YOLO weights; ORT re-pinned AFTER ultralytics

ARG BASE_IMAGE=runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04
FROM ${BASE_IMAGE}

# Stability-AI/stablediffusion is private/removed; A1111 uses STABLE_DIFFUSION_REPO
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    WEBUI_ROOT=/stable-diffusion-webui \

    HF_HUB_ENABLE_HF_TRANSFER=1 \
    TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD=1 \
    ORT_CUDA12_INDEX=https://aiinfra.pkgs.visualstudio.com/PublicPackages/_packaging/onnxruntime-cuda-12/pypi/simple/ \
    STABLE_DIFFUSION_REPO=https://github.com/w-e-w/stablediffusion.git

# OpenCV / build deps + RunPod Connect (nginx, SSH) + gosu for non-root A1111
RUN apt-get update && apt-get install -y --no-install-recommends \
        git wget curl unzip \
        libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 \
        libxcb1 libgtk-3-0 \
        build-essential python3-dev python3-venv \
        nginx openssh-server \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/run/sshd /run/nginx /opt/insightface \
    && useradd -m -u 1000 -s /bin/bash runpod \
    && curl -fsSL -o /usr/local/bin/gosu \
         "https://github.com/tianon/gosu/releases/download/1.17/gosu-amd64" \
    && chmod +x /usr/local/bin/gosu \
    && gosu nobody true

ARG WEBUI_VERSION=v1.10.1
ARG REACTOR_REPO=https://codeberg.org/Gourieff/sd-webui-reactor.git
ARG REACTOR_REF=main
ARG ADETAILER_REPO=https://github.com/Bing-su/adetailer.git
ARG ADETAILER_REF=main

# --- Automatic1111 WebUI (https://github.com/AUTOMATIC1111/stable-diffusion-webui) ---
# CLIP needs pkg_resources (removed in setuptools>=81). A1111 itself pins
# setuptools==69.5.1 in launch_utils / requirements — match that exactly.
# Stability-AI/stablediffusion is gone → STABLE_DIFFUSION_REPO mirror (w-e-w).
# A1111 requirements_versions.txt pins numpy==1.26.2; our PIP_CONSTRAINT is
# numpy==1.26.4 (ORT) — rewrite the pin before pip install or ResolutionImpossible.
ARG CLIP_PACKAGE=https://github.com/openai/CLIP/archive/d50d76daa670286dd6cacf3bcd80b5e4823fc8e1.zip
ARG WEBUI_REPO=https://github.com/AUTOMATIC1111/stable-diffusion-webui.git
RUN git clone --depth 1 --branch ${WEBUI_VERSION} \
        ${WEBUI_REPO} ${WEBUI_ROOT} \
    && cd ${WEBUI_ROOT} \
    && python -m venv venv \
    && . venv/bin/activate \
    && pip install "pip==25.2" "setuptools==69.5.1" "wheel==0.45.1" "numpy==1.26.4" \
    && printf 'setuptools==69.5.1\npip==25.2\nnumpy==1.26.4\n' > /etc/pip-constraints-a1111.txt \
    && export PIP_CONSTRAINT=/etc/pip-constraints-a1111.txt \
    && export STABLE_DIFFUSION_REPO="${STABLE_DIFFUSION_REPO}" \
    && sed -i 's/numpy==1\.26\.2/numpy==1.26.4/g' requirements_versions.txt \
    && pip install torch==2.4.1 torchvision==0.19.1 --index-url https://download.pytorch.org/whl/cu124 \
    && pip install -r requirements_versions.txt \
    && pip install xformers==0.0.28.post1 --index-url https://download.pytorch.org/whl/cu124 \
    && pip install --no-build-isolation --no-use-pep517 "${CLIP_PACKAGE}" \
    && python -c "import pkg_resources, clip; print('clip+pkg_resources OK')" \
    && python launch.py --skip-torch-cuda-test --skip-python-version-check --exit \
    && python -c "import pkg_resources, clip; print('clip still OK after launch.py')" \
    && pip cache purge

ENV PIP_CONSTRAINT=/etc/pip-constraints-a1111.txt \
    CLIP_PACKAGE=https://github.com/openai/CLIP/archive/d50d76daa670286dd6cacf3bcd80b5e4823fc8e1.zip \
    STABLE_DIFFUSION_REPO=https://github.com/w-e-w/stablediffusion.git \
    INSIGHTFACE_HOME=/opt/insightface

# --- Extensions: ReActor + ADetailer ---
RUN cd ${WEBUI_ROOT}/extensions \
    && git clone --depth 1 ${REACTOR_REPO} sd-webui-reactor \
    && cd sd-webui-reactor && (git checkout ${REACTOR_REF} 2>/dev/null || true) \
    && cd ${WEBUI_ROOT}/extensions \
    && git clone --depth 1 ${ADETAILER_REPO} adetailer \
    && cd adetailer && (git checkout ${ADETAILER_REF} 2>/dev/null || true)

# --- InsightFace stack (ReActor) ---
# Never leave CPU `onnxruntime` installed — it hides CUDAExecutionProvider
RUN . ${WEBUI_ROOT}/venv/bin/activate \
    && pip uninstall -y onnxruntime onnxruntime-gpu 2>/dev/null || true \
    && pip install \
        insightface==0.7.3 \
        onnx==1.16.1 \
        "albumentations==1.4.3" \
        "opencv-python>=4.7.0.72" \
        tqdm packaging \
    && pip install onnxruntime-gpu==1.17.1 --extra-index-url ${ORT_CUDA12_INDEX} \
    && pip cache purge

# --- ADetailer stack (ultralytics) ---
# Pin to install.py floor (8.3.75). Avoid very new ultralytics that break YOLO .pt loads.
# ultralytics may pull CPU onnxruntime — we re-pin ORT-GPU in the next layer.
RUN . ${WEBUI_ROOT}/venv/bin/activate \
    && pip install \
        "ultralytics==8.3.75" \
        "mediapipe>=0.10.13" \
        "rich>=13" \
        "pydantic<3" \
        "huggingface-hub" \
        "py-cpuinfo" \
    && pip cache purge

# --- FINAL: pin numpy<2 + onnxruntime-gpu (must be last pip step) ---
# ultralytics/mediapipe often pull numpy 2.x → ORT 1.17.1 then dies with:
#   AttributeError: _ARRAY_API not found
RUN . ${WEBUI_ROOT}/venv/bin/activate \
    && pip install --force-reinstall --no-deps "numpy==1.26.4" \
    && pip uninstall -y onnxruntime onnxruntime-gpu 2>/dev/null || true \
    && pip install onnxruntime-gpu==1.17.1 --extra-index-url ${ORT_CUDA12_INDEX} \
    && pip uninstall -y onnxruntime 2>/dev/null || true \
    && pip install onnxruntime-gpu==1.17.1 --extra-index-url ${ORT_CUDA12_INDEX} \
    && python -c "import numpy; assert numpy.__version__.startswith('1.26'), numpy.__version__; import onnxruntime as ort; print('numpy', numpy.__version__, 'providers', ort.get_available_providers())" \
    && pip cache purge

# Force ReActor onto CUDA
RUN echo "CUDA" > ${WEBUI_ROOT}/extensions/sd-webui-reactor/last_device.txt

# --- Bake models ---
COPY --chmod=755 scripts/download_insightface_models.sh /usr/local/bin/download_insightface_models.sh
COPY --chmod=755 scripts/download_adetailer_models.sh /usr/local/bin/download_adetailer_models.sh
RUN . ${WEBUI_ROOT}/venv/bin/activate \
    && download_insightface_models.sh \
    && download_adetailer_models.sh

# Build-time sanity checks
COPY scripts/verify_insightface.py /tmp/verify_insightface.py
COPY scripts/verify_adetailer.py /tmp/verify_adetailer.py
RUN . ${WEBUI_ROOT}/venv/bin/activate \
    && python /tmp/verify_insightface.py \
    && python /tmp/verify_adetailer.py \
    && rm /tmp/verify_insightface.py /tmp/verify_adetailer.py

COPY a1111/webui-user.sh ${WEBUI_ROOT}/webui-user.sh
COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY --chmod=755 scripts/start.sh /start.sh
COPY --chmod=755 scripts/pre_start.sh /pre_start.sh

# Jupyter for RunPod Connect :8888; ownership for non-root A1111
RUN pip install --no-cache-dir jupyterlab \
    && mkdir -p /var/log/nginx /workspace /opt/insightface /var/log \
    && (rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true) \
    && chown -R runpod:runpod ${WEBUI_ROOT} /workspace /opt/insightface \
    && touch /var/log/a1111.log /jupyter.log \
    && chown runpod:runpod /var/log/a1111.log /jupyter.log

# Entrypoint stays root (nginx/ssh); start.sh drops to runpod for A1111
WORKDIR ${WEBUI_ROOT}
EXPOSE 22 3000 3001 8888

SHELL ["/bin/bash", "--login", "-c"]
CMD ["/start.sh"]
