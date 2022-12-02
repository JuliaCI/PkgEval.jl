#!/bin/bash -uxe

DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

version="bullseye"
date=$(date +%Y%m%d)

rootfs=$(mktemp --directory --tmpdir="$DIR")

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
tar -cJf "$DIR/xvfb-$version-$date.tar.xz" .
popd

rm -rf "$rootfs"
