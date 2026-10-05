#!/usr/bin/env bash
# Boot the compiled centos-arm64 kernel + dracut initrd + full CentOS
# rootfs, with a second raw virtio disk for the encrypted kdump target.
# The second disk is /dev/vdb inside the guest -- do not substitute a loop
# file, the crash kernel will not see the loop mapping.
#
# Unlike qemu/centos-x86/luks/run-qemu-luks-centos-x86.sh (forced to TCG
# because Apple Silicon cannot HVF an x86 guest at all), this host CAN HVF
# an arm64 guest for a plain boot (see qemu/centos-arm64/run-qemu.sh).
# TCG + virtualization=on (EL2) is used here anyway, and is NOT just a
# slower equivalent: arch/arm64/kernel/machine_kexec.c's machine_kexec()
# is shared between a normal kexec reboot and the kdump crash-kernel jump
# (gated by `in_kexec_crash`), and on a non-hyp-mode boot it calls
# __hyp_set_vectors(kimage->arch.el2_vectors) before jumping via
# cpu_soft_restart() -- i.e. the kexec/kdump jump itself needs EL2 to be
# present and usable, the same requirement qemu/vanilla-arm64/run-qemu-
# vanilla.sh documents for plain `kexec -e` ("TCG + EL2 is required").
# QEMU TCG's `virtualization=on` reliably provides that nested EL2; HVF's
# support for it is not something this project has validated, so TCG is
# the default here even though it is slower than HVF for the boot itself.
#   ./qemu/centos-arm64/luks/run-qemu-luks-centos-arm64.sh
#   ACCEL=hvf ./qemu/centos-arm64/luks/run-qemu-luks-centos-arm64.sh   # NOT validated for the crash-kernel jump
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/build-out/centos-arm64"
KVER="${KVER:-$(cat "$OUT/kernel.release" 2>/dev/null || true)}"
KERNEL="${KERNEL:-$OUT/Image}"
INITRD="${INITRD:-$OUT/initramfs.img}"
DISK="${DISK:-$OUT/centos-rootfs.raw}"
LUKS_DISK="${LUKS_DISK:-$OUT/kdump-vdb.raw}"
QEMU="${QEMU:-qemu-system-aarch64}"
MEM="${MEM:-2048}"

for f in "$KERNEL" "$INITRD" "$DISK"; do
  if [[ ! -f "$f" ]]; then
    echo "Missing: $f" >&2
    echo "Build with:" >&2
    echo "  $ROOT/qemu/centos-arm64/build-centos-arm64-kernel.sh" >&2
    echo "  $ROOT/qemu/centos-arm64/make-centos-rootfs.sh" >&2
    echo "  $ROOT/qemu/centos-arm64/install-modules-dracut.sh" >&2
    echo "  $ROOT/qemu/centos-arm64/luks/stage-kdump-scripts-arm64.sh" >&2
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

MACHINE="virt,gic-version=3"
if [[ "${VIRTUALIZATION:-1}" == "1" ]]; then
  MACHINE+=",virtualization=on"
fi

case "${ACCEL:-tcg}" in
  tcg) ACCEL_ARGS=( -accel tcg -cpu "${CPU:-max}" ) ;;
  hvf) ACCEL_ARGS=( -accel hvf -cpu host ) ;;
  *) echo "ACCEL must be tcg or hvf" >&2; exit 1 ;;
esac

APPEND="console=ttyAMA0 earlycon=pl011,0x09000000 nokaslr root=/dev/vda rootfstype=ext4 rw crashkernel=256M"
if [[ -n "${EXTRA_APPEND:-}" ]]; then
  APPEND+=" ${EXTRA_APPEND}"
fi

echo "Login: root / root   (quit QEMU with Ctrl-a then x)"
echo "Using -machine $MACHINE ${ACCEL_ARGS[*]} -m ${MEM} -smp ${SMP:-1} ($KVER)"
echo "Append: $APPEND"
echo "Disks: $DISK (vda)  $LUKS_DISK (vdb)"

exec "$QEMU" \
  -machine "$MACHINE" \
  "${ACCEL_ARGS[@]}" \
  -smp "${SMP:-1}" \
  -m "$MEM" \
  -no-reboot \
  -kernel "$KERNEL" \
  -initrd "$INITRD" \
  -drive "file=${DISK},if=virtio,format=raw" \
  -drive "file=${LUKS_DISK},if=virtio,format=raw" \
  -device virtio-rng-pci \
  -append "$APPEND" \
  -nographic
