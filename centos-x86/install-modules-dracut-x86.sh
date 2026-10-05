#!/usr/bin/env bash
# Install the built x86_64 kernel modules into the CentOS rootfs and
# generate a dracut initrd. Companion to
# qemu/centos-arm64/install-modules-dracut.sh.
#
# Why this is TWO docker stages, unlike the arm64 original (one stage):
# arm64's version builds *and* installs modules on the same arch as the
# host, so everything -- compiling, stripping, signing, and the final
# chroot depmod/dracut run -- happens natively in one container. This is a
# *cross* build: the kernel/modules were compiled x86_64-on-arm64 (fast,
# native toolchain). But "chroot /mnt/root dracut" and "chroot /mnt/root
# depmod" must actually *execute* real x86_64 ELF binaries living inside
# that rootfs -- that needs amd64 emulation, which is slower. So:
#   [1/2] modules_install (native arm64 host, cross-strip/sign, fast)
#   [2/2] copy into rootfs + depmod + dracut (amd64-emulated chroot, slower)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/centos-stream-10/src"
OUT="$ROOT/build-out/centos-x86"
DISK="${DISK:-$OUT/centos-rootfs-x86.raw}"
KVER="${KVER:-$(cat "$OUT/kernel.release" 2>/dev/null || true)}"
VOLUME="${VOLUME:-centos-kernel-x86-build}"
IMAGE_NAME="${IMAGE_NAME:-ubuntu:24.04}"

if [[ ! -f "$DISK" ]]; then
  echo "Rootfs disk not found: $DISK" >&2
  echo "Create it first: $ROOT/qemu/centos-x86/make-centos-x86-rootfs.sh" >&2
  exit 1
fi
if [[ ! -d "$SRC" ]]; then
  echo "Kernel source not found: $SRC" >&2
  exit 1
fi
if [[ -z "$KVER" ]]; then
  echo "Could not determine KVER (no $OUT/kernel.release) — build the kernel first:" >&2
  echo "  $ROOT/qemu/centos-x86/build-centos-x86-kernel.sh" >&2
  exit 1
fi

STAGE="$OUT/modules-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"

echo "[1/2] modules_install for $KVER (native arm64, cross-strip/sign) -> $STAGE"
docker run --rm --platform linux/arm64 \
  --cpus=6 --memory=6g \
  -v "$SRC":/src \
  -v "$VOLUME":/build \
  -v "$STAGE":/stage \
  -w /src \
  "$IMAGE_NAME" \
  bash -lc "
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  git make bc gcc-x86-64-linux-gnu binutils-x86-64-linux-gnu >/dev/null
git config --global --add safe.directory /src
make O=/build ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- \
  INSTALL_MOD_PATH=/stage INSTALL_MOD_STRIP=1 modules_install
test -d /stage/lib/modules/$KVER || { echo 'modules_install produced no /stage/lib/modules/$KVER'; exit 1; }
du -sh /stage/lib/modules/$KVER
echo MODULES_INSTALL_X86_OK
"

echo "[2/2] copy into rootfs + depmod + dracut for $KVER (amd64-emulated chroot) -> $DISK"
docker run --rm --platform linux/amd64 --privileged \
  --cpus=6 --memory=6g \
  -v "$STAGE":/stage:ro \
  -v "$OUT":/out \
  quay.io/centos/centos:stream10 \
  bash -lc "
set -euo pipefail
dnf -y install e2fsprogs >/dev/null

KVER='$KVER'
echo \"Installing modules for \$KVER\"

mkdir -p /mnt/root
mount -o loop /out/centos-rootfs-x86.raw /mnt/root

mkdir -p /mnt/root/lib/modules
rm -rf \"/mnt/root/lib/modules/\$KVER\"
cp -a \"/stage/lib/modules/\$KVER\" /mnt/root/lib/modules/

cp -v /out/bzImage \"/mnt/root/boot/vmlinuz-\$KVER\"
cp -v /out/kernel.config \"/mnt/root/boot/config-\$KVER\"

mount -t proc proc /mnt/root/proc
mount -t sysfs sysfs /mnt/root/sys
mount --bind /dev /mnt/root/dev

chroot /mnt/root depmod -a \"\$KVER\"

chroot /mnt/root dracut --force --no-hostonly --nomdadmconf --nolvmconf \
  --no-early-microcode \
  --add-drivers 'virtio_blk virtio_pci virtio_scsi virtio_net ext4 xfs crc32c jbd2 mbcache' \
  --add 'crypt dm' \
  --kver \"\$KVER\" \
  \"/boot/initramfs-\${KVER}.img\"

cp -v \"/mnt/root/boot/initramfs-\${KVER}.img\" /out/initramfs-x86.img
ls -lh \"/mnt/root/lib/modules/\$KVER\" | head
du -sh \"/mnt/root/lib/modules/\$KVER\"
ls -lh /out/initramfs-x86.img

umount /mnt/root/dev /mnt/root/sys /mnt/root/proc
umount /mnt/root
echo DRACUT_X86_SUCCESS
"

ls -lh "$OUT/initramfs-x86.img"
echo "Wrote $OUT/initramfs-x86.img for $KVER"
