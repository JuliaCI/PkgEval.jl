#!/bin/bash -uxe

version="bookworm"
date=$(date +%Y%m%d)

cat > "mkosi.conf" << EOF
[Distribution]
Distribution=debian
Release=$version

[Output]
Format=tar
CompressOutput=zstd
CompressLevel=19

[Content]
Packages=
    xvfb
EOF
trap "rm mkosi.conf" EXIT

mkosi --architecture=x86-64
mv image.tar.zst "xvfb-$version-x86_64-$date.tar.zst"
rm image

mkosi --architecture=arm64
mv image.tar.zst "xvfb-$version-aarch64-$date.tar.zst"
rm image
