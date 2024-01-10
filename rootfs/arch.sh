#!/bin/bash -uxe

DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

version="devel"
date=$(date +%Y%m%d)

rootfs=$(mktemp --directory --tmpdir="$DIR")

# download base-devel image from https://gitlab.archlinux.org/archlinux/archlinux-docker/-/packages
# pass as argument
archive=$1

sudo tar -xvf $archive -C $rootfs

sudo chown "$(id -u)":"$(id -g)" -R "$rootfs"

# Sandbox.jl is picky about directories in the rootfs, so create them
mkdir $rootfs/proc $rootfs/dev

pushd "$rootfs"
tar -cJf "$DIR/arch-$version-$date.tar.xz" .
popd

rm -rf "$rootfs"
