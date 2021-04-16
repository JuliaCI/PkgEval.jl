#!/bin/bash -uxe

version="buster"
date=$(date +%Y%m%d)

rootfs=$(mktemp --directory --tmpdir="/tmp")

sudo debootstrap --variant=minbase --include=ssh,curl,libicu63,git,xz-utils,bzip2,unzip,p7zip,zstd,expect,locales,libgomp1 $version "$rootfs"

# Set up the one true locale
echo "en_US.UTF-8 UTF-8" | sudo tee "$rootfs"/etc/locale.gen
sudo chroot "$rootfs" locale-gen

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
