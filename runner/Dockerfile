FROM ubuntu:latest

RUN apt-get update && apt-get install -y \
    # download engines
    curl \
    # PyCall.jl
    python3 libpython3.6 python3-distutils virtualenv \
    # clean-up
    && rm -rf /var/lib/apt/lists/*
