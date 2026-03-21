#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script with sudo or as root."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
    build-essential \
    cmake \
    dpkg-dev \
    git \
    meson \
    ninja-build \
    pkg-config \
    libpipewire-0.3-dev \
    libspa-0.2-dev \
    lv2-dev \
    libzix-dev \
    libserd-dev \
    libsord-dev \
    libsratom-dev \
    liblilv-dev \
    libsuil-dev \
    libgtk2.0-dev \
    libmagickwand-dev \
    libx11-dev \
    libpng-dev \
    libvulkan-dev \
    vulkan-utility-libraries-dev
