#!/bin/bash
# 08-postcrash-validate.sh
#
# Description:
#   After the system returns to the first kernel, unlocks the dump
#   target if needed and looks for vmcore on the LUKS filesystem and in
#   /var/crash. Reloads kdump if the dump device is available.
#
#   A dump that only appears under unencrypted /var/crash does not count
#   as CONFIG_CRASH_DM_CRYPT coverage.
#
# When to run:
#   After reboot from 07-trigger-crash.sh.
#
# Usage:
#   ./08-postcrash-validate.sh
#
# Optional:
#   If kernel-debuginfo is installed, opens vmcore with crash(8).

set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
require_root
load_setup_env

echo "=== boot ==="
uptime
who -b || true

echo "=== kdump test status ==="
kdumpctl status || true
[[ -f /var/lib/kdump/vmcore-creation.status ]] && cat /var/lib/kdump/vmcore-creation.status

echo "=== attach dump target if needed ==="
if [[ ! -b /dev/mapper/$KDUMP_MAPPER ]]; then
	if [[ -n ${KDUMP_LUKS_DEV:-} && -b $KDUMP_LUKS_DEV && -f $KDUMP_KEYFILE ]]; then
		cryptsetup open --key-file "$KDUMP_KEYFILE" "$KDUMP_LUKS_DEV" "$KDUMP_MAPPER" || true
	fi
fi
mkdir -p "$KDUMP_MNT"
if [[ -b /dev/mapper/$KDUMP_MAPPER ]] && ! mountpoint -q "$KDUMP_MNT"; then
	mount "/dev/mapper/$KDUMP_MAPPER" "$KDUMP_MNT" || true
fi

echo "=== dump artifacts ==="
lsblk -o NAME,UUID,FSTYPE,SIZE,MOUNTPOINT
echo "--- $KDUMP_MNT ---"
find "$KDUMP_MNT" -maxdepth 4 -type f -ls 2>/dev/null || true
ls -la "$KDUMP_MNT" "$KDUMP_MNT"/*/ 2>/dev/null || true
echo "--- /var/crash ---"
find /var/crash -maxdepth 4 -type f -ls 2>/dev/null || true

vmcore=$(find "$KDUMP_MNT" -name vmcore -type f 2>/dev/null | head -1 || true)
if [[ -n $vmcore && -s $vmcore ]]; then
	info "PASS  found $vmcore ($(stat -c %s "$vmcore") bytes)"
	vmlinux="/usr/lib/debug/lib/modules/$(uname -r)/vmlinux"
	if command -v crash >/dev/null && [[ -f $vmlinux ]]; then
		info "Opening with crash (quit immediately)"
		crash -s "$vmlinux" "$vmcore" <<'CRASH' || warn "crash failed to open vmcore"
quit
CRASH
	else
		warn "crash tool or vmlinux debuginfo not available; skip analysis"
	fi
else
	warn "FAIL  no vmcore on $KDUMP_MNT"
	if find /var/crash -name vmcore -type f 2>/dev/null | grep -q .; then
		warn "vmcore exists on unencrypted /var/crash — that is not LUKS dump coverage"
	fi
fi

echo "=== reload kdump ==="
if cryptsetup status "$KDUMP_MAPPER" >/dev/null 2>&1; then
	if kdumpctl restart; then
		info "kdump reloaded after reboot"
		echo "kexec_crash_loaded=$(cat /sys/kernel/kexec_crash_loaded)"
	else
		warn "kdumpctl restart failed (dump target may still be invalid at boot)"
	fi
else
	warn "LUKS mapping not available; skip kdump reload"
fi
