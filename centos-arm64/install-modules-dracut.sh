#!/usr/bin/env bash
# Install the built kernel modules into the CentOS rootfs and generate a
# dracut initrd. The dracut invocation adds 'crypt dm' and the 'xfs'
# driver on top of the original generic set, so the resulting initramfs
# (used for the *first* kernel's boot, not the kdump-specific initramfs
# kdumpctl rebuild generates later on the guest) matches
# qemu/centos-x86/install-modules-dracut-x86.sh's equivalent additions --
# needed because the LUKS/CONFIG_CRASH_DM_CRYPT test in
# qemu/centos-arm64/luks/ exercises cryptsetup/dm-crypt and an xfs dump
# target from inside the first kernel's own boot environment too.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/centos-stream-10/src"
OUT="$ROOT/build-out/centos-arm64"
DISK="${DISK:-$OUT/centos-rootfs.raw}"
KVER="${KVER:-$(cat "$OUT/kernel.release")}"
# Must match whichever VOLUME built $KVER's objects: the original
# incremental build-kernel.sh/kernel/README.md flow used centos-kernel-build
# (DEBUG_INFO_NONE, kernel.release 6.12.0-centos10-local+); the full LUKS-
# capable build-centos-arm64-kernel.sh uses a separate
# centos-kernel-arm64-build volume (DEBUG_INFO=y, kernel.release
# 6.12.0-centos10-arm64-local+) so the two builds' objects never mix. Pass
# VOLUME=centos-kernel-arm64-build explicitly when installing modules for
# the latter -- using the wrong volume here installs the WRONG kernel's
# modules under $KVER's name (or, worse, modules_install silently succeeds
# against stale objects for a same-named but differently-configured build).
VOLUME="${VOLUME:-centos-kernel-build}"

if [[ ! -f "$DISK" ]]; then
  echo "Rootfs disk not found: $DISK" >&2
  echo "Create it first: $ROOT/qemu/centos-arm64/make-centos-rootfs.sh" >&2
  exit 1
fi
if [[ ! -d "$SRC" ]]; then
  echo "Kernel source not found: $SRC" >&2
  exit 1
fi

docker run --rm --platform linux/arm64 --privileged \
  --cpus=4 --memory=4g \
  -v "$SRC":/src \
  -v "$VOLUME":/build \
  -v "$OUT":/out \
  -w /src \
  centos-kernel-builder:el10 \
  bash -lc '
set -euo pipefail
git config --global --add safe.directory /src
dnf -y install e2fsprogs

KVER=$(cat /out/kernel.release)
echo "Installing modules for $KVER"

mkdir -p /mnt/root
mount -o loop /out/centos-rootfs.raw /mnt/root

make O=/build INSTALL_MOD_PATH=/mnt/root INSTALL_MOD_STRIP=1 modules_install

# kdumpctl defaults to kexec_file_load-ing the *running* kernel as its own
# crash kernel, reading it from /boot/vmlinuz-$(uname -r) (KDUMP_KERNEL is
# unset in this project'\''s kdump.conf) -- without this, 05-rebuild-
# kdump.sh'\''s `systemctl restart kdump` has no kernel image to load.
# Matches qemu/centos-x86/install-modules-dracut-x86.sh'\''s equivalent copy.
cp -v /out/Image "/mnt/root/boot/vmlinuz-$KVER"
cp -v /out/kernel.config "/mnt/root/boot/config-$KVER"

mount -t proc proc /mnt/root/proc
mount -t sysfs sysfs /mnt/root/sys
mount --bind /dev /mnt/root/dev

chroot /mnt/root depmod -a "$KVER"

# Generic initrd: virtio disk + ext4 so QEMU can mount the raw rootfs.
chroot /mnt/root dracut --force --no-hostonly --nomdadmconf --nolvmconf \
  --no-early-microcode \
  --add-drivers "virtio_blk virtio_pci virtio_mmio virtio_net ext4 xfs crc32c jbd2 mbcache" \
  --add "crypt dm" \
  --kver "$KVER" \
  /boot/initramfs-${KVER}.img

cp -v /mnt/root/boot/initramfs-${KVER}.img /out/initramfs.img
ls -lh /mnt/root/lib/modules/"$KVER" | head
du -sh /mnt/root/lib/modules/"$KVER"
ls -lh /out/initramfs.img

umount /mnt/root/dev /mnt/root/sys /mnt/root/proc
umount /mnt/root
echo DRACUT_SUCCESS
'

ls -lh "$OUT/initramfs.img"
echo "Wrote $OUT/initramfs.img for $KVER"
