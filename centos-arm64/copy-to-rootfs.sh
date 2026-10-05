#!/usr/bin/env bash
# Copy files into the CentOS ext4 rootfs from macOS (loop-mount does not work on macOS).
#
# Usage:
#   ./qemu/centos-arm64/copy-to-rootfs.sh build-out/centos-arm64/kexec /usr/bin/kexec
#   ./qemu/centos-arm64/copy-to-rootfs.sh build-out/centos-arm64/Image /boot/Image
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build-out/centos-arm64"
DISK="${DISK:-$OUT/centos-rootfs.raw}"

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <host-file> <path-inside-rootfs>" >&2
  exit 1
fi
SRC_FILE="$1"
DST_PATH="$2"
if [[ ! -f "$SRC_FILE" ]]; then
  echo "Missing file: $SRC_FILE" >&2
  exit 1
fi
if [[ ! -f "$DISK" ]]; then
  echo "Missing disk: $DISK" >&2
  exit 1
fi
if [[ "$DST_PATH" != /* ]]; then
  echo "Destination must be an absolute path in the guest, e.g. /usr/bin/kexec" >&2
  exit 1
fi

HOST_SRC="$(cd "$(dirname "$SRC_FILE")" && pwd)/$(basename "$SRC_FILE")"
BASE="$(basename "$SRC_FILE")"
DST_DIR="$(dirname "$DST_PATH")"

docker run --rm --platform linux/arm64 --privileged \
  -v "$OUT":/out \
  -v "$HOST_SRC":/tmp/srcfile:ro \
  quay.io/centos/centos:stream10 \
  bash -lc "
set -euo pipefail
dnf -y install e2fsprogs >/dev/null
mkdir -p /mnt/root
mount -o loop /out/centos-rootfs.raw /mnt/root
mkdir -p /mnt/root${DST_DIR}
cp -v /tmp/srcfile /mnt/root${DST_PATH}
chmod 0755 /mnt/root${DST_PATH} || true
sync
umount /mnt/root
echo COPIED ${BASE} -> ${DST_PATH}
"
