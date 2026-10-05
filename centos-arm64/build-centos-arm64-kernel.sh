#!/usr/bin/env bash
# Full, one-shot native aarch64 CentOS Stream 10 kernel build (Image +
# vmlinux + all modules) from the real centos-stream-10/src tree, using the
# already-committed-to-the-working-tree redhat/configs/kernel-6.12.0-aarch64.config
# as the base .config -- the exact config a real CentOS Stream 10 aarch64
# kernel RPM ships, which already has CONFIG_CRASH_DM_CRYPT=y out of the box.
#
# Companion to qemu/centos-x86/build-centos-x86-kernel.sh (same role, cross-
# compiled there because the host is arm64; here the host *is* the target
# arch, so this builds natively, same toolchain image as the existing
# qemu/centos-arm64/build-kernel.sh incremental script).
#
#   ./qemu/centos-arm64/build-centos-arm64-kernel.sh
#   JOBS=6 ./qemu/centos-arm64/build-centos-arm64-kernel.sh
#   MODULES=0 ./qemu/centos-arm64/build-centos-arm64-kernel.sh   # Image only, skip modules
#
# Why this exists alongside build-kernel.sh instead of replacing it:
# build-kernel.sh is explicitly "incremental only" (kernel/README.md: "the
# first build is manual", following README steps 4-6) and that original
# first build forced CONFIG_DEBUG_INFO_NONE to fit Docker Desktop's then
#8 GB default memory, and never copied vmlinux out at all -- so there is no
# debuginfo-carrying vmlinux anywhere for crash(8) to use. This script is
# that "manual first build" turned into a script, like
# build-centos-x86-kernel.sh is for x86 -- except it LEAVES DEBUG_INFO ON
# (the stock aarch64 config's own default: CONFIG_DEBUG_INFO=y,
# CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT=y) instead of forcing it off,
# because crash(8) needs that DWARF info to resolve symbols/structs against
# the vmcore the LUKS kdump test produces. It uses a brand-new Docker volume
# (centos-kernel-arm64-build, not the old centos-kernel-build) so this
# debug-info build's objects never mix with the old non-debug incremental
# build's objects.
#
# Why KEXEC_SIG and BTF are force-disabled even though the stock config has
# them on: CONFIG_KEXEC_SIG (already =y in the stock aarch64 config, see
# redhat/configs: enable KEXEC_SIG for aarch64 RHEL) would require a trusted
# signing chain this throwaway QEMU test does not have -- QEMU's direct
# -kernel boot has no UEFI Secure Boot/lockdown anyway, so disabling it only
# removes a check that could never pass here. CONFIG_DEBUG_INFO_BTF/_MODULES
# needs pahole built for the exact kernel version and adds build risk for no
# benefit -- crash(8) reads DWARF (CONFIG_DEBUG_INFO=y, left on), not BTF --
# exactly the same reasoning build-centos-x86-kernel.sh uses.
#
# Unlike x86, ARM64_PTR_AUTH/ARM64_BTI (the nearest arm64 analogues of x86's
# IBT/CET) are left alone: x86 had a real cross-toolchain/objtool mismatch
# forcing IBT off, but this is a *native* build with the distro's own gcc
# (the same centos-kernel-builder:el10 image used for the original,
# proven-working arm64 Image build), so there is no equivalent toolchain
# mismatch to work around.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/centos-stream-10/src"
OUT="$ROOT/build-out/centos-arm64"
IMAGE_NAME="${IMAGE_NAME:-centos-kernel-builder:el10}"
VOLUME="${VOLUME:-centos-kernel-arm64-build}"
JOBS="${JOBS:-8}"
CPUS="${CPUS:-8}"
MEMORY="${MEMORY:-7g}"
MODULES="${MODULES:-1}"
BASE_CONFIG="${BASE_CONFIG:-redhat/configs/kernel-6.12.0-aarch64.config}"

if [[ ! -f "$SRC/Makefile" ]]; then
  echo "CentOS Stream source missing at $SRC" >&2
  echo "Attach centos-kernel.sparseimage (see kernel/README.md step 1)." >&2
  exit 1
fi
if [[ ! -f "$SRC/$BASE_CONFIG" ]]; then
  echo "Base config missing: $SRC/$BASE_CONFIG" >&2
  echo "Regenerate with: docker run --rm --platform linux/arm64 -v \"$SRC\":/src -w /src $IMAGE_NAME bash -lc 'make dist-configs-arch'" >&2
  exit 1
fi

TARGETS="Image"
if [[ "$MODULES" == "1" ]]; then
  TARGETS="Image modules"
fi

if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  echo "Docker image $IMAGE_NAME is missing. Build it with kernel/README.md step 3." >&2
  exit 1
fi
docker volume inspect "$VOLUME" >/dev/null 2>&1 || docker volume create "$VOLUME"
mkdir -p "$OUT"

docker rm -f centos-kernel-arm64-compile >/dev/null 2>&1 || true
echo "make O=/build (native arm64, base: $BASE_CONFIG), then $TARGETS"
docker run --name centos-kernel-arm64-compile --platform linux/arm64 \
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
  cp '$BASE_CONFIG' /build/.config
fi
# Applied on every build (not just the first), same reasoning as
# build-centos-x86-kernel.sh's 'applied on every build' block -- a stale
# /build/.config from an earlier, differently-configured attempt always
# picks up the current override set.
./scripts/config --file /build/.config \
  --disable KEXEC_SIG \
  --disable DEBUG_INFO_BTF \
  --disable DEBUG_INFO_BTF_MODULES \
  --set-str LOCALVERSION '-centos10-arm64-local'
make O=/build olddefconfig

echo '--- key options after olddefconfig ---'
grep -E '^(CONFIG_CRASH_DM_CRYPT|CONFIG_DM_CRYPT|CONFIG_CONFIGFS_FS|CONFIG_CRYPTO_XTS|CONFIG_KEXEC_FILE|CONFIG_DEBUG_INFO|CONFIG_XFS_FS|CONFIG_VIRTIO_BLK|CONFIG_OF\$)=' /build/.config
grep -q '^CONFIG_CRASH_DM_CRYPT=y' /build/.config || { echo 'CONFIG_CRASH_DM_CRYPT missing'; exit 1; }
grep -q '^CONFIG_KEXEC_FILE=y' /build/.config  || { echo 'CONFIG_KEXEC_FILE missing'; exit 1; }
grep -q '^CONFIG_CONFIGFS_FS=y' /build/.config || { echo 'CONFIG_CONFIGFS_FS missing'; exit 1; }
grep -q '^CONFIG_DEBUG_INFO=y' /build/.config  || { echo 'CONFIG_DEBUG_INFO missing -- vmlinux will have no debug symbols for crash(8)'; exit 1; }

make O=/build -j${JOBS} $TARGETS

cp -v /build/arch/arm64/boot/Image /out/Image
cp -v /build/vmlinux /out/vmlinux
cp -v /build/.config /out/kernel.config
cp -v /build/include/config/kernel.release /out/kernel.release
ls -lh /out/Image /out/vmlinux
echo CENTOS_ARM64_BUILD_OK
"

echo "Updated $OUT/Image + $OUT/vmlinux ($(tr -d '\n' < "$OUT/kernel.release" 2>/dev/null || echo unknown))"
