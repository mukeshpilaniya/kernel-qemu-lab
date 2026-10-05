#!/bin/busybox sh
# First-kernel setup: LUKS2 on /dev/vdb, link the volume key, register it
# in configfs, load the crash kernel with kexec_file_load, then panic.
set -u
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export DM_DISABLE_UDEV=1

fail() {
	echo "LUKS_KDUMP_FAIL $*"
	/bin/busybox dmesg | /bin/busybox tail -n 40
	exit 1
}

if [ ! -b /dev/vdb ]; then
	echo "dev listing:"
	/bin/busybox ls -l /dev
	fail "no /dev/vdb (need a second virtio disk, not a loop file)"
fi
/bin/busybox mkdir -p /sys/kernel/config /dev/mapper /run/cryptsetup /root
/bin/busybox mount -t configfs none /sys/kernel/config || fail "configfs mount"
[ -d /sys/kernel/config/crash_dm_crypt_keys ] || fail "CONFIG_CRASH_DM_CRYPT interface missing"

crash_bytes=$(/bin/busybox cat /sys/kernel/kexec_crash_size)
echo "kexec_crash_size=$crash_bytes"
[ "$crash_bytes" != 0 ] || fail "crashkernel= did not reserve memory"

/bin/busybox printf '%s' 'kdump-test-pass' > /root/kdump-luks.key

/sbin/cryptsetup luksFormat --type luks2 --batch-mode --use-urandom \
	--pbkdf argon2id --pbkdf-memory 32768 --pbkdf-parallel 1 \
	--pbkdf-force-iterations 4 \
	--key-file /root/kdump-luks.key /dev/vdb || fail "luksFormat"

UUID=$(/sbin/cryptsetup luksUUID /dev/vdb) || fail "luksUUID"
echo "LUKS_UUID=$UUID"

/sbin/cryptsetup --batch-mode open --key-file /root/kdump-luks.key \
	--disable-external-tokens \
	--link-vk-to-keyring "@u::%logon:cryptsetup:${UUID}" \
	/dev/vdb kdump_luks || fail "open --link-vk-to-keyring"

/sbin/mke2fs -t ext4 -F /dev/mapper/kdump_luks || fail "mke2fs"
/bin/busybox sync

/bin/busybox mkdir -p "/sys/kernel/config/crash_dm_crypt_keys/${UUID}" || fail "configfs mkdir"
/bin/busybox printf '%s\n' "cryptsetup:${UUID}" \
	> "/sys/kernel/config/crash_dm_crypt_keys/${UUID}/description"
echo "configfs_count=$(/bin/busybox cat /sys/kernel/config/crash_dm_crypt_keys/count)"
if [ -x /usr/bin/keyctl ]; then
	/usr/bin/keyctl show @u || true
fi

# -s is kexec_file_load. That is the path that copies logon keys.
/usr/bin/kexec -p -s /boot/bzImage \
	--initrd=/boot/kdump.cpio \
	--append="console=ttyS0 nokaslr irqpoll nr_cpus=1 reset_devices rdinit=/init" \
	|| fail "kexec -p -s"

echo 1 > /proc/sys/kernel/sysrq
/bin/busybox sync
echo KEXEC_PANIC_TRIGGER
echo c > /proc/sysrq-trigger
fail "sysrq c did not panic"
