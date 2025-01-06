#!/bin/bash -uxe

version="bookworm"
date=$(date +%Y%m%d)

cat > "debian.conf" << EOF
[Distribution]
Distribution=debian
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
    g++
    make
    libc6-dev
    autoconf
    automake
    cmake
    libtool
    pkg-config
EOF
trap "rm debian.conf" EXIT

mkosi --include debian.conf --architecture x86-64
mv image.tar.zst "debian-$version-x86_64-$date.tar.zst"
rm image

mkosi --include debian.conf --architecture arm64
mv image.tar.zst "debian-$version-aarch64-$date.tar.zst"
rm image
