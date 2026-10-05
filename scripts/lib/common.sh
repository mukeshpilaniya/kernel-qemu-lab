#!/bin/bash
# shared helpers for CONFIG_CRASH_DM_CRYPT / LUKS kdump test scripts
# Source this file; do not run it directly.
#
# These scripts are meant to run as root on the system under test
# (for example kvm-05-guest14), not over SSH.

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	echo "Do not run ${BASH_SOURCE[0]} directly. Source it from another script." >&2
	exit 1
fi

# Bootstrap default only, used for the "already active" guard before any
# run has completed. 03-create-luks-target.sh overrides this to
# "luks-<LUKS-UUID>" once the UUID is known, to match kdump-utils' own
# crash-kernel-side naming convention -- see that script's header comment.
KDUMP_MAPPER="${KDUMP_MAPPER:-kdump_luks}"
KDUMP_MNT="${KDUMP_MNT:-/mnt/kdump}"
KDUMP_KEYFILE="${KDUMP_KEYFILE:-/root/kdump-luks.key}"
KDUMP_ENV_FILE="${KDUMP_ENV_FILE:-/root/kdump-luks-setup.env}"
KDUMP_CONF="${KDUMP_CONF:-/etc/kdump.conf}"
CRYPTTAB="${CRYPTTAB:-/etc/crypttab}"
# kdump-utils registers this prefix, not the kernel-doc "cryptsetup:" name.
LUKS_KEY_PREFIX="${LUKS_KEY_PREFIX:-kdump-cryptsetup:vk-}"
LUKS_CONFIGFS="${LUKS_CONFIGFS:-/sys/kernel/config/crash_dm_crypt_keys}"

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_root() {
	[[ $(id -u) -eq 0 ]] || die "Run as root."
}

load_setup_env() {
	if [[ -f $KDUMP_ENV_FILE ]]; then
		# shellcheck disable=SC1090
		. "$KDUMP_ENV_FILE"
	fi
}

save_setup_env() {
	cat > "$KDUMP_ENV_FILE" <<EOF
KDUMP_LUKS_DEV=${KDUMP_LUKS_DEV:-}
LUKS_UUID=${LUKS_UUID:-}
FS_UUID=${FS_UUID:-}
KEY_DESC=${KEY_DESC:-}
KDUMP_MAPPER=$KDUMP_MAPPER
KDUMP_MNT=$KDUMP_MNT
KDUMP_KEYFILE=$KDUMP_KEYFILE
EOF
	chmod 600 "$KDUMP_ENV_FILE"
}

active_luks_dev() {
	if [[ -n ${KDUMP_LUKS_DEV:-} && -b $KDUMP_LUKS_DEV ]]; then
		printf '%s\n' "$KDUMP_LUKS_DEV"
		return
	fi
	if cryptsetup status "$KDUMP_MAPPER" >/dev/null 2>&1; then
		cryptsetup status "$KDUMP_MAPPER" | awk '/device:/ { print $2; exit }'
		return
	fi
}

kdump_initramfs() {
	printf '/boot/initramfs-%skdump.img\n' "$(uname -r)"
}
