#!/bin/bash -uxe

version="bullseye"
date=$(date +%Y%m%d)

rootfs=$(mktemp --directory --tmpdir="/tmp")

packages=()

# download engines
packages+=(curl ca-certificates)
# essential tools
packages+=(git unzip)
# toolchain
packages+=(build-essential libatomic1 python3 gfortran perl wget m4 cmake pkg-config curl patchelf)

function join_by { local IFS="$1"; shift; echo "$*"; }
package_list=$(join_by , ${packages[@]})

sudo debootstrap --variant=minbase \
                 --include=$package_list \
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

tar -cJf "/tmp/debian-$version-$date.tar.xz" .
popd
rm -rf "$rootfs"
