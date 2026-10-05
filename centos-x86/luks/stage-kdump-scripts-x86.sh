#!/usr/bin/env bash
# Stage the real encrypt_crash_kernel/scripts/ kdump-utils-based LUKS test
# toolkit into the compiled centos-x86 rootfs, at /root/kdump-scripts/.
#
# Why reuse that toolkit instead of hand-rolling a busybox-style harness
# (the way qemu/vanilla-x86/luks/ does): the centos-x86 rootfs has a real
# systemd + dnf-installed kexec-tools + kdump-utils (kdumpctl), confirmed to
# include "kdumpctl setup-crypttab" and the dracut kdump module's
# kexec-crypt-setup.sh -- i.e. the actual production CONFIG_CRASH_DM_CRYPT
# integration path, not a stand-in. vanilla-x86 needed its own harness only
# because its busybox rootfs has no systemd/kdump-utils at all.
#
#   ./qemu/centos-x86/luks/stage-kdump-scripts-x86.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/build-out/centos-x86"
DISK="${DISK:-$OUT/centos-rootfs-x86.raw}"
SRC_SCRIPTS="$(cd "$ROOT/../encrypt_crash_kernel/scripts" && pwd)"

if [[ ! -f "$DISK" ]]; then
  echo "Rootfs disk not found: $DISK" >&2
  echo "Create it first: $ROOT/qemu/centos-x86/make-centos-x86-rootfs.sh" >&2
  exit 1
fi
if [[ ! -d "$SRC_SCRIPTS" ]]; then
  echo "encrypt_crash_kernel/scripts not found at $SRC_SCRIPTS" >&2
  exit 1
fi

STAGE="$OUT/kdump-scripts-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -a "$SRC_SCRIPTS/." "$STAGE/"

# Chains the non-destructive/setup scripts, then triggers the panic.
# METHOD=sysrq (not the default METHOD=test / "kdumpctl test --force"):
# a direct SysRq c is the exact mechanism already proven end-to-end in
# qemu/vanilla-x86/luks/, and keeps this QEMU test independent of
# kdumpctl's own "test" bookkeeping (test id files under /var/lib/kdump),
# which assumes a more complete boot/journal environment than this
# single-shot QEMU run provides.
cat > "$STAGE/run-all.sh" <<'EOF'
#!/bin/bash
# Chains 01/03/04/05/06 (setup, non-destructive to destructive), then 07
# (the panic). Run as root at the QEMU serial console.
#   sh /root/kdump-scripts/run-all.sh
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
"$DIR/01-verify-prereqs.sh" || echo "[WARN] 01-verify-prereqs reported gaps; continuing"
# FORCE=yes: on a *re*-run against the same rootfs disk image (not a fresh
# one), systemd auto-activates kdump_luks at boot via the /etc/crypttab
# entry the previous run's 04-configure-kdump.sh already wrote and
# persisted to disk -- 03's own "already active" guard would otherwise
# correctly, but inconveniently, refuse to re-format on every subsequent
# boot of this same image.
FORCE=yes "$DIR/03-create-luks-target.sh"
"$DIR/04-configure-kdump.sh"
"$DIR/05-rebuild-kdump.sh"
"$DIR/06-precrash-checks.sh"
echo KDUMP_SETUP_DONE
CONFIRM=yes METHOD=sysrq "$DIR/07-trigger-crash.sh"
EOF
chmod +x "$STAGE/run-all.sh"
find "$STAGE" -name '*.sh' -exec chmod +x {} \;

docker run --rm --platform linux/arm64 --privileged \
  -v "$OUT":/out \
  -v "$STAGE":/stage:ro \
  alpine:3.21 \
  sh -lc '
set -eu
mkdir -p /mnt/root
mount -o loop /out/centos-rootfs-x86.raw /mnt/root
rm -rf /mnt/root/root/kdump-scripts
mkdir -p /mnt/root/root/kdump-scripts
cp -a /stage/. /mnt/root/root/kdump-scripts/
chmod -R +x /mnt/root/root/kdump-scripts
sync
umount /mnt/root
echo KDUMP_SCRIPTS_STAGED_OK
'

echo "Staged $SRC_SCRIPTS into $DISK:/root/kdump-scripts (run-all.sh added)"
