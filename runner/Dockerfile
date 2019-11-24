FROM ubuntu:latest

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    # download engines
    curl \
    # essential tools
    git unzip \
    # toolchain
    build-essential gfortran \
    # PyCall.jl
    python3 libpython3.6 python3-distutils virtualenv \
    # TimeZones.jl
    tzdata \
    # FFMPEG.jl
    ffmpeg \
    # GZip.jl
    zlib1g-dev \
    # clean-up
    && rm -rf /var/lib/apt/lists/*
