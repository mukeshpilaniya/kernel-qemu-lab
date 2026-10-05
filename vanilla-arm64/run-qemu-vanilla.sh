#!/usr/bin/env bash
# Boot the vanilla torvalds Image + busybox ext4 rootfs (no dracut).
# TCG + EL2 is required for kexec -e:
#   ACCEL=tcg VIRTUALIZATION=1 SMP=1 ./qemu/vanilla-arm64/run-qemu-vanilla.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KERNEL="${KERNEL:-$ROOT/build-out/vanilla-arm64/Image}"
DISK="${DISK:-$ROOT/build-out/vanilla-arm64/rootfs.raw}"
QEMU="${QEMU:-qemu-system-aarch64}"

for f in "$KERNEL" "$DISK"; do
  if [[ ! -f "$f" ]]; then
    echo "Missing: $f" >&2
    echo "Build with ./qemu/vanilla-arm64/build-vanilla-kernel.sh and ./qemu/vanilla-arm64/make-busybox-rootfs.sh" >&2
    exit 1
  fi
done

MACHINE="virt,gic-version=3"
if [[ "${VIRTUALIZATION:-0}" == "1" ]]; then
  MACHINE+=",virtualization=on"
fi

case "${ACCEL:-hvf}" in
  tcg) ACCEL_ARGS=( -accel tcg -cpu "${CPU:-max}" ) ;;
  hvf) ACCEL_ARGS=( -accel hvf -cpu host ) ;;
  *) echo "ACCEL must be hvf or tcg" >&2; exit 1 ;;
esac

APPEND="console=ttyAMA0 earlycon=pl011,0x09000000 nokaslr root=/dev/vda rootfstype=ext4 rw"
if [[ -n "${EXTRA_APPEND:-}" ]]; then
  APPEND+=" ${EXTRA_APPEND}"
fi

echo "Busybox sh on serial (no password). Quit QEMU with Ctrl-a then x"
echo "Using -machine $MACHINE ${ACCEL_ARGS[*]} -smp ${SMP:-1}"
echo "Append: $APPEND"

set -x
exec "$QEMU" \
  -machine "$MACHINE" \
  "${ACCEL_ARGS[@]}" \
  -smp "${SMP:-1}" \
  -m 1G \
  -kernel "$KERNEL" \
  -drive file="$DISK",if=virtio,format=raw \
  -append "$APPEND" \
  -nographic
