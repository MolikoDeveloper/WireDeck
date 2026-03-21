#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
VENDOR_DIR="$ROOT_DIR/vendor"
BUILD_ROOT="${LV2_BUILD_ROOT:-$ROOT_DIR/.cache/lv2-build}"
PREFIX_DIR="${LILV_PREFIX:-$ROOT_DIR/.cache/lilv-prefix}"

usage() {
    cat <<'EOF'
Usage:
  ./scripts/fetch_vendor_deps.sh [clean]

Fetches and builds vendored dependencies.

Options:
  clean   Remove build caches (LV2/Lilv build output).
EOF
}

require_bin() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "[wiredeck] missing required binary: $1" >&2
        exit 1
    fi
}

prepare_env() {
    mkdir -p "$BUILD_ROOT" "$PREFIX_DIR" "$VENDOR_DIR"
    export PKG_CONFIG_PATH="$PREFIX_DIR/lib/pkgconfig:$PREFIX_DIR/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
    export LD_LIBRARY_PATH="$PREFIX_DIR/lib:$PREFIX_DIR/lib64:${LD_LIBRARY_PATH:-}"
    export LIBRARY_PATH="$PREFIX_DIR/lib:$PREFIX_DIR/lib64:${LIBRARY_PATH:-}"
    export C_INCLUDE_PATH="$PREFIX_DIR/include:${C_INCLUDE_PATH:-}"
}

clone_or_update() {
    name="$1"
    repo="$2"
    ref="$3"
    dir="$VENDOR_DIR/$name"

    if [ ! -d "$dir/.git" ]; then
        echo "[wiredeck] cloning $name"
        git clone --depth 1 --branch "$ref" "$repo" "$dir"
        return
    fi

    echo "[wiredeck] updating $name"
    git -C "$dir" fetch --depth 1 origin "$ref"
    git -C "$dir" checkout --detach FETCH_HEAD >/dev/null 2>&1 || git -C "$dir" checkout "$ref"
}

sync_submodules_if_present() {
    name="$1"
    dir="$VENDOR_DIR/$name"
    if [ -d "$dir/.git" ] && [ -f "$dir/.gitmodules" ]; then
        echo "[wiredeck] syncing $name submodules"
        git -C "$dir" submodule update --init --recursive
    fi
}

ensure_rnnoise_model() {
    dir="$VENDOR_DIR/rnnoise"
    if [ ! -d "$dir" ]; then
        return
    fi
    if [ -f "$dir/src/rnnoise_data.c" ] && [ -f "$dir/src/rnnoise_data.h" ]; then
        return
    fi
    echo "[wiredeck] downloading rnnoise model sources"
    (cd "$dir" && ./download_model.sh)
}

patch_suil_waf() {
    suil_dir="$VENDOR_DIR/suil"
    waflib_dir=$(find "$suil_dir" -maxdepth 1 -type d -name '.waf3-*' | head -n 1)
    if [ -z "${waflib_dir:-}" ]; then
        return
    fi

    cat >"$suil_dir/imp.py" <<'EOF'
from importlib.util import cache_from_source
from types import ModuleType


def new_module(name):
    return ModuleType(name)


def get_tag():
    path = cache_from_source("dummy.py")
    suffix = ".cpython-"
    marker = path.rfind(suffix)
    if marker == -1:
        return ""
    start = marker + 1
    end = path.find(".", start)
    if end == -1:
        end = len(path)
    return path[start:end]
EOF

    python3 - <<EOF
from pathlib import Path

waflib = Path("$waflib_dir")
for rel in ("waflib/ConfigSet.py", "waflib/Context.py"):
    path = waflib / rel
    text = path.read_text()
    text = text.replace("m='rU'", "m='r'")
    text = text.replace("node.read('rU',encoding)", "node.read('r',encoding)")
    path.write_text(text)

node_path = waflib / "waflib/Node.py"
text = node_path.read_text()
text = text.replace("\n\t\traise StopIteration\n", "\n\t\treturn\n")
node_path.write_text(text)
EOF
}

build_waf() {
    name="$1"
    shift
    src_dir="$VENDOR_DIR/$name"

    if [ "$name" = "suil" ]; then
        patch_suil_waf
    fi

    echo "[wiredeck] building $name (waf)"
    (
        cd "$src_dir"
        python3 ./waf configure --prefix="$PREFIX_DIR" "$@"
        python3 ./waf build
        python3 ./waf install
    )
}

build_meson() {
    name="$1"
    shift
    src_dir="$VENDOR_DIR/$name"
    build_dir="$BUILD_ROOT/$name"

    echo "[wiredeck] building $name (meson)"
    meson setup "$build_dir" "$src_dir" \
        --prefix="$PREFIX_DIR" \
        --buildtype=release \
        "$@" \
        --reconfigure
    meson compile -C "$build_dir"
    meson install -C "$build_dir"
}

build_lv2_stack() {
    build_waf lv2 --no-plugins
    build_meson serd -Ddocs=disabled -Dtests=disabled -Dtools=disabled -Dman=disabled
    build_meson zix -Ddocs=disabled -Dtests=disabled -Dtests_cpp=disabled -Dbenchmarks=disabled
    build_meson sord -Ddocs=disabled -Dtests=disabled -Dtools=disabled -Dbindings_cpp=disabled -Dman=disabled
    build_waf sratom
    build_meson lilv -Ddocs=disabled -Dtests=disabled -Dtools=disabled -Dbindings_cpp=disabled -Dbindings_py=disabled -Ddynmanifest=disabled
    build_waf suil

    if pkg-config --exists lilv-0; then
        echo "[wiredeck] LV2/Lilv stack ready in $PREFIX_DIR"
        pkg-config --modversion lilv-0
    else
        echo "[wiredeck] lilv-0 still not visible via pkg-config" >&2
        exit 1
    fi
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "help" ]; then
    usage
    exit 0
fi

if [ "${1:-}" = "clean" ]; then
    echo "[wiredeck] removing LV2 build caches"
    rm -rf "$BUILD_ROOT" "$PREFIX_DIR"
    exit 0
fi

require_bin python3
require_bin meson
require_bin ninja
require_bin pkg-config

prepare_env

clone_or_update sdl https://github.com/libsdl-org/SDL.git release-3.2.10
clone_or_update cimgui https://github.com/cimgui/cimgui.git docking_inter
sync_submodules_if_present cimgui
clone_or_update implot https://github.com/epezent/implot.git v0.16
clone_or_update volk https://github.com/zeux/volk.git 1.4.304
clone_or_update rnnoise https://github.com/xiph/rnnoise.git v0.2
ensure_rnnoise_model

# LV2 stack for plugin discovery/hosting through lilv.
clone_or_update lv2 https://gitlab.com/lv2/lv2.git v1.18.2
clone_or_update zix https://github.com/drobilla/zix.git v0.6.0
clone_or_update serd https://gitlab.com/drobilla/serd.git v0.32.8
clone_or_update sord https://gitlab.com/drobilla/sord.git v0.16.20
clone_or_update sratom https://github.com/lv2/sratom.git v0.6.10
clone_or_update lilv https://github.com/lv2/lilv.git v0.26.4
clone_or_update suil https://gitlab.com/lv2/suil.git v0.8.4
sync_submodules_if_present lv2
sync_submodules_if_present serd
sync_submodules_if_present sratom

# Build the LV2/Lilv stack so the project can link against it.
build_lv2_stack
