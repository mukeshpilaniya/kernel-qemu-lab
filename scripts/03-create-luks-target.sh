#!/bin/bash
# 03-create-luks-target.sh
#
# Description:
#   Creates a LUKS2 volume, XFS filesystem, and mount at /mnt/kdump for
#   use as the kdump destination.
#
#   Device selection (first match):
#     1. KDUMP_LUKS_DEV if set (for example /dev/vdb)
#     2. /dev/vdb if that disk exists
#
#   A real block device is required: the crash kernel does not inherit
#   the first kernel's loop-device mappings, so a loop-backed image is
#   never a valid dump target for this feature. If neither of the above
#   resolves to a real block device, this script fails rather than
#   falling back to one.
#
#   Mapper naming: the device-mapper name used to open this volume is
#   *not* a fixed "kdump_luks" -- it is always "luks-<LUKS-UUID>",
#   computed fresh after luksFormat assigns the UUID. This exactly
#   matches the naming convention kdump-utils' own crash-kernel-side
#   dracut module (kexec_check_crypt_targets()/kdump_check_crypt_targets(),
#   in 99kdumpbase/module-setup.sh) independently derives and creates when
#   it unlocks the same device after a panic -- confirmed by reading that
#   module's source: it always names the unlocked device "luks-$_devuuid",
#   with no awareness of whatever name the first kernel used. If this
#   script instead picked an arbitrary fixed name, kdumpctl rebuild's
#   generated --mount argument for the kdump initramfs (built from
#   get_mntpoint_from_target(), which reads the *first* kernel's current
#   mount source via findmnt) would bake in that arbitrary name, and the
#   crash kernel would unlock the device under a different name than the
#   mount unit is waiting for -- the dump would stall forever at
#   "Device luks-<uuid> already exists" with no further progress, since
#   the mount target never appears under the name it actually expects.
#   Matching the naming convention here, on the first-kernel side, is
#   what keeps both sides in agreement without needing to patch
#   kdump-utils itself.
#
# When to run:
#   After packages are installed. This DESTROYS data on the chosen
#   device.
#
# Usage:
#   ./03-create-luks-target.sh
#   KDUMP_LUKS_DEV=/dev/vdb ./03-create-luks-target.sh
#   FORCE=yes ./03-create-luks-target.sh   # allow re-format if a mapping exists
#
# Environment:
#   KDUMP_LUKS_DEV     Block device to encrypt (preferred)
#   KDUMP_KEYFILE      Passphrase file written for non-interactive open
#   FORCE=yes          Re-create even if a previous run's mapping is active

set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
require_root
command -v cryptsetup >/dev/null || die "cryptsetup is not installed; run 02-install-packages.sh"

# Recover the *previous* run's actual mapper name (if any) for the
# already-active guard below -- it is never the static default once a run
# has completed, since KDUMP_MAPPER becomes "luks-<uuid>" at the end of
# this script and gets persisted by save_setup_env.
load_setup_env

choose_device() {
	if [[ -n ${KDUMP_LUKS_DEV:-} ]]; then
		[[ -b $KDUMP_LUKS_DEV ]] || die "KDUMP_LUKS_DEV=$KDUMP_LUKS_DEV is not a block device"
		return
	fi
	if [[ -b /dev/vdb ]]; then
		KDUMP_LUKS_DEV=/dev/vdb
		info "Using /dev/vdb"
		return
	fi
	die "No real block device found. Set KDUMP_LUKS_DEV=<device> or attach /dev/vdb."
}

if cryptsetup status "$KDUMP_MAPPER" >/dev/null 2>&1 && [[ ${FORCE:-} != yes ]]; then
	die "$KDUMP_MAPPER is already active. Unmount/close it or set FORCE=yes."
fi

choose_device
info "Encrypting $KDUMP_LUKS_DEV"

if mountpoint -q "$KDUMP_MNT"; then
	umount "$KDUMP_MNT"
fi
if cryptsetup status "$KDUMP_MAPPER" >/dev/null 2>&1; then
	cryptsetup close "$KDUMP_MAPPER"
fi

install -m 600 /dev/null "$KDUMP_KEYFILE"
printf '%s' 'kdump-test-pass' > "$KDUMP_KEYFILE"

cryptsetup luksFormat --type luks2 --batch-mode --key-file "$KDUMP_KEYFILE" "$KDUMP_LUKS_DEV"
LUKS_UUID=$(cryptsetup luksUUID "$KDUMP_LUKS_DEV")
KEY_DESC="${LUKS_KEY_PREFIX}${LUKS_UUID}"

# Must match kdump-utils' crash-kernel-side naming exactly -- see the
# header comment above. Overrides whatever KDUMP_MAPPER was inherited
# from lib/common.sh's default or a previous run's persisted env file.
KDUMP_MAPPER="luks-${LUKS_UUID}"

cryptsetup open --key-file "$KDUMP_KEYFILE" \
	--link-vk-to-keyring "@u::%logon:${KEY_DESC}" \
	"$KDUMP_LUKS_DEV" "$KDUMP_MAPPER"

mkfs.xfs -f "/dev/mapper/$KDUMP_MAPPER"
mkdir -p "$KDUMP_MNT"
mount "/dev/mapper/$KDUMP_MAPPER" "$KDUMP_MNT"
touch "$KDUMP_MNT/.kdump-write-test" && rm -f "$KDUMP_MNT/.kdump-write-test"
FS_UUID=$(blkid -s UUID -o value "/dev/mapper/$KDUMP_MAPPER")

save_setup_env

echo
cryptsetup luksDump "$KDUMP_LUKS_DEV"
lsblk -o NAME,UUID,FSTYPE,TYPE,SIZE,MOUNTPOINT
info "LUKS_UUID=$LUKS_UUID"
info "FS_UUID=$FS_UUID"
info "KEY_DESC=$KEY_DESC"
info "KDUMP_MAPPER=$KDUMP_MAPPER"
info "Wrote $KDUMP_ENV_FILE"
