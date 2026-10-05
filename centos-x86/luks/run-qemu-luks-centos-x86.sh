#!/usr/bin/env bash
# Boot the compiled centos-x86 kernel + dracut initrd + full CentOS rootfs,
# with a second raw virtio disk for the encrypted kdump target.
# The second disk is /dev/vdb inside the guest -- do not substitute a loop
# file, the crash kernel will not see the loop mapping.
#
# Apple Silicon cannot HVF an x86 guest; TCG is required.
#   ./qemu/centos-x86/luks/run-qemu-luks-centos-x86.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/build-out/centos-x86"
KVER="${KVER:-$(cat "$OUT/kernel.release" 2>/dev/null || true)}"
KERNEL="${KERNEL:-$OUT/bzImage}"
INITRD="${INITRD:-$OUT/initramfs-x86.img}"
DISK="${DISK:-$OUT/centos-rootfs-x86.raw}"
LUKS_DISK="${LUKS_DISK:-$OUT/kdump-vdb.raw}"
QEMU="${QEMU:-qemu-system-x86_64}"
MEM="${MEM:-2048}"

for f in "$KERNEL" "$INITRD" "$DISK"; do
  if [[ ! -f "$f" ]]; then
    echo "Missing: $f" >&2
    echo "Build with:" >&2
    echo "  $ROOT/qemu/centos-x86/build-centos-x86-kernel.sh" >&2
    echo "  $ROOT/qemu/centos-x86/make-centos-x86-rootfs.sh" >&2
    echo "  $ROOT/qemu/centos-x86/install-modules-dracut-x86.sh" >&2
    echo "  $ROOT/qemu/centos-x86/luks/stage-kdump-scripts-x86.sh" >&2
    exit 1
  fi
done

if [[ ! -f "$LUKS_DISK" ]]; then
  echo "Creating sparse dump disk $LUKS_DISK (2048MiB)"
  mkdir -p "$(dirname "$LUKS_DISK")"
  if ! truncate -s 2048M "$LUKS_DISK" 2>/dev/null; then
    dd if=/dev/zero of="$LUKS_DISK" bs=1M count=2048
  fi
fi

APPEND="console=ttyS0 nokaslr root=/dev/vda rootfstype=ext4 rw crashkernel=256M"
if [[ -n "${EXTRA_APPEND:-}" ]]; then
  APPEND+=" ${EXTRA_APPEND}"
fi

echo "Login: root / root   (quit QEMU with Ctrl-a then x)"
echo "Using -machine q35 -accel tcg -cpu ${CPU:-max} -m ${MEM} -smp ${SMP:-2} ($KVER)"
echo "Append: $APPEND"
echo "Disks: $DISK (vda)  $LUKS_DISK (vdb)"

exec "$QEMU" \
  -machine q35 \
  -accel tcg \
  -cpu "${CPU:-max}" \
  -smp "${SMP:-2}" \
  -m "$MEM" \
  -no-reboot \
  -kernel "$KERNEL" \
  -initrd "$INITRD" \
  -drive "file=${DISK},if=virtio,format=raw" \
  -drive "file=${LUKS_DISK},if=virtio,format=raw" \
  -device virtio-rng-pci \
  -append "$APPEND" \
  -nographic
