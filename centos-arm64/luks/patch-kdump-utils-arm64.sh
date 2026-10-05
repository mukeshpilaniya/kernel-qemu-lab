#!/usr/bin/env bash
# Lift kdump-utils' hardcoded "x86_64 only" gates on the CONFIG_CRASH_DM_CRYPT
# integration, inside the already-built centos-rootfs.raw.
#
# WHY THIS SCRIPT EXISTS (and has no x86 counterpart):
# The *kernel* side of ARM64 LUKS-kdump support is the 3-commit series
# cherry-picked into centos-stream-10/src (see build-out/centos-arm64/
# README.md, "The missing commits" section) -- that part is upstream-recent
# (Feb 2026) but genuinely new. The *userspace* side, kdump-utils 1.0.61 (the
# exact version `dnf` installs from CentOS Stream 10's repos, see
# make-centos-rootfs.sh), has NOT caught up: its three functions that drive
# the whole feature are each individually gated to x86_64 only --
#   - kdumpctl's prepare_luks()        (~line 1184): populates
#     /sys/kernel/config/crash_dm_crypt_keys/<uuid>/description before
#     kexec_file_load, so the kernel knows which keys to copy into
#     crash-reserved memory. Skipped entirely on aarch64 -> configfs
#     count stays 0 -> there is nothing for the kernel to save, regardless
#     of whether the DT dmcryptkeys plumbing itself is correct.
#   - kdumpctl's setup_crypttab()      (~line 1272): writes the
#     link-volume-key= crypttab option. Skipped on aarch64 -> crypttab is
#     left with 04-configure-kdump.sh's provisional keyfile-path entry.
#   - 99kdumpbase/module-setup.sh's kdump_check_crypt_targets() (~line 1118):
#     builds the crash kernel's OWN dracut module (the cryptsetup
#     luksOpen --volume-key-keyring udev rule). Skipped on aarch64 -> the
#     crash kernel's initramfs has no self-contained unlock mechanism at
#     all, regardless of what the first kernel did.
# This is confirmed as a genuine, still-current upstream gap, not something
# this project is working around incorrectly: the kernel's own
# Documentation/admin-guide/kdump/kdump.rst (as of this writing) still says
# "CONFIG_CRASH_DM_CRYPT ... (only x86_64 supported for now)" -- kdump-utils
# simply has not been updated for the brand-new kernel-side ARM64 enablement
# yet. All three gated code paths are otherwise 100% architecture-generic
# (UUID-based device lookup via get_all_kdump_crypt_dev, the generic
# /sys/kernel/config/crash_dm_crypt_keys configfs interface, and a plain
# `cryptsetup luksOpen --volume-key-keyring` udev rule -- no x86-specific
# boot_params/e820 code anywhere in these three functions), which is what
# makes lifting the gate a correct fix rather than a hack: nothing else in
# these functions needs to change for aarch64.
#
#   ./qemu/centos-arm64/luks/patch-kdump-utils-arm64.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/build-out/centos-arm64"
DISK="${DISK:-$OUT/centos-rootfs.raw}"

if [[ ! -f "$DISK" ]]; then
  echo "Rootfs disk not found: $DISK" >&2
  echo "Create it first: $ROOT/qemu/centos-arm64/make-centos-rootfs.sh" >&2
  exit 1
fi

docker run --rm --platform linux/arm64 --privileged \
  -v "$OUT":/out \
  alpine:3.21 sh -lc '
set -eu
mkdir -p /mnt/root
mount -o loop /out/centos-rootfs.raw /mnt/root

K=/mnt/root/usr/bin/kdumpctl
M=/mnt/root/usr/lib/dracut/modules.d/99kdumpbase/module-setup.sh

echo "--- before ---"
grep -n "x86_64" "$K" "$M" | grep -iE "only|supported"

# prepare_luks() and setup_crypttab() in kdumpctl share the exact same
# guard text, each on its own line -- a plain (non-anchored) substitution
# hits both, one per line, in a single pass.
sed -i "s|if \[\[ \"\$(uname -m)\" != \"x86_64\" \]\]; then|if [[ \"\$(uname -m)\" != \"x86_64\" \&\& \"\$(uname -m)\" != \"aarch64\" ]]; then|" "$K"

# kdump_check_crypt_targets() in the dracut module: one-line early return.
sed -i "s|\[\[ \"\$(uname -m)\" != \"x86_64\" \]\] \&\& return 1|[[ \"\$(uname -m)\" != \"x86_64\" \&\& \"\$(uname -m)\" != \"aarch64\" ]] \&\& return 1|" "$M"

echo "--- after ---"
grep -n "x86_64" "$K" "$M" | grep -iE "only|supported|aarch64"

sync
umount /mnt/root
echo KDUMP_UTILS_ARM64_PATCH_OK
'

echo "Patched kdump-utils x86_64-only gates for aarch64 in $DISK"
