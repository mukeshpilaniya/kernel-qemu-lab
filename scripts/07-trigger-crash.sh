#!/bin/bash
# 07-trigger-crash.sh
#
# Description:
#   Triggers a controlled kernel panic so kdump can boot the crash
#   kernel and attempt to save vmcore to the LUKS target.
#
#   THIS REBOOTS THE MACHINE. SSH sessions die. Watch serial console
#   for crash-kernel boot, dmcryptkeys=, passphrase prompts, and dump
#   completion.
#
# When to run:
#   Only after 06-precrash-checks.sh exits 0, with a console attached.
#
# Usage:
#   CONFIRM=yes ./07-trigger-crash.sh
#   CONFIRM=yes METHOD=sysrq ./07-trigger-crash.sh
#
# Environment:
#   CONFIRM=yes   Required. Refuses to run without it.
#   METHOD=test   Default. Uses "kdumpctl test --force" (records a test id).
#   METHOD=sysrq  Uses "echo c > /proc/sysrq-trigger"

set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
require_root

[[ ${CONFIRM:-} == yes ]] || die "Refusing to panic. Re-run as: CONFIRM=yes $0"

METHOD=${METHOD:-test}
echo 1 > /proc/sys/kernel/sysrq
sync

info "Triggering crash via METHOD=$METHOD"
case $METHOD in
test)
	# Unloads/reloads kdump, then panics. After reboot, check
	# kdumpctl status and /var/lib/kdump/vmcore-creation.status
	exec kdumpctl test --force
	;;
sysrq)
	echo c > /proc/sysrq-trigger
	die "SysRq crash did not take effect (kernel.sysrq=$(cat /proc/sys/kernel/sysrq))"
	;;
*)
	die "Unknown METHOD=$METHOD (use test or sysrq)"
	;;
esac
