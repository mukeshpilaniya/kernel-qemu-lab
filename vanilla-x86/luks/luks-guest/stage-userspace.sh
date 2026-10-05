#!/bin/sh
# Runs inside linux/amd64 Alpine. Stages a rootfs tree and a crash initrd
# that contain busybox plus cryptsetup 2.7 (dynamic musl) and its libraries.
set -eu
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

apk add --no-cache busybox-static cryptsetup e2fsprogs keyutils cpio
cryptsetup --version
cryptsetup --help | grep -q link-vk-to-keyring
cryptsetup --help | grep -q volume-key-keyring

bb=/bin/busybox.static
for applet in sh mount umount mkdir cat echo dd sync poweroff dmesg grep sleep \
	ln rm cp wc cmp head tail tr ls; do
	"$bb" --list | grep -qx "$applet" || {
		echo "busybox missing applet $applet" >&2
		exit 1
	}
done

stage=/out/luks-stage
rm -rf "$stage"
mkdir -p "$stage/rootfs" "$stage/initrd"

copy_bin() {
	destroot=$1
	src=$2
	name=$3
	mkdir -p "$destroot/sbin" "$destroot/usr/bin" "$destroot/lib" "$destroot/usr/lib"
	cp -L "$src" "$destroot/sbin/$name"
	chmod 0755 "$destroot/sbin/$name"
	ldd "$src" | awk '{
		for (i = 1; i <= NF; i++) if ($i ~ /^\//) print $i
	}' | while read -r lib; do
		[ -e "$lib" ] || continue
		mkdir -p "$destroot$(dirname "$lib")"
		cp -L "$lib" "$destroot$lib"
	done
}

install_busybox() {
	destroot=$1
	mkdir -p "$destroot/bin" "$destroot/sbin" "$destroot/proc" "$destroot/sys" \
		"$destroot/dev" "$destroot/tmp" "$destroot/root" "$destroot/mnt" \
		"$destroot/boot" "$destroot/usr/bin"
	cp "$bb" "$destroot/bin/busybox"
	chmod 0755 "$destroot/bin/busybox"
	for applet in sh ash mount umount mkdir ls cat echo ln rm cp mv sleep \
		uname dmesg reboot poweroff dd sync grep wc cmp head tail tr; do
		ln -sf busybox "$destroot/bin/$applet"
	done
}

install_busybox "$stage/rootfs"
install_busybox "$stage/initrd"

cryptsetup_bin=$(command -v cryptsetup)
mke2fs_bin=$(command -v mke2fs)
keyctl_bin=$(command -v keyctl || true)
echo "cryptsetup=$cryptsetup_bin"
echo "mke2fs=$mke2fs_bin"

copy_bin "$stage/rootfs" "$cryptsetup_bin" cryptsetup
copy_bin "$stage/initrd" "$cryptsetup_bin" cryptsetup
copy_bin "$stage/rootfs" "$mke2fs_bin" mke2fs
if [ -n "$keyctl_bin" ]; then
	cp -L "$keyctl_bin" "$stage/rootfs/usr/bin/keyctl"
	chmod 0755 "$stage/rootfs/usr/bin/keyctl"
	ldd "$keyctl_bin" | awk '{
		for (i = 1; i <= NF; i++) if ($i ~ /^\//) print $i
	}' | while read -r lib; do
		[ -e "$lib" ] || continue
		mkdir -p "$stage/rootfs$(dirname "$lib")"
		cp -L "$lib" "$stage/rootfs$lib"
	done
fi

# Token plugins are unused. Copy them if present so dlopen does not fail closed.
if [ -d /usr/lib/cryptsetup ]; then
	mkdir -p "$stage/rootfs/usr/lib/cryptsetup" "$stage/initrd/usr/lib/cryptsetup"
	cp -a /usr/lib/cryptsetup/. "$stage/rootfs/usr/lib/cryptsetup/" || true
	cp -a /usr/lib/cryptsetup/. "$stage/initrd/usr/lib/cryptsetup/" || true
fi

cp /guest/init "$stage/rootfs/sbin/init"
cp /guest/init "$stage/rootfs/init"
cp /guest/luks-kdump-test.sh "$stage/rootfs/root/luks-kdump-test.sh"
cp /guest/kdump-init "$stage/initrd/init"
chmod 0755 "$stage/rootfs/sbin/init" "$stage/rootfs/init" \
	"$stage/rootfs/root/luks-kdump-test.sh" "$stage/initrd/init"

# Smoke-test the dynamic loader layout inside this container by chroot if possible.
# The host kernel is arm64, so we cannot exec the x86 cryptsetup here.

(cd "$stage/initrd" && find . -print | cpio -o -H newc > "$stage/kdump.cpio")
ls -lh "$stage/kdump.cpio"
echo LUKS_USERSPACE_STAGED
