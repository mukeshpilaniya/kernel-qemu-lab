#!/usr/bin/env bash
# x86_64 ext4 rootfs for the CONFIG_CRASH_DM_CRYPT QEMU test.
# Busybox + cryptsetup 2.7 + kexec, plus /boot/kdump.cpio for the crash kernel.
#
#   ./qemu/vanilla-x86/luks/make-luks-rootfs-x86.sh
#
# Does not modify build-out/vanilla-x86/rootfs.raw.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/build-out/vanilla-x86"
DISK="$OUT/rootfs-luks.raw"
KERNEL="${KERNEL:-$OUT/bzImage}"
KEXEC="${KEXEC:-$OUT/kexec}"
GUEST="$ROOT/qemu/vanilla-x86/luks/luks-guest"

if [[ ! -f "$KERNEL" ]]; then
	echo "Missing $KERNEL — run ./qemu/vanilla-x86/luks/build-vanilla-x86-kernel.sh first." >&2
	exit 1
fi
if [[ ! -f "$KEXEC" ]]; then
	echo "Missing $KEXEC — put an x86_64 kexec binary there first." >&2
	exit 1
fi
if ! grep -q '^CONFIG_CRASH_DM_CRYPT=y' "$OUT/kernel.config"; then
	echo "kernel.config has no CONFIG_CRASH_DM_CRYPT=y." >&2
	echo "Rebuild with ./qemu/vanilla-x86/luks/build-vanilla-x86-kernel.sh before making this rootfs." >&2
	exit 1
fi
mkdir -p "$OUT"

docker run --rm --platform linux/amd64 \
	-v "$OUT":/out \
	-v "$GUEST":/guest:ro \
	alpine:3.21 \
	sh /guest/stage-userspace.sh

docker run --rm --platform linux/arm64 --privileged \
	-v "$OUT":/out \
	-v "$KERNEL":/tmp/bzImage:ro \
	-v "$KEXEC":/tmp/kexec:ro \
	alpine:3.21 \
	sh -lc '
set -eu
apk add --no-cache e2fsprogs
rm -f /out/rootfs-luks.raw
dd if=/dev/zero of=/out/rootfs-luks.raw bs=1M count=512
mkfs.ext4 -F -L luks-x86 /out/rootfs-luks.raw
mkdir -p /mnt/root
mount -o loop /out/rootfs-luks.raw /mnt/root
cp -a /out/luks-stage/rootfs/. /mnt/root/
cp /tmp/bzImage /mnt/root/boot/bzImage
cp /tmp/kexec /mnt/root/usr/bin/kexec
chmod 0755 /mnt/root/usr/bin/kexec
cp /out/luks-stage/kdump.cpio /mnt/root/boot/kdump.cpio
sync
umount /mnt/root
echo LUKS_X86_ROOTFS_OK
'
ls -lh "$DISK" "$OUT/luks-stage/kdump.cpio"
echo "Wrote $DISK"
