#!/usr/bin/env bash
# Cross-build an x86_64 CentOS Stream 10 kernel (bzImage + vmlinux + all
# modules) from the official centos-stream-10/src tree, using the
# upstream-committed redhat/configs/kernel-6.12.0-x86_64.config as the base
# .config -- the same config a real CentOS Stream 10 x86_64 install ships,
# which already has CONFIG_CRASH_DM_CRYPT=y out of the box.
#
# Companion scripts, named so x86 is never confused with arm64:
#   qemu/centos-arm64/build-kernel.sh        <- native arm64 build (this host's arch)
#   qemu/centos-x86/build-centos-x86-kernel.sh <- this file, cross-compiled x86_64
#
# Unlike centos-arm64 (which builds *on* its own target arch, so dist-configs
# can run live), this cross-compiles x86_64 from an arm64 host using Ubuntu +
# a gcc-x86-64-linux-gnu cross toolchain -- the same proven approach as
# qemu/vanilla-x86/build-vanilla-x86-kernel.sh, just pointed at the real
# centos-stream-10/src tree and its already-committed x86_64 defconfig
# instead of a hand-built vanilla config.
#
#   ./qemu/centos-x86/build-centos-x86-kernel.sh
#   JOBS=8 ./qemu/centos-x86/build-centos-x86-kernel.sh
#   MODULES=0 ./qemu/centos-x86/build-centos-x86-kernel.sh   # bzImage only, skip modules (fast)
#
# Why BTF, KEXEC_SIG, and IBT/CET are forced off even though the stock
# config has them on: CONFIG_DEBUG_INFO_BTF needs pahole built for the exact
# kernel version (CONFIG_PAHOLE_VERSION=131) and adds cross-build risk for no
# benefit here -- crash(8) reads DWARF (CONFIG_DEBUG_INFO=y, left on), not
# BTF. CONFIG_KEXEC_SIG would require a trusted signing chain this throwaway
# test build does not have; QEMU's direct -kernel boot has no UEFI Secure
# Boot/lockdown anyway, so turning it off here only removes a check that
# could never pass in this environment, not a check that was actually
# protecting anything. CONFIG_X86_KERNEL_IBT (+ CONFIG_OBJTOOL_WERROR, which
# turns any objtool complaint into a hard build failure) hit a real
# cross-toolchain mismatch: objtool flagged the Xen PVH entry stub
# (pvh_start_xen) as "relocation to !ENDBR" -- a known class of IBT
# validation edge case in assembly entry points, triggered here by this
# Ubuntu 24.04 container's gcc/binutils not being the exact toolchain RHEL
# built this config's objtool expectations against. IBT/CET is pure
# hardware-level control-flow hardening, orthogonal to CONFIG_CRASH_DM_CRYPT;
# disabling it removes the mismatch instead of papering over it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/centos-stream-10/src"
OUT="$ROOT/build-out/centos-x86"
IMAGE_NAME="${IMAGE_NAME:-ubuntu:24.04}"
VOLUME="${VOLUME:-centos-kernel-x86-build}"
JOBS="${JOBS:-8}"
CPUS="${CPUS:-8}"
MEMORY="${MEMORY:-7g}"
MODULES="${MODULES:-1}"
BASE_CONFIG="${BASE_CONFIG:-redhat/configs/kernel-6.12.0-x86_64.config}"

if [[ ! -f "$SRC/Makefile" ]]; then
  echo "CentOS Stream source missing at $SRC" >&2
  echo "Attach centos-kernel.sparseimage (see README.md step 1)." >&2
  exit 1
fi
if [[ ! -f "$SRC/$BASE_CONFIG" ]]; then
  echo "Base config missing: $SRC/$BASE_CONFIG" >&2
  echo "This should already be committed in the centos-stream-10 checkout." >&2
  exit 1
fi

TARGETS="bzImage"
if [[ "$MODULES" == "1" ]]; then
  TARGETS="bzImage modules"
fi

docker volume inspect "$VOLUME" >/dev/null 2>&1 || docker volume create "$VOLUME"
mkdir -p "$OUT"

docker rm -f centos-kernel-x86-compile >/dev/null 2>&1 || true
echo "make O=/build ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- (base: $BASE_CONFIG), then $TARGETS"
docker run --name centos-kernel-x86-compile --platform linux/arm64 \
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
  libssl-dev libelf-dev openssl cpio kmod rsync xz-utils
git config --global --add safe.directory /src

if [[ ! -f /build/.config ]]; then
  cp '$BASE_CONFIG' /build/.config
fi
# Applied on every build (not just the first) so a stale /build/.config
# left over from an earlier, differently-configured attempt always picks
# up the current override set -- same reasoning as
# qemu/vanilla-x86/build-vanilla-x86-kernel.sh's 'applied on every build'
# CRASH_DM_CRYPT block.
./scripts/config --file /build/.config \
  --disable KEXEC_SIG \
  --disable KEXEC_BZIMAGE_VERIFY_SIG \
  --disable DEBUG_INFO_BTF \
  --disable DEBUG_INFO_BTF_MODULES \
  --disable X86_KERNEL_IBT \
  --disable X86_CET \
  --disable OBJTOOL_WERROR \
  --set-str LOCALVERSION '-centos10-x86-local'
make O=/build ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- olddefconfig

echo '--- key options after olddefconfig ---'
grep -E '^(CONFIG_CRASH_DM_CRYPT|CONFIG_DM_CRYPT|CONFIG_CONFIGFS_FS|CONFIG_CRYPTO_XTS|CONFIG_KEXEC_FILE|CONFIG_DEBUG_INFO|CONFIG_XFS_FS|CONFIG_VIRTIO_BLK)=' /build/.config
grep -q '^CONFIG_CRASH_DM_CRYPT=y' /build/.config || { echo 'CONFIG_CRASH_DM_CRYPT missing'; exit 1; }
grep -q '^CONFIG_KEXEC_FILE=y' /build/.config  || { echo 'CONFIG_KEXEC_FILE missing'; exit 1; }
grep -q '^CONFIG_CONFIGFS_FS=y' /build/.config || { echo 'CONFIG_CONFIGFS_FS missing'; exit 1; }

make O=/build ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- -j${JOBS} $TARGETS

cp -v /build/arch/x86/boot/bzImage /out/bzImage
cp -v /build/vmlinux /out/vmlinux
cp -v /build/.config /out/kernel.config
make O=/build ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- -s kernelrelease > /out/kernel.release
ls -lh /out/bzImage /out/vmlinux
echo CENTOS_X86_BUILD_OK
"

echo "Updated $OUT/bzImage ($(tr -d '\n' < "$OUT/kernel.release" 2>/dev/null || echo unknown))"
