#!/bin/bash
# 06-precrash-checks.sh
#
# Description:
#   Final first-kernel checks before a panic. Confirms the LUKS mapping
#   is open, kdump is loaded, crypttab has link-volume-key, kdump.conf
#   points at the LUKS filesystem, and SysRq crash is enabled.
#
#   Does not trigger a panic.
#
# When to run:
#   After 05-rebuild-kdump.sh. Do not run 07-trigger-crash.sh unless this
#   script exits 0.
#
# Usage:
#   ./06-precrash-checks.sh
#
# Notes:
#   Capture serial console (this guest uses console=ttyS0,115200) before
#   the crash. configfs count may be 0; reuse=1 is the reserved-memory check.

set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
require_root
load_setup_env

fail=0
pass() { info "PASS  $1"; }
fail_item() { warn "FAIL  $1"; fail=1; }

echo "=== kernel ==="
grep CONFIG_CRASH_DM_CRYPT /boot/config-"$(uname -r)" || fail_item "CONFIG_CRASH_DM_CRYPT"

echo "=== cryptsetup status ==="
if cryptsetup status "$KDUMP_MAPPER"; then
	pass "$KDUMP_MAPPER is active"
else
	fail_item "$KDUMP_MAPPER not active"
fi

echo "=== configfs ==="
if [[ -d $LUKS_CONFIGFS ]]; then
	echo "count=$(cat "$LUKS_CONFIGFS/count")"
	if echo true > "$LUKS_CONFIGFS/reuse" 2>/dev/null; then
		echo "reuse=$(cat "$LUKS_CONFIGFS/reuse")"
		pass "keys present in crash-reserved memory"
	else
		fail_item "could not set $LUKS_CONFIGFS/reuse (keys not saved?)"
	fi
else
	fail_item "configfs missing"
fi

echo "=== crypttab ==="
if grep -q 'link-volume-key=' "$CRYPTTAB"; then
	cat "$CRYPTTAB"
	pass "link-volume-key is set"
else
	cat "$CRYPTTAB" 2>/dev/null || true
	fail_item "crypttab missing link-volume-key"
fi

echo "=== kdump.conf ==="
grep -vE '^[ \t]*(#|$)' "$KDUMP_CONF"
grep -qE '^xfs[[:space:]]' "$KDUMP_CONF" || fail_item "kdump.conf has no xfs dump target"

echo "=== kdump ==="
if [[ $(cat /sys/kernel/kexec_crash_loaded) == 1 ]]; then
	pass "crash kernel loaded"
else
	fail_item "kexec_crash_loaded != 1"
fi
kdumpctl status || fail_item "kdumpctl status"

echo "=== sysrq ==="
echo 1 > /proc/sys/kernel/sysrq
echo "kernel.sysrq=$(cat /proc/sys/kernel/sysrq)"
[[ $(cat /proc/sys/kernel/sysrq) == 1 ]] && pass "SysRq enabled" || fail_item "failed to enable SysRq"

dmesg | grep -iE 'kdump|dm.crypt|dmcrypt' | tail -15 || true

if [[ $fail -ne 0 ]]; then
	die "Pre-crash checks failed. Do not panic the system."
fi
info "Pre-crash checks passed. Attach serial console, then run 07-trigger-crash.sh"
