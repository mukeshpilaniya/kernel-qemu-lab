#!/usr/bin/env bash
# Boot the custom CentOS Stream 10 kernel with dracut initrd + CentOS rootfs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KERNEL="${KERNEL:-$ROOT/build-out/centos-arm64/Image}"
INITRD="${INITRD:-$ROOT/build-out/centos-arm64/initramfs.img}"
DISK="${DISK:-$ROOT/build-out/centos-arm64/centos-rootfs.raw}"
QEMU="${QEMU:-qemu-system-aarch64}"

for f in "$KERNEL" "$INITRD" "$DISK"; do
  if [[ ! -f "$f" ]]; then
    echo "Missing: $f" >&2
    echo "Build with:" >&2
    echo "  $ROOT/qemu/centos-arm64/make-centos-rootfs.sh" >&2
    echo "  # plus kernel modules + $ROOT/qemu/centos-arm64/install-modules-dracut.sh" >&2
    exit 1
  fi
done

# ACCEL=hvf (default on Apple Silicon) or ACCEL=tcg (needed for kexec -e)
# VIRTUALIZATION=1 adds EL2 so arm64 cpu_soft_restart can jump to the new kernel
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
#APPEND="console=ttyAMA0 earlycon=pl011,0x09000000 nokaslr root=/dev/vda rootfstype=ext4 rw selinux=0 rootwait"
if [[ -n "${EXTRA_APPEND:-}" ]]; then
  APPEND+=" ${EXTRA_APPEND}"
fi

echo "Login: root / root   (quit QEMU with Ctrl-a then x)"
echo "Using -machine $MACHINE ${ACCEL_ARGS[*]} -smp ${SMP:-2}"
echo "Append: $APPEND"

set -x 
exec "$QEMU" \
  -machine "$MACHINE" \
  "${ACCEL_ARGS[@]}" \
  -smp "${SMP:-1}" \
  -m 4G \
  -kernel "$KERNEL" \
  -initrd "$INITRD" \
  -drive file="$DISK",if=virtio,format=raw \
  -append "$APPEND" \
  -nographic
