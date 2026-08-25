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

## Stack

- **WebUI:** [AUTOMATIC1111/stable-diffusion-webui](https://github.com/AUTOMATIC1111/stable-diffusion-webui) `v1.10.1`
- Base: `runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04`
- [Gourieff/sd-webui-reactor](https://codeberg.org/Gourieff/sd-webui-reactor)
- [Bing-su/adetailer](https://github.com/Bing-su/adetailer)
- SD code mirror: [w-e-w/stablediffusion](https://github.com/w-e-w/stablediffusion) (via `STABLE_DIFFUSION_REPO`; upstream Stability-AI repo is unavailable)
- `insightface==0.7.3`, `onnxruntime-gpu==1.17.1`, `ultralytics==8.3.75`

> InsightFace models are for **non-commercial research** unless you have a separate license.

## Build

```bash
docker build -t yourdockerhub/a1111-reactor:latest .
docker push yourdockerhub/a1111-reactor:latest
```

Build is heavy (torch + WebUI + InsightFace ~800MB + YOLO detectors).

## RunPod template

| Field | Value |
| --- | --- |
| Container image | `yourdockerhub/a1111-reactor:latest` |
| Container disk | ≥ 30 GB (40+ recommended) |
| Volume | optional → `/workspace` |
| Expose HTTP | **3000** |
| Command | `/start.sh` (default) |

Env: `CLI_ARGS` (extra WebUI flags), `WORKSPACE` (default `/workspace`).

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
a1111/webui-user.sh
scripts/
  download_insightface_models.sh
  download_adetailer_models.sh
  verify_insightface.py
  verify_adetailer.py
  pre_start.sh          # volume links + ultralytics/ORT repair
  start.sh
```

## Notes

- **Install order matters:** ultralytics can pull CPU `onnxruntime`; the image always reinstalls `onnxruntime-gpu` last, and `pre_start.sh` repairs it again on boot.
- Do not manually `pip install onnxruntime` (CPU). Prefer leaving version pins alone.
- With a Network Volume, `models/insightface` and `models/adetailer` are seeded then symlinked under `/workspace`.
