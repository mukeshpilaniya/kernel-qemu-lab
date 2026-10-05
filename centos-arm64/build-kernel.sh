#!/usr/bin/env bash
# Incremental kernel rebuild (keeps the existing Docker O=/build objects).
#
# Usage:
#   ./qemu/centos-arm64/build-kernel.sh                 # Image only
#   ./qemu/centos-arm64/build-kernel.sh --modules       # Image + modules
#   ./qemu/centos-arm64/build-kernel.sh --modules --install
#       # also install .ko into the CentOS rootfs and regenerate dracut
#   ./qemu/centos-arm64/build-kernel.sh --clean         # wipe objects (keeps .config), then Image
#
# Environment:
#   JOBS=4  CPUS=6  MEMORY=6.5g
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/centos-stream-10/src"
OUT="$ROOT/build-out/centos-arm64"
IMAGE_NAME="${IMAGE_NAME:-centos-kernel-builder:el10}"
VOLUME="${VOLUME:-centos-kernel-build}"
JOBS="${JOBS:-4}"
CPUS="${CPUS:-6}"
MEMORY="${MEMORY:-6.5g}"

BUILD_MODULES=0
INSTALL_ROOTFS=0
CLEAN=0

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --modules) BUILD_MODULES=1 ;;
    --install) INSTALL_ROOTFS=1; BUILD_MODULES=1 ;;
    --clean) CLEAN=1 ;;
    -j|--jobs) JOBS="$2"; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done

if [[ ! -f "$SRC/Makefile" ]]; then
  echo "Kernel source not found at $SRC" >&2
  echo "Mount the case-sensitive volume first (see README.md step 1)." >&2
  exit 1
fi
if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  echo "Docker image $IMAGE_NAME is missing. Build it with README.md step 3." >&2
  exit 1
fi
if ! docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  echo "Docker volume $VOLUME is missing. Run the first full build (README.md steps 4–6)." >&2
  exit 1
fi
mkdir -p "$OUT"

TARGETS="Image"
if [[ "$BUILD_MODULES" -eq 1 ]]; then
  TARGETS="Image modules"
fi

CLEAN_CMD=""
if [[ "$CLEAN" -eq 1 ]]; then
  echo "Wiping object files in $VOLUME (keeping .config)"
  CLEAN_CMD='
    if [[ ! -f /build/.config ]]; then
      echo "No /build/.config; cannot --clean. Run the first full build." >&2
      exit 1
    fi
    cp /build/.config /tmp/.config.keep
    find /build -mindepth 1 -maxdepth 1 ! -name .config -exec rm -rf {} +
    cp /tmp/.config.keep /build/.config
  '
fi

echo "Incremental make O=/build -j${JOBS} ${TARGETS}"
docker rm -f centos-kernel-compile >/dev/null 2>&1 || true
docker run --name centos-kernel-compile --platform linux/arm64 \
  --cpus="$CPUS" --memory="$MEMORY" \
  -v "$SRC":/src \
  -v "$VOLUME":/build \
  -v "$OUT":/out \
  -w /src \
  "$IMAGE_NAME" \
  bash -lc "
set -euo pipefail
git config --global --add safe.directory /src
if [[ ! -f /build/.config ]]; then
  echo 'No /build/.config. Run the first full configure/build (README.md step 6).' >&2
  exit 1
fi
$CLEAN_CMD
make O=/build -j${JOBS} ${TARGETS}
cp -v /build/arch/arm64/boot/Image /out/Image
cp -v /build/include/config/kernel.release /out/kernel.release
ls -lh /out/Image
echo BUILD_SUCCESS
"

echo "Updated $OUT/Image ($(cat "$OUT/kernel.release"))"

if [[ "$INSTALL_ROOTFS" -eq 1 ]]; then
  echo "Installing modules into rootfs and regenerating dracut..."
  "$ROOT/qemu/centos-arm64/install-modules-dracut.sh"
fi
