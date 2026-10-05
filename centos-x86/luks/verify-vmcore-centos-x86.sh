#!/usr/bin/env bash
# Unlock kdump-vdb.raw (LUKS2, XFS inside) outside the guest and check for
# a saved vmcore. Companion to qemu-x86.md Section 12 Step 3, adapted for
# this guest's real kdump-utils flow: the dracut kdump module calls
# do_final_action() (normally "reboot") whether the dump succeeded or
# failed, so the QEMU serial transcript alone cannot be the pass/fail
# signal here -- this external check is the authoritative one.
#
# kdump.conf (written by encrypt_crash_kernel/scripts/04-configure-kdump.sh)
# sets "path /", so the real file lives at <mounted-root>/var/crash/<ts>/vmcore.
#
#   ./qemu/centos-x86/luks/verify-vmcore-centos-x86.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/build-out/centos-x86"
LUKS_DISK="${LUKS_DISK:-$OUT/kdump-vdb.raw}"
PASSPHRASE="${PASSPHRASE:-kdump-test-pass}"

if [[ ! -f "$LUKS_DISK" ]]; then
  echo "Missing: $LUKS_DISK" >&2
  echo "Run the LUKS kdump test first: ./qemu/centos-x86/luks/luks-kdump-centos-x86-test.py" >&2
  exit 1
fi

docker run --rm --privileged --platform linux/arm64 \
  -v "$OUT":/out \
  alpine:3.21 sh -lc '
set -eu
apk add --no-cache cryptsetup xfsprogs util-linux >/dev/null
LOOP=$(losetup -f --show /out/kdump-vdb.raw)
echo "luksUUID: $(cryptsetup luksUUID "$LOOP" 2>/dev/null || echo "(not a LUKS header -- target was never formatted/dumped)")"
if ! cryptsetup isLuks "$LOOP" 2>/dev/null; then
  echo "VERIFY_RESULT=NO_LUKS_HEADER"
  losetup -d "$LOOP"
  exit 0
fi
printf "%s" "'"$PASSPHRASE"'" | cryptsetup open --key-file - --disable-external-tokens "$LOOP" kdump_x86_extract
mkdir -p /mnt/extract
if ! mount -o ro -t xfs /dev/mapper/kdump_x86_extract /mnt/extract 2>/tmp/mnt.err; then
  echo "VERIFY_RESULT=MOUNT_FAILED"
  cat /tmp/mnt.err || true
  cryptsetup close kdump_x86_extract
  losetup -d "$LOOP"
  exit 0
fi
echo "--- contents under /var/crash ---"
find /mnt/extract/var/crash -maxdepth 3 -ls 2>/dev/null || echo "(no /var/crash directory)"
VMCORE=$(find /mnt/extract -name vmcore -type f 2>/dev/null | head -1 || true)
if [ -n "$VMCORE" ] && [ -s "$VMCORE" ]; then
  SIZE=$(stat -c %s "$VMCORE")
  echo "VERIFY_RESULT=PASS vmcore=$VMCORE bytes=$SIZE"
  cp "$VMCORE" /out/vmcore-x86.extracted
  head -c 4 "$VMCORE" | od -An -tx1
else
  echo "VERIFY_RESULT=FAIL no vmcore found under /mnt/extract"
fi
umount /mnt/extract
cryptsetup close kdump_x86_extract
losetup -d "$LOOP"
'
