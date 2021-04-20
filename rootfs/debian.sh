#!/bin/bash -uxe

version="buster"
date=$(date +%Y%m%d)

rootfs=$(mktemp --directory --tmpdir="/tmp")

packages=()

# download engines
packages+=(curl ca-certificates)
# essential tools
packages+=(git unzip)
# toolchain
packages+=(build-essential gfortran pkg-config)

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

# replace hardlinks with softlinks (working around JuliaIO/Tar.jl#101)
target_inode=-1
find . -type f -links +1 -printf "%i %p\n" | sort -nk1 | while read inode path; do
    if [[ $target_inode != $inode ]]; then
        target_inode=$inode
        target_path=$path
    else
        ln -sf $target_path $path
    fi
done

tar -cJf "/tmp/debian-$version-$date.tar.xz" .
popd
rm -rf "$rootfs"
