#!/bin/bash
# reclaim-swap-to-vda4.sh
#
# Description:
#   Turns the swap LV into a real GPT partition /dev/vda4 for use as
#   a LUKS kdump target. Swap occupies PEs at the start of /dev/vda3,
#   and LVM cannot pvmove those extents onto the same PV. A temporary
#   PV on /home is used as a landing zone so the tail of vda3 can be
#   freed, the partition shrunk, and vda4 created at the end of the disk.
#
#   Removes swap from fstab and drops resume=/rd.lvm.lv=.../swap from
#   the kernel command line so the next boot does not wait for swap.
#   Tears down the kdump LUKS mapping if it is present.
#
#   THIS DESTROYS SWAP. The OS disk partition table is rewritten.
#
# Usage (as root on the guest):
#   ./reclaim-swap-to-vda4.sh

set -euo pipefail

VG=rhel_kvm-04-guest12
PV=/dev/vda3
DISK=/dev/vda
SWAP_LV=/dev/${VG}/swap
TMP_IMG=/home/pvmove-tmp.img
TMP_IMG_MIB=4096

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }

[[ $(id -u) -eq 0 ]] || die "Run as root."
[[ -b $DISK ]] || die "$DISK not found"

if [[ -b /dev/vda4 ]]; then
	info "/dev/vda4 already exists"
	parted -s "$DISK" unit MiB print free
	lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
	exit 0
fi

[[ -b $PV ]] || die "$PV not found"

extent_kb=$(vgs --noheadings --nosuffix --units k -o vg_extent_size "$VG" | awk '{print int($1)}')
[[ -n $extent_kb && $extent_kb -gt 0 ]] || die "Could not read VG extent size"
swap_pe=963

pv_pe() { pvs --noheadings --nosuffix -o pv_pe_count "$PV" | awk '{print int($1)}'; }
alloc_pe() { pvs --noheadings --nosuffix -o pv_pe_alloc_count "$PV" | awk '{print int($1)}'; }

# Tear down dump target mapping so we can reuse mapper name later.
if mountpoint -q /mnt/kdump; then
	umount /mnt/kdump
	info "Unmounted /mnt/kdump"
fi
if cryptsetup status kdump_luks >/dev/null 2>&1; then
	cryptsetup close kdump_luks
	info "Closed kdump_luks"
fi

if swapon --show --noheadings | grep -q .; then
	swapoff -a
	info "swapoff -a"
fi
if grep -qE '[[:space:]]swap[[:space:]]' /etc/fstab; then
	cp -a /etc/fstab /etc/fstab.bak-before-vda4
	sed -i -E '/[[:space:]]swap[[:space:]]/d' /etc/fstab
	info "Removed swap from fstab"
fi

if grep -q 'rd.lvm.lv=rhel_kvm-04-guest12/swap' /etc/default/grub \
	|| grep -q 'resume=' /etc/default/grub \
	|| grep -q 'rd.lvm.lv=rhel_kvm-04-guest12/swap' /proc/cmdline; then
	info "Removing resume= and swap rd.lvm.lv from kernel command line"
	grubby --update-kernel=ALL --remove-args="resume=UUID=5316ca07-fa00-4bd2-acf0-f5f4caf06c84" || true
	grubby --update-kernel=ALL --remove-args="rd.lvm.lv=rhel_kvm-04-guest12/swap" || true
	sed -i -E 's/ resume=UUID=[^ "]+//' /etc/default/grub
	sed -i -E 's| rd.lvm.lv=rhel_kvm-04-guest12/swap||' /etc/default/grub
fi

if lvs "$SWAP_LV" >/dev/null 2>&1; then
	lvremove -f "$SWAP_LV"
	info "Removed $SWAP_LV"
fi

free_pe=$(($(pv_pe) - $(alloc_pe)))
info "PV $PV pe=$(pv_pe) alloc=$(alloc_pe) free=$free_pe extent=${extent_kb}KiB"
[[ $free_pe -eq $swap_pe ]] || die "Expected $swap_pe free PEs after swap removal, got $free_pe"

src_start=$(($(pv_pe) - swap_pe))
src_end=$(($(pv_pe) - 1))

cleanup_tmp_pv() {
	local tmpdev=$1
	if pvs "$tmpdev" >/dev/null 2>&1; then
		pvmove "$tmpdev" "$PV" || true
		vgreduce "$VG" "$tmpdev" || true
		pvremove -f "$tmpdev" || true
	fi
	losetup -d "$tmpdev" 2>/dev/null || true
	rm -f "$TMP_IMG"
}

info "Creating temporary PV on /home (${TMP_IMG_MIB}MiB) so extents can leave $PV"
dd if=/dev/zero of="$TMP_IMG" bs=1M count="$TMP_IMG_MIB" status=progress
tmpdev=$(losetup -f --show "$TMP_IMG")
[[ -b $tmpdev ]] || die "losetup failed for $TMP_IMG"
pvcreate -f "$tmpdev"
vgextend "$VG" "$tmpdev"
info "Moving $PV:${src_start}-${src_end} -> $tmpdev"
pvmove -i 10 "${PV}:${src_start}-${src_end}" "$tmpdev"

new_pe_count=$(($(pv_pe) - swap_pe))
new_pv_mib=$((1 + new_pe_count * extent_kb / 1024))
info "Shrinking PV to ${new_pe_count} PEs (${new_pv_mib} MiB including 1MiB label)"
pvresize --setphysicalvolumesize "${new_pv_mib}m" "$PV"

part_start_mib=$(parted -s "$DISK" unit MiB print | awk '/^[[:space:]]*3[[:space:]]/ { gsub(/MiB/,"",$2); print int($2); exit }')
[[ -n $part_start_mib ]] || die "Could not read vda3 start"
new_part_end_mib=$((part_start_mib + new_pv_mib))
info "vda3 starts at ${part_start_mib}MiB; resizing end to ${new_part_end_mib}MiB"
parted -s "$DISK" unit MiB resizepart 3 "${new_part_end_mib}"
info "Creating vda4 from ${new_part_end_mib}MiB to 100%"
parted -s "$DISK" unit MiB mkpart kdump_luks "${new_part_end_mib}" 100%
partprobe "$DISK" || true
udevadm settle
sleep 2
[[ -b /dev/vda4 ]] || die "/dev/vda4 did not appear"

info "Moving extents from $tmpdev back onto $PV"
pvmove -i 10 "$tmpdev" "$PV"
vgreduce "$VG" "$tmpdev"
pvremove -f "$tmpdev"
losetup -d "$tmpdev"
rm -f "$TMP_IMG"

wipefs -a /dev/vda4 || true

echo
info "Partition table after conversion:"
parted -s "$DISK" unit MiB print free
pvs
vgs
lvs -o lv_name,lv_size,seg_pe_ranges
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
info "Created /dev/vda4. Next: FORCE=yes KDUMP_LUKS_DEV=/dev/vda4 ./setup-encrypted-kdump.sh"
