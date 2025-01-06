#!/bin/bash -uxe

version="41"
date=$(date +%Y%m%d)

cat > "fedora.conf" << EOF
[Distribution]
Distribution=fedora
Release=$version

[Output]
Format=tar
CompressOutput=zstd
CompressLevel=19

[Content]
Packages=
    curl
    ca-certificates
    git
    unzip
    gcc
    gcc-c++
    make
    glibc-devel
    autoconf
    automake
    cmake
    libtool
    pkgconfig
EOF
trap "rm fedora.conf" EXIT

mkosi --include fedora.conf --architecture x86-64
mv image.tar.zst "fedora-$version-x86_64-$date.tar.zst"
rm image

mkosi --include fedora.conf --architecture arm64
mv image.tar.zst "fedora-$version-aarch64-$date.tar.zst"
rm image
