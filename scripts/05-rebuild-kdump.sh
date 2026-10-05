#!/bin/bash
# 05-rebuild-kdump.sh
#
# Description:
#   Rebuilds the kdump initramfs (so it contains cryptsetup and dm-crypt)
#   and reloads the crash kernel with kexec_file_load. kdumpctl copies
#   registered logon keys into crash-reserved memory during load, then
#   removes the configfs key directories on exit. A later count of 0 is
#   therefore expected; use the reuse attribute to confirm keys were saved.
#
# When to run:
#   After 04-configure-kdump.sh.
#
# Usage:
#   ./05-rebuild-kdump.sh

set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
require_root
load_setup_env

info "Rebuilding kdump initramfs"
kdumpctl rebuild
info "Reloading kdump"
systemctl restart kdump
kdumpctl status || true
kdumpctl showmem || true
kdumpctl estimate || true

echo
echo "kexec_crash_loaded=$(cat /sys/kernel/kexec_crash_loaded)"
echo "configfs count=$(cat "$LUKS_CONFIGFS/count" 2>/dev/null || echo n/a)"
echo "(count 0 after kdumpctl exits is expected; keys should already be in reserved memory)"

if echo true > "$LUKS_CONFIGFS/reuse" 2>/tmp/kdump-reuse.err; then
	info "reuse=1 — dm-crypt keys are saved in crash-reserved memory"
	cat "$LUKS_CONFIGFS/reuse"
else
	warn "reuse write failed — keys may not be in reserved memory"
	cat /tmp/kdump-reuse.err || true
fi

img=$(kdump_initramfs)
info "Checking $img for cryptsetup / dm-crypt"
lsinitrd "$img" | grep -iE 'cryptsetup|dm-crypt|dm_crypt|kexec-crypt' | head -30 || warn "crypto bits missing from initramfs"

journalctl -u kdump --no-pager -n 20
info "Rebuild/reload finished"
