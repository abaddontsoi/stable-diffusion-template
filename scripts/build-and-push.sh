#!/usr/bin/env bash
# Build & push linux/amd64 image for RunPod (required; Mac arm64 alone will fail template create).
set -euo pipefail

IMAGE="${IMAGE:-abaddonmybeauty/a1111-reactor:latest}"
PLATFORM="${PLATFORM:-linux/amd64}"

echo "Building ${IMAGE} for ${PLATFORM}..."
docker buildx build \
  --platform "${PLATFORM}" \
  -t "${IMAGE}" \
  --push \
  .

echo "Done. Verify amd64 manifest:"
docker buildx imagetools inspect "${IMAGE}" | head -40
