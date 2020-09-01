FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y gnupg ca-certificates

RUN apt-get update && apt-get install --no-install-recommends -y \
    # container tools
    dumb-init \
    # download engines
    curl \
    # essential tools
    git unzip sudo \
    # toolchain
    build-essential gfortran pkg-config \
    # TimeZones.jl
    tzdata \
    # FFMPEG.jl
    ffmpeg \
    # GZip.jl
    zlib1g-dev \
    # JavaCall.jl
    default-jre-headless \
    # PGFPlotsX.jl, PredictMD.jl
    gnuplot \
    pdf2svg \
    poppler-utils \
    texlive \
    texlive-binaries \
    texlive-latex-base \
    texlive-latex-extra \
    texlive-luatex \
    texlive-pictures \
    # Any package that needs a display (e.g. Gtk.jl)
    xvfb \
    # clean-up
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash --groups sudo pkgeval && \
    echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
WORKDIR /home/pkgeval
USER pkgeval

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
