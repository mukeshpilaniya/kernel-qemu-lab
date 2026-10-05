#!/usr/bin/env bash
# Boot the x86_64 bzImage with a busybox rootfs and a second raw virtio disk.
# The second disk is /dev/vdb inside the guest. Do not substitute a loop file:
# the crash kernel would not see the loop mapping.
#
# Apple Silicon cannot HVF an x86 guest; TCG is required.
#   ./qemu/vanilla-x86/luks/run-qemu-luks-x86.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
KERNEL="${KERNEL:-$ROOT/build-out/vanilla-x86/bzImage}"
DISK="${DISK:-$ROOT/build-out/vanilla-x86/rootfs-luks.raw}"
LUKS_DISK="${LUKS_DISK:-$ROOT/build-out/vanilla-x86/kdump-vdb.raw}"
QEMU="${QEMU:-qemu-system-x86_64}"
MEM="${MEM:-1024}"

for f in "$KERNEL" "$DISK"; do
	if [[ ! -f "$f" ]]; then
		echo "Missing: $f" >&2
		echo "Build with ./qemu/vanilla-x86/luks/build-vanilla-x86-kernel.sh and ./qemu/vanilla-x86/luks/make-luks-rootfs-x86.sh" >&2
		exit 1
	fi
done

if [[ ! -f "$LUKS_DISK" ]]; then
	echo "Creating sparse dump disk $LUKS_DISK (1536MiB)"
	mkdir -p "$(dirname "$LUKS_DISK")"
	# macOS truncate, then a Linux fallback.
	if ! truncate -s 1536M "$LUKS_DISK" 2>/dev/null; then
		dd if=/dev/zero of="$LUKS_DISK" bs=1M count=1536
	fi
fi

APPEND="console=ttyS0 nokaslr root=/dev/vda rootfstype=ext4 rw crashkernel=256M"
if [[ -n "${EXTRA_APPEND:-}" ]]; then
	APPEND+=" ${EXTRA_APPEND}"
fi

echo "Busybox sh on serial (no password). Quit QEMU with Ctrl-a then x"
echo "Using -machine q35 -accel tcg -cpu ${CPU:-max} -m ${MEM} -smp ${SMP:-1}"
echo "Append: $APPEND"
echo "Disks: $DISK (vda)  $LUKS_DISK (vdb)"

exec "$QEMU" \
	-machine q35 \
	-accel tcg \
	-cpu "${CPU:-max}" \
	-smp "${SMP:-1}" \
	-m "$MEM" \
	-no-reboot \
	-kernel "$KERNEL" \
	-drive "file=${DISK},if=virtio,format=raw" \
	-drive "file=${LUKS_DISK},if=virtio,format=raw" \
	-device virtio-rng-pci \
	-append "$APPEND" \
	-nographic
