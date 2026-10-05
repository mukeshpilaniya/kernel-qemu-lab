#!/usr/bin/env bash
# Stage the real encrypt_crash_kernel/scripts/ kdump-utils-based LUKS test
# toolkit into the compiled centos-arm64 rootfs, at /root/kdump-scripts/.
# Identical in spirit to qemu/centos-x86/luks/stage-kdump-scripts-x86.sh --
# the same toolkit, unmodified, works on both arches because kdump-utils'
# userspace side (kdumpctl, 99kdumpbase) is architecture-generic; only the
# kernel's own kexec_file_load implementation (boot-params on x86, a
# device-tree dmcryptkeys property on arm64, see build-out/centos-arm64/
# README.md) differs, and that is below this toolkit's level entirely.
#
#   ./qemu/centos-arm64/luks/stage-kdump-scripts-arm64.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/build-out/centos-arm64"
DISK="${DISK:-$OUT/centos-rootfs.raw}"
SRC_SCRIPTS="$(cd "$ROOT/scripts" && pwd)"

if [[ ! -f "$DISK" ]]; then
  echo "Rootfs disk not found: $DISK" >&2
  echo "Create it first: $ROOT/qemu/centos-arm64/make-centos-rootfs.sh" >&2
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

# See qemu/centos-x86/luks/stage-kdump-scripts-x86.sh for why FORCE=yes and
# METHOD=sysrq are used here -- identical reasoning, arch-independent.
cat > "$STAGE/run-all.sh" <<'EOF'
#!/bin/bash
# Chains 01/03/04/05/06 (setup, non-destructive to destructive), then 07
# (the panic). Run as root at the QEMU serial console.
#   sh /root/kdump-scripts/run-all.sh
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
"$DIR/01-verify-prereqs.sh" || echo "[WARN] 01-verify-prereqs reported gaps; continuing"
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
mount -o loop /out/centos-rootfs.raw /mnt/root
rm -rf /mnt/root/root/kdump-scripts
mkdir -p /mnt/root/root/kdump-scripts
cp -a /stage/. /mnt/root/root/kdump-scripts/
chmod -R +x /mnt/root/root/kdump-scripts
sync
umount /mnt/root
echo KDUMP_SCRIPTS_STAGED_OK
'

echo "Staged $SRC_SCRIPTS into $DISK:/root/kdump-scripts (run-all.sh added)"
