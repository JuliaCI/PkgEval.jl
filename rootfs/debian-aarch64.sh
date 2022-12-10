#!/bin/bash -uxe

DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

version="bullseye"
date=$(date +%Y%m%d)
arch="aarch64"

rootfs=$(mktemp --directory --tmpdir="$DIR")

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
                 --arch=arm64 \
                 --foreign \
                 $version "$rootfs"
sudo cp /usr/bin/qemu-aarch64-static "$rootfs"/usr/bin
sudo chroot "$rootfs" /debootstrap/debootstrap --second-stage

# Clean some files
sudo chroot "$rootfs" apt-get clean
sudo rm -rf "$rootfs"/var/lib/apt/lists/*
sudo rm "$rootfs"/usr/bin/qemu-aarch64-static

# Remove special `dev` files
sudo rm -rf "$rootfs"/dev/*

# Remove `_apt` user so that `apt` doesn't try to `setgroups()`
sudo sed '/_apt:/d' -i "$rootfs"/etc/passwd

sudo chown "$(id -u)":"$(id -g)" -R "$rootfs"

pushd "$rootfs"
tar -cJf "$DIR/debian_$version-$arch-$date.tar.xz" .
popd

rm -rf "$rootfs"
