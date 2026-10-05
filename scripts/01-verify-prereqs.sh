#!/bin/bash
# 01-verify-prereqs.sh
#
# Description:
#   Read-only check that the running kernel and userspace can support
#   kdump to a LUKS target with CONFIG_CRASH_DM_CRYPT. Does not format
#   disks, change kdump.conf, or panic the system.
#
# When to run:
#   First, on the system under test, before any setup.
#
# Usage:
#   ./01-verify-prereqs.sh
#
# Exit status:
#   0 if required kernel options and kdump service look usable
#   1 if a required check failed

set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
require_root

fail=0
check() {
	local desc=$1
	shift
	if "$@"; then
		info "PASS  $desc"
	else
		warn "FAIL  $desc"
		fail=1
	fi
}

echo "=== host ==="
hostname
uname -a
[[ -r /etc/os-release ]] && . /etc/os-release && echo "OS=$PRETTY_NAME"

echo
echo "=== cmdline / memory ==="
cat /proc/cmdline
echo
free -h
echo "kexec_crash_loaded=$(cat /sys/kernel/kexec_crash_loaded 2>/dev/null || echo missing)"
echo "kexec_crash_size=$(cat /sys/kernel/kexec_crash_size 2>/dev/null || echo missing)"

echo
echo "=== kernel config ==="
CFG="/boot/config-$(uname -r)"
[[ -r $CFG ]] || die "Cannot read $CFG"

for opt in CONFIG_CRASH_DM_CRYPT CONFIG_CRASH_DUMP CONFIG_KEXEC_FILE \
	CONFIG_DM_CRYPT CONFIG_CONFIGFS_FS CONFIG_KEYS CONFIG_CRASH_HOTPLUG; do
	line=$(grep -E "^$opt=|^# $opt is not set" "$CFG" || true)
	echo "$line"
	case $opt in
	CONFIG_CRASH_DM_CRYPT | CONFIG_CRASH_DUMP | CONFIG_KEXEC_FILE | CONFIG_KEYS | CONFIG_CONFIGFS_FS)
		check "$opt enabled" grep -q "^${opt}=" <<<"$line"
		;;
	esac
done

echo
echo "=== packages ==="
for pkg in kexec-tools kdump-utils cryptsetup systemd dracut makedumpfile; do
	if rpm -q "$pkg" >/dev/null 2>&1; then
		info "installed  $(rpm -q "$pkg")"
	else
		warn "missing    $pkg"
		[[ $pkg == cryptsetup ]] && fail=1
	fi
done
rpm -q crash >/dev/null 2>&1 && info "installed  $(rpm -q crash)" || warn "optional   crash not installed"
command -v cryptsetup >/dev/null && cryptsetup --version || true

echo
echo "=== kdump service ==="
systemctl is-enabled kdump 2>/dev/null || true
systemctl is-active kdump 2>/dev/null || true
if command -v kdumpctl >/dev/null; then
	kdumpctl status || true
	kdumpctl showmem || true
	kdumpctl estimate || true
fi

echo
echo "=== kdump.conf (active lines) ==="
if [[ -f $KDUMP_CONF ]]; then
	grep -vE '^[ \t]*(#|$)' "$KDUMP_CONF" || true
else
	warn "no $KDUMP_CONF"
	fail=1
fi

echo
echo "=== crypttab / LUKS ==="
if [[ -f $CRYPTTAB ]]; then
	cat "$CRYPTTAB"
else
	warn "no $CRYPTTAB"
fi
lsblk -o NAME,UUID,FSTYPE,TYPE,SIZE,MOUNTPOINT

echo
echo "=== configfs $LUKS_CONFIGFS ==="
if [[ -d $LUKS_CONFIGFS ]]; then
	info "configfs interface present"
	find "$LUKS_CONFIGFS" -ls
	echo "count=$(cat "$LUKS_CONFIGFS/count" 2>/dev/null || echo n/a)"
	echo "reuse=$(cat "$LUKS_CONFIGFS/reuse" 2>/dev/null || echo n/a)"
else
	warn "configfs interface missing"
	fail=1
fi

echo
echo "=== kdump initramfs crypto bits ==="
img=$(kdump_initramfs)
if [[ -f $img ]]; then
	lsinitrd "$img" | grep -iE 'cryptsetup|dm-crypt|dm_crypt|crypttab|kexec-crypt' | head -40 || warn "no crypto hits in $img"
else
	warn "no kdump initramfs $img"
fi

echo
echo "=== sysrq ==="
echo "kernel.sysrq=$(cat /proc/sys/kernel/sysrq)"

if [[ $fail -eq 0 ]]; then
	info "Prerequisite check finished: required kernel/kdump pieces are present."
	info "A LUKS dump target may still be missing; run 03-create-luks-target.sh next."
else
	die "Prerequisite check failed."
fi
