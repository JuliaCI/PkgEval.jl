#!/bin/bash -uxe

version="devel"
date=$(date +%Y%m%d)

rootfs=$(mktemp --directory --tmpdir="/tmp")

# download from https://gitlab.archlinux.org/archlinux/archlinux-docker/-/packages
# pass as argumnent
archive=$1

sudo tar -xvf $archive -C $rootfs

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

# Sandbox.jl is picky about directories in the rootfs, so create them
mkdir proc dev

tar -cJf "/tmp/arch-$version-$date.tar.xz" .
popd
rm -rf "$rootfs"
