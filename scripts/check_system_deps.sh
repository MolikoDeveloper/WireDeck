#!/bin/sh
set -eu

missing=0

check_bin() {
    if command -v "$1" >/dev/null 2>&1; then
        echo "[ok] binary: $1"
    else
        echo "[missing] binary: $1"
        missing=1
    fi
}

check_pkg() {
    if pkg-config --exists "$1"; then
        echo "[ok] pkg-config: $1"
    else
        echo "[missing] pkg-config: $1"
        missing=1
    fi
}

check_bin git
check_bin zig
check_bin pkg-config
check_bin cmake
check_bin meson
check_bin ninja

if command -v pkg-config >/dev/null 2>&1; then
    check_pkg sdl3
    check_pkg libpipewire-0.3
    check_pkg libspa-0.2
    check_pkg vulkan
    # Optional LV2/Lilv plugin stack.
    check_pkg lv2
    check_pkg zix-0
    check_pkg serd-0
    check_pkg sord-0
    check_pkg sratom-0
    check_pkg lilv-0
    check_pkg suil-0
    check_pkg gtk+-2.0
    check_pkg gtk+-x11-2.0
    check_pkg x11
fi

exit "$missing"
