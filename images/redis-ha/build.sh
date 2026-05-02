#!/bin/bash
# build.sh — build the redis-ha image. Tag scheme:
#   redis-ha:7-v<VERSION>
#   redis-ha:7-latest
# The semver bumps when the entrypoint script or HA config fragment
# change. The pinned 7 is the upstream redis major.

set -euo pipefail

VERSION="${VERSION:-0.1.0}"
TAG_BASE="redis-ha:7"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

cd "$SCRIPT_DIR"

echo "[build] tagging redis-ha:7-v${VERSION} (and :7-latest)"
docker build \
    --tag "${TAG_BASE}-v${VERSION}" \
    --tag "${TAG_BASE}-latest" \
    .

echo "[build] done."
docker images "${TAG_BASE}-*" --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}'
