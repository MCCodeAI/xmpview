#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v swift >/dev/null; then
  exec ./scripts/check.sh
fi

# Official Swift image, pinned to the digest used for this environment's tests.
# Compiler caches live inside the disposable container; .build stays in checkout.
swift_image='swift:6.0.3-jammy@sha256:95f6ef898992dc840b35517e780f6f6db9661432775ab0b33cc0a531ea749bdb'
docker_local() {
  env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS \
    -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
    docker --host=unix:///var/run/docker.sock "$@"
}
docker_local info --format '{{.ServerVersion}}' >/dev/null
if ! docker_local image inspect "$swift_image" >/dev/null 2>&1; then
  docker_local pull "$swift_image"
fi
docker_local run --rm --network none --user "$(id -u):$(id -g)" \
  -e XDG_CACHE_HOME=/tmp/cache -e SWIFTPM_MODULECACHE_OVERRIDE=/tmp/swift-modules \
  --mount "type=bind,src=$PWD,dst=/workspace/xmpview" -w /workspace/xmpview \
  "$swift_image" swift test --jobs 4 --cache-path /tmp/swift-cache \
    --config-path /tmp/swift-config --security-path /tmp/swift-security
echo 'Portable core verified. Native ImageIO, SwiftUI and app packaging require macOS.'
