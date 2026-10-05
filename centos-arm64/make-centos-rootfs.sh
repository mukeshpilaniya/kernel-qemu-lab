#!/usr/bin/env bash
# Create a CentOS Stream 10 ext4 root disk for QEMU (no kernel/modules yet --
# see install-modules-dracut.sh for that).
#
# Companion to qemu/centos-x86/make-centos-x86-rootfs.sh: same dnf
# --installroot recipe, native linux/arm64 instead of --platform linux/amd64,
# plus the same extra packages the LUKS/CONFIG_CRASH_DM_CRYPT kdump test in
# qemu/centos-arm64/luks/ needs: cryptsetup (>=2.7 for
# --link-vk-to-keyring/--volume-key-keyring), kexec-tools + kdump-utils (real
# kdumpctl, including "kdumpctl setup-crypttab"), xfsprogs (kdump.conf's dump
# filesystem), makedumpfile, keyutils, crash, and grubby (kdumpctl shells out
# to it in a few paths even with no real GRUB present). Purely additive on
# top of the original package list, so the existing plain-kexec test
# (kexec-guest-test.py / run-qemu.sh) keeps working unchanged.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build-out/centos-arm64"
DISK="${DISK:-$OUT/centos-rootfs.raw}"
SIZE="${SIZE:-8G}"

mkdir -p "$OUT"
rm -f "$DISK"
qemu-img create -f raw "$DISK" "$SIZE"

docker run --rm --platform linux/arm64 --privileged --memory=2g \
  -v "$OUT":/out \
  quay.io/centos/centos:stream10 \
  bash -lc '
set -euo pipefail
dnf -y install e2fsprogs
mkfs.ext4 -F -L centos-root /out/centos-rootfs.raw
mkdir -p /mnt/root
mount -o loop /out/centos-rootfs.raw /mnt/root

dnf -y --installroot=/mnt/root --releasever=10 \
  --setopt=install_weak_deps=False \
  --setopt=tsflags=nodocs \
  install \
    basesystem filesystem setup \
    centos-stream-release centos-stream-repos centos-gpg-keys \
    systemd systemd-udev dbus \
    bash coreutils util-linux shadow-utils passwd rootfiles hostname \
    dnf \
    kmod dracut binutils cpio gzip findutils grep sed gawk \
    e2fsprogs xfsprogs \
    procps-ng iproute iputils less vim-minimal \
    NetworkManager openssh-server sudo \
    cryptsetup keyutils kexec-tools kdump-utils makedumpfile crash grubby

UUID=$(blkid -s UUID -o value /out/centos-rootfs.raw)
printf "UUID=%s / ext4 defaults 0 1\n" "$UUID" > /mnt/root/etc/fstab

if [ -f /mnt/root/etc/selinux/config ]; then
  sed -i "s/^SELINUX=.*/SELINUX=disabled/" /mnt/root/etc/selinux/config
fi

echo "centos-stream-10" > /mnt/root/etc/hostname
echo "root:root" | chroot /mnt/root chpasswd

mkdir -p /mnt/root/etc/systemd/system/getty.target.wants
ln -sf /usr/lib/systemd/system/serial-getty@.service \
  /mnt/root/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service

# Allow root login on the serial console.
if [ -f /mnt/root/etc/securetty ]; then
  grep -qx ttyAMA0 /mnt/root/etc/securetty || echo ttyAMA0 >> /mnt/root/etc/securetty
fi

# systemd-machine-id so first boot is quieter
systemd-machine-id-setup --root=/mnt/root || true

sync
umount /mnt/root
echo ROOTFS_SUCCESS
'

ls -lh "$DISK"
echo "Wrote $DISK (root password: root)"
