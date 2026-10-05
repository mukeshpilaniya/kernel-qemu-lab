#!/usr/bin/env bash
# Cross-build an x86_64 bzImage from the same torvalds/linux tree as ARM64 vanilla.
#
#   ./qemu/vanilla-x86/build-vanilla-x86-kernel.sh
#   JOBS=8 ./qemu/vanilla-x86/build-vanilla-x86-kernel.sh
#   DEBUG_INFO=1 ./qemu/vanilla-x86/build-vanilla-x86-kernel.sh   # opt-in: crash(8)-readable vmlinux
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/centos-stream-10/linux"
OUT="$ROOT/build-out/vanilla-x86"
IMAGE_NAME="${IMAGE_NAME:-ubuntu:24.04}"
VOLUME="${VOLUME:-linux-vanilla-x86-build}"
JOBS="${JOBS:-4}"
CPUS="${CPUS:-6}"
MEMORY="${MEMORY:-6.5g}"
# DEBUG_INFO=1 trades a bigger, slower build for a vmlinux that crash(8) can
# read. Default is 0: fast build, no DWARF, vmlinux is still copied out but
# is not useful for crash(8). See qemu-x86.md Section 12.
DEBUG_INFO="${DEBUG_INFO:-0}"

if [[ ! -f "$SRC/Makefile" ]]; then
  echo "Vanilla tree missing at $SRC" >&2
  echo "Attach centos-kernel.sparseimage (see README.md step 1)." >&2
  exit 1
fi

docker volume inspect "$VOLUME" >/dev/null 2>&1 || docker volume create "$VOLUME"
mkdir -p "$OUT"

docker rm -f linux-vanilla-x86-compile >/dev/null 2>&1 || true
echo "make O=/build ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- defconfig + kexec_file + CRASH_DM_CRYPT, then bzImage"
docker run --name linux-vanilla-x86-compile --platform linux/arm64 \
  --cpus="$CPUS" --memory="$MEMORY" \
  -v "$SRC":/src \
  -v "$VOLUME":/build \
  -v "$OUT":/out \
  -w /src \
  "$IMAGE_NAME" \
  bash -lc "
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  ca-certificates git make bc bison flex python3 gcc \
  gcc-x86-64-linux-gnu binutils-x86-64-linux-gnu \
  libssl-dev libelf-dev cpio kmod rsync
git config --global --add safe.directory /src
if [[ ! -f /build/.config ]]; then
  make O=/build ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- defconfig
  ./scripts/config --file /build/.config \
    --enable KEXEC \
    --enable KEXEC_FILE \
    --disable KEXEC_SIG \
    --disable RANDOMIZE_BASE \
    --enable VIRTIO \
    --enable VIRTIO_PCI \
    --enable VIRTIO_BLK \
    --enable BLK_DEV \
    --enable EXT4_FS \
    --enable SERIAL_8250 \
    --enable SERIAL_8250_CONSOLE \
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
  make O=/build ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- olddefconfig
fi
# Applied on every build so an existing /build/.config picks up LUKS kdump.
./scripts/config --file /build/.config \
  --enable DM_CRYPT \
  --enable CRYPTO_XTS \
  --enable CONFIGFS_FS \
  --enable CRASH_DM_CRYPT
if [[ $DEBUG_INFO == 1 ]]; then
  echo 'DEBUG_INFO=1: enabling CONFIG_DEBUG_INFO for a crash(8)-readable vmlinux'
  ./scripts/config --file /build/.config \
    --enable DEBUG_INFO \
    --enable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
    --disable DEBUG_INFO_BTF \
    --disable DEBUG_INFO_BTF_MODULES
else
  ./scripts/config --file /build/.config \
    --disable DEBUG_INFO \
    --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
    --disable DEBUG_INFO_DWARF4 \
    --disable DEBUG_INFO_DWARF5 \
    --disable DEBUG_INFO_BTF \
    --disable DEBUG_INFO_BTF_MODULES
fi
make O=/build ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- olddefconfig
grep -E '^(CONFIG_CRASH_DM_CRYPT|CONFIG_DM_CRYPT|CONFIG_CONFIGFS_FS|CONFIG_CRYPTO_XTS|CONFIG_DEBUG_INFO)=' /build/.config
grep -q '^CONFIG_CRASH_DM_CRYPT=y' /build/.config || { echo 'CONFIG_CRASH_DM_CRYPT missing'; exit 1; }
grep -q '^CONFIG_DM_CRYPT=y' /build/.config || { echo 'CONFIG_DM_CRYPT missing'; exit 1; }
grep -q '^CONFIG_CONFIGFS_FS=y' /build/.config || { echo 'CONFIG_CONFIGFS_FS missing'; exit 1; }
grep -q '^CONFIG_CRYPTO_XTS=y' /build/.config || { echo 'CONFIG_CRYPTO_XTS missing'; exit 1; }
if [[ $DEBUG_INFO == 1 ]]; then
  grep -q '^CONFIG_DEBUG_INFO=y' /build/.config || { echo 'CONFIG_DEBUG_INFO missing'; exit 1; }
fi
make O=/build ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- -j${JOBS} bzImage
cp -v /build/arch/x86/boot/bzImage /out/bzImage
cp -v /build/vmlinux /out/vmlinux
cp -v /build/.config /out/kernel.config
make O=/build ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- -s kernelrelease > /out/kernel.release
ls -lh /out/bzImage /out/vmlinux
echo VANILLA_X86_BUILD_OK
"

echo "Updated $OUT/bzImage ($(tr -d '\n' < "$OUT/kernel.release"))"
