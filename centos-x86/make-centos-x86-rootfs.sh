#!/usr/bin/env bash
# Create a CentOS Stream 10 x86_64 ext4 root disk for QEMU (no kernel/modules
# yet -- see install-modules-dracut-x86.sh for that).
#
# Companion to qemu/centos-arm64/make-centos-rootfs.sh: same dnf --installroot
# recipe, --platform linux/amd64 instead of arm64, plus the extra packages
# the LUKS/CONFIG_CRASH_DM_CRYPT kdump test in qemu/centos-x86/luks/ needs:
# cryptsetup (>=2.7 for --link-vk-to-keyring/--volume-key-keyring),
# kexec-tools + kdump-utils (real kdumpctl, including "kdumpctl
# setup-crypttab" -- confirmed present in kdump-utils 1.0.61-2.el10),
# xfsprogs (kdump.conf's dump filesystem), makedumpfile, keyutils, crash,
# and grubby (kdumpctl shells out to it in a few paths even though this
# QEMU test has no real GRUB).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build-out/centos-x86"
DISK="${DISK:-$OUT/centos-rootfs-x86.raw}"
SIZE="${SIZE:-8G}"

mkdir -p "$OUT"
rm -f "$DISK"
qemu-img create -f raw "$DISK" "$SIZE"

docker run --rm --platform linux/amd64 --privileged --memory=2g \
  -v "$OUT":/out \
  quay.io/centos/centos:stream10 \
  bash -lc '
set -euo pipefail
dnf -y install e2fsprogs
mkfs.ext4 -F -L centos-x86-root /out/centos-rootfs-x86.raw
mkdir -p /mnt/root
mount -o loop /out/centos-rootfs-x86.raw /mnt/root

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

UUID=$(blkid -s UUID -o value /out/centos-rootfs-x86.raw)
printf "UUID=%s / ext4 defaults 0 1\n" "$UUID" > /mnt/root/etc/fstab

if [ -f /mnt/root/etc/selinux/config ]; then
  sed -i "s/^SELINUX=.*/SELINUX=disabled/" /mnt/root/etc/selinux/config
fi

echo "centos-stream-10-x86" > /mnt/root/etc/hostname
echo "root:root" | chroot /mnt/root chpasswd

mkdir -p /mnt/root/etc/systemd/system/getty.target.wants
ln -sf /usr/lib/systemd/system/serial-getty@.service \
  /mnt/root/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service

# x86_64 serial console device is ttyS0 (arm64 uses ttyAMA0).
if [ -f /mnt/root/etc/securetty ]; then
  grep -qx ttyS0 /mnt/root/etc/securetty || echo ttyS0 >> /mnt/root/etc/securetty
fi

systemd-machine-id-setup --root=/mnt/root || true

sync
umount /mnt/root
echo ROOTFS_X86_SUCCESS
'

ls -lh "$DISK"
echo "Wrote $DISK (root password: root)"
