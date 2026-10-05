#!/usr/bin/env bash
# Build a minimal aarch64 Image from torvalds/linux (O= docker volume).
#
#   ./qemu/vanilla-arm64/build-vanilla-kernel.sh
#   JOBS=8 ./qemu/vanilla-arm64/build-vanilla-kernel.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/centos-stream-10/linux"
OUT="$ROOT/build-out/vanilla-arm64"
IMAGE_NAME="${IMAGE_NAME:-centos-kernel-builder:el10}"
VOLUME="${VOLUME:-linux-vanilla-build}"
JOBS="${JOBS:-4}"
CPUS="${CPUS:-6}"
MEMORY="${MEMORY:-6.5g}"

if [[ ! -f "$SRC/Makefile" ]]; then
  echo "Vanilla tree missing at $SRC" >&2
  echo "Clone torvalds/linux onto the case-sensitive volume first." >&2
  exit 1
fi
if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  echo "Docker image $IMAGE_NAME is missing." >&2
  exit 1
fi
docker volume inspect "$VOLUME" >/dev/null 2>&1 || docker volume create "$VOLUME"
mkdir -p "$OUT"

docker rm -f linux-vanilla-compile >/dev/null 2>&1 || true
echo "make O=/build ARCH=arm64 defconfig + kexec_file, then Image"
docker run --name linux-vanilla-compile --platform linux/arm64 \
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
  make O=/build ARCH=arm64 defconfig
  ./scripts/config --file /build/.config \
    --enable KEXEC \
    --enable KEXEC_FILE \
    --disable KEXEC_SIG \
    --disable KEXEC_IMAGE_VERIFY_SIG \
    --disable RANDOMIZE_BASE \
    --enable VIRTIO \
    --enable VIRTIO_PCI \
    --enable VIRTIO_BLK \
    --enable VIRTIO_MMIO \
    --enable BLK_DEV \
    --enable EXT4_FS \
    --enable SERIAL_AMBA_PL011 \
    --enable SERIAL_AMBA_PL011_CONSOLE \
    --enable DEVTMPFS \
    --enable DEVTMPFS_MOUNT \
    --enable TMPFS \
    --enable PROC_FS \
    --enable SYSFS \
    --enable BINFMT_ELF \
    --disable DEBUG_INFO \
    --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
    --disable DEBUG_INFO_DWARF4 \
    --disable DEBUG_INFO_DWARF5 \
    --disable DEBUG_INFO_BTF \
    --disable DEBUG_INFO_BTF_MODULES
  make O=/build ARCH=arm64 olddefconfig
fi
make O=/build ARCH=arm64 -j${JOBS} Image
cp -v /build/arch/arm64/boot/Image /out/Image
cp -v /build/.config /out/kernel.config
cut -d= -f2 /build/include/config/kernel.release > /out/kernel.release || \
  make O=/build ARCH=arm64 -s kernelrelease > /out/kernel.release
ls -lh /out/Image
echo VANILLA_BUILD_OK
"

echo "Updated $OUT/Image ($(tr -d '\n' < "$OUT/kernel.release"))"
