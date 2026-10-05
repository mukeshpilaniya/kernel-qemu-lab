#!/usr/bin/env bash
# Open the vmcore extracted by verify-vmcore-centos-arm64.sh with crash(8),
# against the exact vmlinux that produced it. Companion to
# qemu/centos-x86/luks/verify-with-crash-centos-x86.sh -- turns "a vmcore
# file exists" into "the dump is actually analyzable".
#
# Needs the crash-tool:fedora42-arm64 image (qemu/crash-tool/, built once
# via ./qemu/crash-tool/build.sh) -- native arm64, no emulation, unlike the
# amd64-emulated crash-tool:fedora42-x86 pull this host also needs for the
# x86 side of this project.
#
#   ./qemu/centos-arm64/luks/verify-with-crash-centos-arm64.sh
#   ./qemu/centos-arm64/luks/verify-with-crash-centos-arm64.sh sys bt log
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/build-out/centos-arm64"
VMLINUX="${VMLINUX:-$OUT/vmlinux}"
VMCORE="${VMCORE:-$OUT/vmcore-arm64.extracted}"
IMAGE="${IMAGE:-crash-tool:fedora42-arm64}"

if [[ ! -f "$VMLINUX" ]]; then
	echo "Missing $VMLINUX -- run ./qemu/centos-arm64/build-centos-arm64-kernel.sh first." >&2
	exit 1
fi
if [[ ! -f "$VMCORE" ]]; then
	echo "Missing $VMCORE." >&2
	echo "Run ./qemu/centos-arm64/luks/luks-kdump-centos-arm64-test.py then" >&2
	echo "./qemu/centos-arm64/luks/verify-vmcore-centos-arm64.sh first -- it only" >&2
	echo "writes this file if a vmcore was actually found on the LUKS target." >&2
	exit 1
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "Missing docker image $IMAGE." >&2
	echo "Build it once with: docker build --platform linux/arm64 -t crash-tool:fedora42-arm64 ./qemu/crash-tool" >&2
	exit 1
fi

CMDS=("$@")
if [[ ${#CMDS[@]} -eq 0 ]]; then
	CMDS=(sys bt log)
fi
CRASH_SCRIPT="$(printf '%s\n' "${CMDS[@]}")
quit"

echo "Running crash against $VMLINUX / $VMCORE"
printf '%s\n' "$CRASH_SCRIPT" | docker run --rm -i --platform linux/arm64 \
	-v "$OUT":/out \
	"$IMAGE" \
	"/out/$(basename "$VMLINUX")" "/out/$(basename "$VMCORE")"
