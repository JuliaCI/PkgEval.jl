#!/bin/bash -uxe

DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

version="bookworm"
arch=$(uname -m)
date=$(date +%Y%m%d)

rootfs=$(mktemp --directory --tmpdir="$DIR")
trap "sudo rm -rf $rootfs" EXIT

sudo debootstrap --variant=minbase \
                 --include=xvfb \
                 $version "$rootfs"

# Clean some files
sudo chroot "$rootfs" apt-get clean
sudo rm -rf "$rootfs"/var/lib/apt/lists/*

# Remove special `dev` files
sudo rm -rf "$rootfs"/dev/*

# Remove `_apt` user so that `apt` doesn't try to `setgroups()`
sudo sed '/_apt:/d' -i "$rootfs"/etc/passwd

sudo chown "$(id -u)":"$(id -g)" -R "$rootfs"

pushd "$rootfs"
tar -cf - . | zstd -T0 -19 > "$DIR/xvfb-$version-$arch-$date.tar.zst"
popd

rm -rf "$rootfs"
