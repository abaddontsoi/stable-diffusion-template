#!/usr/bin/env bash
# RunPod-style entrypoint (mirrors runpod/containers + ashleykleynhans SD templates):
#   A1111 :3000 (non-root) → nginx :3001 | Jupyter :8888 | SSH | sleep infinity
set -euo pipefail

export WEBUI_ROOT="${WEBUI_ROOT:-/stable-diffusion-webui}"
export WORKSPACE="${WORKSPACE:-/workspace}"
export TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD="${TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD:-1}"
export STABLE_DIFFUSION_REPO="${STABLE_DIFFUSION_REPO:-https://github.com/w-e-w/stablediffusion.git}"
export INSIGHTFACE_HOME="${INSIGHTFACE_HOME:-/opt/insightface}"
export CLIP_PACKAGE="${CLIP_PACKAGE:-https://github.com/openai/CLIP/archive/d50d76daa670286dd6cacf3bcd80b5e4823fc8e1.zip}"
export PIP_CONSTRAINT="${PIP_CONSTRAINT:-/etc/pip-constraints-a1111.txt}"
export PIP_NO_BUILD_ISOLATION="${PIP_NO_BUILD_ISOLATION:-1}"
export PIP_USE_PEP517="${PIP_USE_PEP517:-0}"
export RUN_USER="${RUN_USER:-runpod}"
# Default matches Dockerfile; start_webui may force 0 if hf_transfer is missing
export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-1}"

ensure_hf_transfer() {
  local py="${WEBUI_ROOT}/venv/bin/python"
  if [[ "${HF_HUB_ENABLE_HF_TRANSFER}" != "1" ]]; then
    return 0
  fi
  if [[ -x "${py}" ]] && "${py}" -c "import hf_transfer" >/dev/null 2>&1; then
    echo "[start] hf_transfer available — HF_HUB_ENABLE_HF_TRANSFER=1"
    return 0
  fi
  if [[ -x "${py}" ]] && "${py}" -m pip install -U hf_transfer >/dev/null 2>&1 \
    && "${py}" -c "import hf_transfer" >/dev/null 2>&1; then
    echo "[start] installed hf_transfer into A1111 venv"
    return 0
  fi
  echo "[start] hf_transfer missing — disabling HF_HUB_ENABLE_HF_TRANSFER (fallback to default HF downloads)"
  export HF_HUB_ENABLE_HF_TRANSFER=0
}

wait_for_upstream() {
  local host="${1:-127.0.0.1}"
  local port="${2:-3000}"
  local timeout="${3:-600}"
  local i=0
  echo "[start] Waiting for A1111 upstream ${host}:${port} (timeout ${timeout}s)..."
  while (( i < timeout )); do
    if curl -sf -o /dev/null --connect-timeout 1 "http://${host}:${port}/" \
      || curl -sf -o /dev/null --connect-timeout 1 "http://${host}:${port}/internal/ping" 2>/dev/null; then
      echo "[start] Upstream ready after ${i}s"
      return 0
    fi
    # Accept TCP open even if HTTP not ready yet (Gradio still loading)
    if (echo >/dev/tcp/${host}/${port}) >/dev/null 2>&1; then
      echo "[start] Upstream port open after ${i}s (HTTP may still be loading)"
      return 0
    fi
    sleep 2
    i=$((i + 2))
  done
  echo "[start] WARNING: upstream ${host}:${port} not ready after ${timeout}s — starting nginx anyway" >&2
  return 0
}

start_nginx() {
  echo "[start] Starting nginx (3001 → 3000)..."
  if command -v service >/dev/null 2>&1; then
    service nginx start || nginx
  else
    nginx
  fi
}

setup_ssh() {
  if [[ -z "${PUBLIC_KEY:-}" ]]; then
    echo "[start] PUBLIC_KEY not set — skipping SSH setup"
    return 0
  fi
  echo "[start] Setting up SSH..."
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  touch /root/.ssh/authorized_keys
  if ! grep -qxF "${PUBLIC_KEY}" /root/.ssh/authorized_keys 2>/dev/null; then
    echo "${PUBLIC_KEY}" >> /root/.ssh/authorized_keys
  fi
  chmod 600 /root/.ssh/authorized_keys

  for type in rsa ecdsa ed25519; do
    key="/etc/ssh/ssh_host_${type}_key"
    if [[ ! -f "${key}" ]]; then
      ssh-keygen -t "${type}" -f "${key}" -q -N ''
    fi
  done

  if command -v service >/dev/null 2>&1; then
    service ssh start || /usr/sbin/sshd || true
  else
    /usr/sbin/sshd || true
  fi
}

start_jupyter() {
  if [[ "${DISABLE_JUPYTER:-}" == "1" ]]; then
    echo "[start] Jupyter disabled (DISABLE_JUPYTER=1)"
    return 0
  fi

  mkdir -p "${WORKSPACE}"

  local token_args=()
  if [[ -n "${JUPYTER_PASSWORD:-}" ]]; then
    token_args=(--IdentityProvider.token="${JUPYTER_PASSWORD}")
    echo "[start] Starting Jupyter Lab on :8888 (token from JUPYTER_PASSWORD)..."
  else
    token_args=(--IdentityProvider.token='' --ServerApp.password='')
    echo "[start] Starting Jupyter Lab on :8888 (no token)..."
  fi

  local py=python
  if ! "${py}" -c "import jupyterlab" 2>/dev/null; then
    if [[ -x "${WEBUI_ROOT}/venv/bin/python" ]] \
      && "${WEBUI_ROOT}/venv/bin/python" -c "import jupyterlab" 2>/dev/null; then
      py="${WEBUI_ROOT}/venv/bin/python"
    else
      echo "[start] Installing jupyterlab..."
      pip install -q jupyterlab || "${WEBUI_ROOT}/venv/bin/pip" install -q jupyterlab || true
    fi
  fi

  # Prefer non-root Jupyter; fall back to --allow-root
  if [[ "$(id -u)" -eq 0 ]] && id -u "${RUN_USER}" >/dev/null 2>&1; then
    local jcmd=()
    if command -v gosu >/dev/null 2>&1; then
      jcmd=(gosu "${RUN_USER}")
    else
      jcmd=(runuser -u "${RUN_USER}" --)
    fi
    nohup "${jcmd[@]}" "${py}" -m jupyter lab \
      --no-browser \
      --port=8888 \
      --ip=0.0.0.0 \
      --FileContentsManager.delete_to_trash=False \
      --ServerApp.terminado_settings='{"shell_command":["/bin/bash"]}' \
      --ServerApp.allow_origin='*' \
      --ServerApp.preferred_dir="${WORKSPACE}" \
      "${token_args[@]}" \
      &>/jupyter.log &
  else
    nohup "${py}" -m jupyter lab \
      --allow-root \
      --no-browser \
      --port=8888 \
      --ip=0.0.0.0 \
      --FileContentsManager.delete_to_trash=False \
      --ServerApp.terminado_settings='{"shell_command":["/bin/bash"]}' \
      --ServerApp.allow_origin='*' \
      --ServerApp.preferred_dir="${WORKSPACE}" \
      "${token_args[@]}" \
      &>/jupyter.log &
  fi
  echo "[start] Jupyter Lab launched (log: /jupyter.log)"
}

start_webui() {
  if [[ "${DISABLE_AUTOLAUNCH:-}" == "1" ]]; then
    echo "[start] WebUI autolaunch disabled (DISABLE_AUTOLAUNCH=1)"
    return 0
  fi

  echo "[start] Launching A1111 WebUI on :3000 as ${RUN_USER}..."
  ensure_hf_transfer
  cd "${WEBUI_ROOT}"
  chmod +x webui.sh || true
  chown -R "${RUN_USER}:${RUN_USER}" "${WEBUI_ROOT}" "${INSIGHTFACE_HOME}" 2>/dev/null || true
  touch /var/log/a1111.log
  chown "${RUN_USER}:${RUN_USER}" /var/log/a1111.log 2>/dev/null || true

  # Inline drop-privileges — nohup cannot invoke a shell function
  local launcher=(bash -c)
  if [[ "$(id -u)" -eq 0 ]] && id -u "${RUN_USER}" >/dev/null 2>&1; then
    if command -v gosu >/dev/null 2>&1; then
      launcher=(gosu "${RUN_USER}" bash -c)
    else
      launcher=(runuser -u "${RUN_USER}" -- bash -c)
    fi
  fi

  # Never use a shared /workspace/venv — A1111 uses $WEBUI_ROOT/venv via webui-user.sh
  # shellcheck disable=SC2086
  nohup "${launcher[@]}" "
    cd '${WEBUI_ROOT}'
    export PIP_CONSTRAINT='${PIP_CONSTRAINT}'
    export PIP_NO_BUILD_ISOLATION='${PIP_NO_BUILD_ISOLATION}'
    export PIP_USE_PEP517='${PIP_USE_PEP517}'
    export CLIP_PACKAGE='${CLIP_PACKAGE}'
    export STABLE_DIFFUSION_REPO='${STABLE_DIFFUSION_REPO}'
    export TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD='${TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD}'
    export INSIGHTFACE_HOME='${INSIGHTFACE_HOME}'
    export HF_HUB_ENABLE_HF_TRANSFER='${HF_HUB_ENABLE_HF_TRANSFER}'
    exec bash webui.sh \
      --listen \
      --port 3000 \
      --enable-insecure-extension-access \
      --api \
      --xformers \
      ${CLI_ARGS:-}
  " &>/var/log/a1111.log &
  echo "[start] WebUI launched (log: /var/log/a1111.log)"
}

export_env_vars() {
  printenv | grep -E '^[A-Z_][A-Z0-9_]*=' | grep -v '^PUBLIC_KEY' \
    | awk -F= '{
        val=$0; sub(/^[^=]*=/,"",val);
        gsub(/\\/,"\\\\",val); gsub(/"/,"\\\"",val);
        print "export " $1 "=\"" val "\""
      }' > /etc/rp_environment
  if ! grep -q 'source /etc/rp_environment' /root/.bashrc 2>/dev/null; then
    echo 'source /etc/rp_environment' >> /root/.bashrc
  fi
}

ensure_workspace_perms() {
  if [[ -d "${WORKSPACE}" ]] && id -u "${RUN_USER}" >/dev/null 2>&1; then
    chown -R "${RUN_USER}:${RUN_USER}" "${WORKSPACE}" 2>/dev/null || true
  fi
}

# --- boot ---
# Order: prep → SSH/Jupyter → A1111 → wait upstream → nginx (avoid 502 on Connect)
/pre_start.sh || true
ensure_workspace_perms
setup_ssh
start_jupyter
start_webui
if [[ "${DISABLE_AUTOLAUNCH:-}" != "1" ]]; then
  wait_for_upstream 127.0.0.1 3000 "${UPSTREAM_WAIT_SECS:-600}"
fi
start_nginx
export_env_vars

echo "[start] Pod ready — Connect HTTP :3001 (WebUI), Jupyter :8888"
sleep infinity
