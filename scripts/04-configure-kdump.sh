#!/bin/bash
# 04-configure-kdump.sh
#
# Description:
#   Points /etc/kdump.conf at the unlocked LUKS filesystem, writes
#   /etc/crypttab, runs kdumpctl setup-crypttab, and links the volume key
#   into a logon keyring using the kdump-utils description:
#     kdump-cryptsetup:vk-<LUKS-UUID>
#
# When to run:
#   After 03-create-luks-target.sh, while its LUKS mapping is open.
#
# Usage:
#   ./04-configure-kdump.sh
#
# Notes:
#   Backs up /etc/kdump.conf and /etc/crypttab with a .bak-before-luks
#   suffix. RHEL 10 uses failure_action rather than default.

set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
require_root
load_setup_env

cryptsetup status "$KDUMP_MAPPER" >/dev/null 2>&1 || die "$KDUMP_MAPPER is not active; run 03-create-luks-target.sh"
KDUMP_LUKS_DEV=$(active_luks_dev)
[[ -b ${KDUMP_LUKS_DEV:-} ]] || die "Could not determine LUKS backing device"
LUKS_UUID=$(cryptsetup luksUUID "$KDUMP_LUKS_DEV")
FS_UUID=$(blkid -s UUID -o value "/dev/mapper/$KDUMP_MAPPER")
KEY_DESC="${LUKS_KEY_PREFIX}${LUKS_UUID}"

info "LUKS_UUID=$LUKS_UUID FS_UUID=$FS_UUID"

cp -a "$KDUMP_CONF" "${KDUMP_CONF}.bak-before-luks"
[[ -f $CRYPTTAB ]] && cp -a "$CRYPTTAB" "${CRYPTTAB}.bak-before-luks"

cat > "$CRYPTTAB" <<EOF
$KDUMP_MAPPER UUID=$LUKS_UUID $KDUMP_KEYFILE luks
EOF

awk '!/^[[:space:]]*(auto_reset_crashkernel|path|core_collector|extra_bins|extra_modules|failure_action|default|xfs|ext[234])[[:space:]]/' \
	"${KDUMP_CONF}.bak-before-luks" > /tmp/kdump.conf.comments
{
	cat /tmp/kdump.conf.comments
	echo
	echo "# --- encrypted dump target (CONFIG_CRASH_DM_CRYPT) ---"
	grep -E '^auto_reset_crashkernel' "${KDUMP_CONF}.bak-before-luks" || echo 'auto_reset_crashkernel yes'
	echo "xfs UUID=$FS_UUID"
	echo "path /"
	# No -l/-p: default (zlib) compression. -l (lzo) produced a dump that
	# a from-source-built crash(8) (kernel/qemu/crash-tool/, see
	# vanilla-x86-readme.md Section 12) could not open: "uncompress failed: no lzo
	# compression support" -- that crash build links zlib/bz2/xz/snappy
	# but not liblzo2. zlib is the one compression format essentially
	# every crash(8) build supports, so it is the safe default here.
	echo "core_collector makedumpfile -c --message-level 7 -d 31"
	echo "extra_bins /usr/sbin/cryptsetup"
	echo "extra_modules dm_mod dm_crypt"
	echo "failure_action reboot"
} > "$KDUMP_CONF"

info "Active kdump.conf:"
grep -vE '^[ \t]*(#|$)' "$KDUMP_CONF"

kdumpctl setup-crypttab
info "crypttab after setup-crypttab:"
cat "$CRYPTTAB"

# Re-open with the kdump-utils key description so prepare_luks can find it.
if mountpoint -q "$KDUMP_MNT"; then
	umount "$KDUMP_MNT"
fi
cryptsetup close "$KDUMP_MAPPER" || true
cryptsetup open --key-file "$KDUMP_KEYFILE" \
	--link-vk-to-keyring "@u::%logon:${KEY_DESC}" \
	"$KDUMP_LUKS_DEV" "$KDUMP_MAPPER"
mount "/dev/mapper/$KDUMP_MAPPER" "$KDUMP_MNT"

save_setup_env
info "Volume key linked as @u::%logon:$KEY_DESC"
keyctl show @u || true
