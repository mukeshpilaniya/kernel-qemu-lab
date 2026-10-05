#!/usr/bin/env bash
# Tiny x86_64 ext4 rootfs: static busybox + /boot/bzImage.
#
#   ./qemu/vanilla-x86/make-busybox-rootfs-x86.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build-out/vanilla-x86"
DISK="$OUT/rootfs.raw"
KERNEL="${KERNEL:-$OUT/bzImage}"
KEXEC="${KEXEC:-$OUT/kexec}"

if [[ ! -f "$KERNEL" ]]; then
  echo "Missing $KERNEL — run ./qemu/vanilla-x86/build-vanilla-x86-kernel.sh first." >&2
  exit 1
fi
if [[ ! -f "$KEXEC" ]]; then
  echo "Missing $KEXEC — put an x86_64 kexec binary there first." >&2
  exit 1
fi
mkdir -p "$OUT"

# x86_64 busybox (static) from Alpine amd64, then format the disk natively.
docker run --rm --platform linux/amd64 \
  -v "$OUT":/out \
  alpine:3.21 \
  sh -lc 'apk add --no-cache busybox-static && cp /bin/busybox.static /out/busybox.x86_64'

docker run --rm --platform linux/arm64 --privileged \
  -v "$OUT":/out \
  -v "$KERNEL":/tmp/bzImage:ro \
  -v "$KEXEC":/tmp/kexec:ro \
  alpine:3.21 \
  sh -lc '
set -eu
apk add --no-cache e2fsprogs
rm -f /out/rootfs.raw
dd if=/dev/zero of=/out/rootfs.raw bs=1M count=256
mkfs.ext4 -F -L vanilla-x86 /out/rootfs.raw
mkdir -p /mnt/root
mount -o loop /out/rootfs.raw /mnt/root
mkdir -p /mnt/root/bin /mnt/root/sbin /mnt/root/usr/bin /mnt/root/proc \
         /mnt/root/sys /mnt/root/dev /mnt/root/tmp /mnt/root/root /mnt/root/boot
cp /out/busybox.x86_64 /mnt/root/bin/busybox
chmod 0755 /mnt/root/bin/busybox
for a in sh ash mount umount mkdir ls cat echo ln rm cp mv sleep \
         uname dmesg reboot poweroff; do
  ln -sf busybox /mnt/root/bin/"$a"
done
cp /tmp/bzImage /mnt/root/boot/bzImage
cp /tmp/kexec /mnt/root/usr/bin/kexec
chmod 0755 /mnt/root/usr/bin/kexec
rm -f /mnt/root/sbin/init /mnt/root/init /mnt/root/bin/init
cat > /mnt/root/sbin/init << '"'"'EOF'"'"'
#!/bin/busybox sh
export PATH=/bin:/sbin:/usr/bin
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null || /bin/busybox mount -t tmpfs tmpfs /dev
/bin/busybox mkdir -p /dev/pts /tmp
/bin/busybox mount -t devpts devpts /dev/pts 2>/dev/null || true
echo
echo "vanilla x86_64 busybox guest  —  kexec is /usr/bin/kexec  kernel is /boot/bzImage"
echo
exec /bin/busybox sh
EOF
chmod 0755 /mnt/root/sbin/init
cp /mnt/root/sbin/init /mnt/root/init
sync
umount /mnt/root
rm -f /out/busybox.x86_64
echo BUSYBOX_X86_ROOTFS_OK
'
ls -lh "$DISK"
echo "Wrote $DISK"
