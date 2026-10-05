#!/usr/bin/env bash
# Tiny ext4 rootfs: static busybox + kexec + /boot/Image. No dracut.
#
#   ./qemu/vanilla-arm64/make-busybox-rootfs.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build-out/vanilla-arm64"
DISK="$OUT/rootfs.raw"
# kexec is not built by the vanilla-arm64 tree; reuse the kexec-tools binary
# produced by the centos-arm64 build. Override with KEXEC= if that moved.
KEXEC="${KEXEC:-$ROOT/build-out/centos-arm64/kexec}"
KERNEL="${KERNEL:-$OUT/Image}"

if [[ ! -f "$KERNEL" ]]; then
  echo "Missing $KERNEL — run ./qemu/vanilla-arm64/build-vanilla-kernel.sh first." >&2
  exit 1
fi
if [[ ! -f "$KEXEC" ]]; then
  echo "Missing $KEXEC" >&2
  exit 1
fi
mkdir -p "$OUT"

docker run --rm --platform linux/arm64 --privileged \
  -v "$OUT":/out \
  -v "$KEXEC":/tmp/kexec:ro \
  -v "$KERNEL":/tmp/Image:ro \
  alpine:3.21 \
  sh -lc '
set -eu
apk add --no-cache e2fsprogs busybox-static
rm -f /out/rootfs.raw
dd if=/dev/zero of=/out/rootfs.raw bs=1M count=256
mkfs.ext4 -F -L vanilla-root /out/rootfs.raw
mkdir -p /mnt/root
mount -o loop /out/rootfs.raw /mnt/root
mkdir -p /mnt/root/bin /mnt/root/sbin /mnt/root/usr/bin /mnt/root/proc \
         /mnt/root/sys /mnt/root/dev /mnt/root/tmp /mnt/root/root /mnt/root/boot
cp /bin/busybox.static /mnt/root/bin/busybox
chmod 0755 /mnt/root/bin/busybox
# busybox --install writes absolute paths; make relative applet links instead
for a in sh ash mount umount mkdir ls cat echo ln rm cp mv sleep \
         uname dmesg reboot poweroff; do
  ln -sf busybox /mnt/root/bin/"$a"
done
cp /tmp/kexec /mnt/root/usr/bin/kexec
chmod 0755 /mnt/root/usr/bin/kexec
cp /tmp/Image /mnt/root/boot/Image
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
echo "vanilla busybox guest  —  kexec is /usr/bin/kexec  Image is /boot/Image"
echo
exec /bin/busybox sh
EOF
chmod 0755 /mnt/root/sbin/init
cp /mnt/root/sbin/init /mnt/root/init
sync
umount /mnt/root
echo BUSYBOX_ROOTFS_OK
'
ls -lh "$DISK"
echo "Wrote $DISK"
