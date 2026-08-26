# RunPod A1111 + ReActor + ADetailer

Docker template for [RunPod](https://www.runpod.io/) with **AUTOMATIC1111 WebUI**, **ReActor** (InsightFace), and **ADetailer** (ultralytics) preinstalled so the usual dependency failures are fixed at build time.

## What this fixes

| Problem | Fix in this image |
| --- | --- |
| Missing `inswapper_128.onnx` | Baked into `models/insightface/` |
| Missing `buffalo_l` | Baked into `/root/.insightface/models/buffalo_l/` |
| CPU `onnxruntime` shadows GPU | Only `onnxruntime-gpu==1.17.1` (CUDA 12 index); re-pinned **after** ultralytics |
| ReActor stuck on CPU | `last_device.txt` → `CUDA`; checked every boot |
| ADetailer / `ultralytics` missing or wrong | Pin `ultralytics==8.3.75` (+ mediapipe, rich) |
| Missing YOLO detectors | Bake `face/hand/person` `.pt` from `Bingsu/adetailer` |
| Torch `weights_only` YOLO load issues | `TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD=1` |
| CLIP install fails (`pkg_resources`) | Pin `setuptools==69.5.1` (A1111’s version) + pre-install CLIP with `--no-build-isolation` |
| `Couldn't clone Stable Diffusion` (Stability-AI private) | `STABLE_DIFFUSION_REPO=https://github.com/w-e-w/stablediffusion.git` |
| ORT `_ARRAY_API not found` | Pin `numpy==1.26.4` (ultralytics often pulls numpy 2.x) |
| `ResolutionImpossible` numpy 1.26.2 vs constraint 1.26.4 | Rewrite A1111 `requirements_versions.txt` pin to `1.26.4` before `pip install` |

## Stack

- **WebUI:** [AUTOMATIC1111/stable-diffusion-webui](https://github.com/AUTOMATIC1111/stable-diffusion-webui) `v1.10.1`
- Base: `runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04`
- [Gourieff/sd-webui-reactor](https://codeberg.org/Gourieff/sd-webui-reactor)
- [Bing-su/adetailer](https://github.com/Bing-su/adetailer)
- SD code mirror: [w-e-w/stablediffusion](https://github.com/w-e-w/stablediffusion) (via `STABLE_DIFFUSION_REPO`; upstream Stability-AI repo is unavailable)
- `insightface==0.7.3`, `onnxruntime-gpu==1.17.1`, `ultralytics==8.3.75`

> InsightFace models are for **non-commercial research** unless you have a separate license.

## Build

RunPod requires a **`linux/amd64`** image. Building on Apple Silicon without `--platform` pushes **arm64 only**, and template create fails with:

> has no linux/amd64 manifest

```bash
# Recommended (build + push amd64 in one step)
./scripts/build-and-push.sh
# or:
IMAGE=abaddonmybeauty/a1111-reactor:latest ./scripts/build-and-push.sh
```

Equivalent manual command:

```bash
docker buildx build \
  --platform linux/amd64 \
  -t abaddonmybeauty/a1111-reactor:latest \
  --push \
  .
```

Verify the registry has amd64:

```bash
docker buildx imagetools inspect abaddonmybeauty/a1111-reactor:latest
```

You should see `Platform: linux/amd64`. Then create the RunPod template again.

Build is heavy (torch + WebUI + InsightFace ~800MB + YOLO; cross-building amd64 on Mac is slower).

## RunPod template (Connect / internet access)

Match the official `runpod/stable-diffusion` Connect UX:

| Connect label | Container port | What it is |
| --- | --- | --- |
| **HTTP Service** | **3001** | nginx → A1111 WebUI (`:3000`) |
| **Jupyter Lab** | **8888** | Jupyter Lab |
| SSH | **22** | OpenSSH (when `PUBLIC_KEY` is set by RunPod) |

### Template fields

| Field | Value |
| --- | --- |
| Container image | `yourdockerhub/a1111-reactor:latest` |
| Container disk | ≥ 30 GB (40+ recommended) |
| Volume | optional Network Volume → `/workspace` |
| Expose HTTP ports | `3001`, `8888` |
| Expose TCP | `22` (optional; RunPod often maps this for SSH) |
| Docker command | leave default (`/start.sh`) |

After deploy, open **Connect** → click **HTTP Service** (3001) for WebUI, or **Jupyter Lab** (8888).

### Env vars

| Variable | Purpose |
| --- | --- |
| `CLI_ARGS` | Extra WebUI flags, e.g. `--medvram` |
| `WORKSPACE` | Persist root (default `/workspace`) |
| `JUPYTER_PASSWORD` | Optional Jupyter token (empty = no token, RunPod-proxy style) |
| `DISABLE_JUPYTER` | Set `1` to skip Jupyter |
| `DISABLE_AUTOLAUNCH` | Set `1` to skip auto-starting WebUI |
| `PUBLIC_KEY` | Injected by RunPod for SSH |

### Local test (similar port map)

```bash
docker run --gpus all -p 3000:3001 -p 8888:8888 -p 22:22 \
  -v "$(pwd)/workspace:/workspace" \
  yourdockerhub/a1111-reactor:latest
```

Then open `http://localhost:3000` (maps to container nginx `:3001`).

## Verify on a pod

```bash
source /stable-diffusion-webui/venv/bin/activate
python - <<'PY'
import insightface, onnxruntime as ort
from ultralytics import YOLO
print("insightface", insightface.__version__)
print("providers", ort.get_available_providers())
print("ultralytics OK", YOLO)
assert "CUDAExecutionProvider" in ort.get_available_providers()
PY

ls -lh /stable-diffusion-webui/models/insightface/inswapper_128.onnx
ls /stable-diffusion-webui/models/adetailer/
cat /stable-diffusion-webui/extensions/sd-webui-reactor/last_device.txt
```

## Layout

```
Dockerfile
nginx/nginx.conf            # :3001 → WebUI :3000
a1111/webui-user.sh
scripts/
  download_insightface_models.sh
  download_adetailer_models.sh
  verify_insightface.py
  verify_adetailer.py
  pre_start.sh              # volume links + ultralytics/ORT repair
  start.sh                  # nginx + jupyter + webui + sleep infinity
```

## Notes

- **Install order matters:** ultralytics can pull CPU `onnxruntime`; the image always reinstalls `onnxruntime-gpu` last, and `pre_start.sh` repairs it again on boot.
- Do not manually `pip install onnxruntime` (CPU). Prefer leaving version pins alone.
- With a Network Volume, `models/insightface` and `models/adetailer` are seeded then symlinked under `/workspace`.
