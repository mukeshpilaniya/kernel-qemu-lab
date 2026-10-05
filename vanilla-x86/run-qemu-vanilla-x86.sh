#!/usr/bin/env bash
# Boot the vanilla x86_64 bzImage + busybox ext4 rootfs.
# Apple Silicon cannot HVF an x86 guest; TCG is required:
#   ./qemu/vanilla-x86/run-qemu-vanilla-x86.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KERNEL="${KERNEL:-$ROOT/build-out/vanilla-x86/bzImage}"
DISK="${DISK:-$ROOT/build-out/vanilla-x86/rootfs.raw}"
QEMU="${QEMU:-qemu-system-x86_64}"

for f in "$KERNEL" "$DISK"; do
  if [[ ! -f "$f" ]]; then
    echo "Missing: $f" >&2
    echo "Build with ./qemu/vanilla-x86/build-vanilla-x86-kernel.sh and ./qemu/vanilla-x86/make-busybox-rootfs-x86.sh" >&2
    exit 1
  fi
done

APPEND="console=ttyS0 nokaslr root=/dev/vda rootfstype=ext4 rw"
if [[ -n "${EXTRA_APPEND:-}" ]]; then
  APPEND+=" ${EXTRA_APPEND}"
fi

echo "Busybox sh on serial (no password). Quit QEMU with Ctrl-a then x"
echo "Using -machine q35 -accel tcg -cpu ${CPU:-max} -smp ${SMP:-1}"
echo "Append: $APPEND"

exec "$QEMU" \
  -machine q35 \
  -accel tcg \
  -cpu "${CPU:-max}" \
  -smp "${SMP:-1}" \
  -m 1G \
  -kernel "$KERNEL" \
  -drive file="$DISK",if=virtio,format=raw \
  -append "$APPEND" \
  -nographic
