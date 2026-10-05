#!/usr/bin/env bash
# Boot the compiled x86_64 CentOS Stream 10 kernel + dracut initrd + full
# CentOS rootfs (no second LUKS disk -- see qemu/centos-x86/luks/ for that).
# Companion to qemu/centos-arm64/run-qemu.sh.
#
# Apple Silicon cannot HVF an x86 guest; TCG is required.
#   ./qemu/centos-x86/run-qemu-centos-x86.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build-out/centos-x86"
KVER="${KVER:-$(cat "$OUT/kernel.release" 2>/dev/null || true)}"
KERNEL="${KERNEL:-$OUT/bzImage}"
INITRD="${INITRD:-$OUT/initramfs-x86.img}"
DISK="${DISK:-$OUT/centos-rootfs-x86.raw}"
QEMU="${QEMU:-qemu-system-x86_64}"

for f in "$KERNEL" "$INITRD" "$DISK"; do
  if [[ ! -f "$f" ]]; then
    echo "Missing: $f" >&2
    echo "Build with:" >&2
    echo "  $ROOT/qemu/centos-x86/build-centos-x86-kernel.sh" >&2
    echo "  $ROOT/qemu/centos-x86/make-centos-x86-rootfs.sh" >&2
    echo "  $ROOT/qemu/centos-x86/install-modules-dracut-x86.sh" >&2
    exit 1
  fi
done

APPEND="console=ttyS0 nokaslr root=/dev/vda rootfstype=ext4 rw crashkernel=256M"
if [[ -n "${EXTRA_APPEND:-}" ]]; then
  APPEND+=" ${EXTRA_APPEND}"
fi

echo "Login: root / root   (quit QEMU with Ctrl-a then x)"
echo "Using -machine q35 -accel tcg -cpu ${CPU:-max} -smp ${SMP:-2} ($KVER)"
echo "Append: $APPEND"

exec "$QEMU" \
  -machine q35 \
  -accel tcg \
  -cpu "${CPU:-max}" \
  -smp "${SMP:-2}" \
  -m "${MEM:-2G}" \
  -kernel "$KERNEL" \
  -initrd "$INITRD" \
  -drive file="$DISK",if=virtio,format=raw \
  -append "$APPEND" \
  -nographic
