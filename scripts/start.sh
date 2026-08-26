#!/usr/bin/env bash
# RunPod-style entrypoint (mirrors runpod/containers + ashleykleynhans SD templates):
#   nginx :3001 → WebUI :3000 | Jupyter :8888 | SSH | sleep infinity
set -euo pipefail

export WEBUI_ROOT="${WEBUI_ROOT:-/stable-diffusion-webui}"
export WORKSPACE="${WORKSPACE:-/workspace}"
export TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD="${TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD:-1}"
export STABLE_DIFFUSION_REPO="${STABLE_DIFFUSION_REPO:-https://github.com/w-e-w/stablediffusion.git}"
export INSIGHTFACE_HOME="${INSIGHTFACE_HOME:-/root/.insightface}"

start_nginx() {
  echo "[start] Starting nginx (3001 → 3000)..."
  # Prefer service; fall back to nginx binary if needed
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
  # Avoid duplicate keys on restart
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
  # Match RunPod Connect: always expose Jupyter on 8888 unless disabled
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
    # Open like many RunPod SD templates (proxy is already auth-gated by RunPod login)
    token_args=(--IdentityProvider.token='' --ServerApp.password='')
    echo "[start] Starting Jupyter Lab on :8888 (no token)..."
  fi

  # Prefer system python for jupyter if present; else venv
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
  echo "[start] Jupyter Lab launched (log: /jupyter.log)"
}

start_webui() {
  if [[ "${DISABLE_AUTOLAUNCH:-}" == "1" ]]; then
    echo "[start] WebUI autolaunch disabled (DISABLE_AUTOLAUNCH=1)"
    return 0
  fi

  echo "[start] Launching A1111 WebUI on :3000..."
  cd "${WEBUI_ROOT}"
  chmod +x webui.sh || true
  # shellcheck disable=SC2086
  nohup bash webui.sh \
    --listen \
    --port 3000 \
    --enable-insecure-extension-access \
    --api \
    --xformers \
    ${CLI_ARGS:-} \
    &>/var/log/a1111.log &
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

# --- boot ---
/pre_start.sh || true
start_nginx
setup_ssh
start_jupyter
start_webui
export_env_vars

echo "[start] Pod ready — Connect HTTP :3001 (WebUI), Jupyter :8888"
# Keep container alive for SSH / Jupyter / long-running WebUI (RunPod pattern)
sleep infinity
