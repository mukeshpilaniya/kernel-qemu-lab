#!/usr/bin/env bash
# Open the vmcore extracted by verify-vmcore-centos-x86.sh with crash(8),
# against the exact vmlinux that produced it. This is the step that turns
# "a vmcore file exists" into "the dump is actually analyzable" -- same
# bar qemu-x86.md Section 12 applies to the vanilla-x86 vmcore.
#
# Needs the crash-tool:fedora42-x86 image (qemu/crash-tool/, built once via
# ./qemu/crash-tool/build.sh) rather than CentOS Stream 10's own packaged
# `crash` -- running crash from inside the guest would require booting it
# again just to do analysis, when the vmlinux/vmcore pair this script
# needs already sit on the host after the LUKS test run.
#
#   ./qemu/centos-x86/luks/verify-with-crash-centos-x86.sh
#   ./qemu/centos-x86/luks/verify-with-crash-centos-x86.sh sys bt log
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/build-out/centos-x86"
VMLINUX="${VMLINUX:-$OUT/vmlinux}"
VMCORE="${VMCORE:-$OUT/vmcore-x86.extracted}"
IMAGE="${IMAGE:-crash-tool:fedora42-x86}"

if [[ ! -f "$VMLINUX" ]]; then
	echo "Missing $VMLINUX -- run ./qemu/centos-x86/build-centos-x86-kernel.sh first." >&2
	exit 1
fi
if [[ ! -f "$VMCORE" ]]; then
	echo "Missing $VMCORE." >&2
	echo "Run ./qemu/centos-x86/luks/luks-kdump-centos-x86-test.py then" >&2
	echo "./qemu/centos-x86/luks/verify-vmcore-centos-x86.sh first -- it only" >&2
	echo "writes this file if a vmcore was actually found on the LUKS target." >&2
	exit 1
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "Missing docker image $IMAGE." >&2
	echo "Build it once with: ./qemu/crash-tool/build.sh" >&2
	exit 1
fi

CMDS=("$@")
if [[ ${#CMDS[@]} -eq 0 ]]; then
	CMDS=(sys bt log)
fi
CRASH_SCRIPT="$(printf '%s\n' "${CMDS[@]}")
quit"

echo "Running crash against $VMLINUX / $VMCORE"
printf '%s\n' "$CRASH_SCRIPT" | docker run --rm -i --platform linux/amd64 \
	-v "$OUT":/out \
	"$IMAGE" \
	"/out/$(basename "$VMLINUX")" "/out/$(basename "$VMCORE")"
