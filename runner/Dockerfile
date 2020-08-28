FROM ubuntu:18.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y gnupg ca-certificates

RUN printf "deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu1804/x86_64 /" > /etc/apt/sources.list.d/backports.list
RUN APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=DontWarn \
    apt-key adv --fetch-keys https://developer.download.nvidia.com/compute/cuda/repos/ubuntu1804/x86_64/7fa2af80.pub

RUN apt-get update && apt-get install -y \
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
    # CUDA packages
    cuda-runtime-10-2 cuda-toolkit-10-2 \
    # clean-up
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash --groups sudo pkgeval && \
    echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
WORKDIR /home/pkgeval
USER pkgeval

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
