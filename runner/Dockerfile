FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install --no-install-recommends -y \
    # container tools
    dumb-init \
    # download engines
    curl ca-certificates \
    # essential tools
    git unzip sudo \
    # toolchain
    build-essential gfortran pkg-config \
    # Any package that needs a display (e.g. Gtk.jl)
    xvfb \
    # clean-up
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash --groups sudo pkgeval && \
    echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

RUN mkdir /storage /cache && \
    chown pkgeval /storage /cache

WORKDIR /home/pkgeval
USER pkgeval

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
