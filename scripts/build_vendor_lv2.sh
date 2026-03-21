#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
VENDOR_DIR="$ROOT_DIR/vendor"
BUILD_ROOT="${LV2_BUILD_ROOT:-$ROOT_DIR/.cache/lv2-build}"
PREFIX_DIR="${LILV_PREFIX:-$ROOT_DIR/.cache/lilv-prefix}"

usage() {
    cat <<'EOF'
Usage:
  ./scripts/build_vendor_lv2.sh [clean]

Builds the vendored LV2/Lilv dependency stack into:
  .cache/lilv-prefix
EOF
}

require_bin() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "[wiredeck] missing required binary: $1" >&2
        exit 1
    fi
}

require_vendor_dir() {
    if [ ! -d "$VENDOR_DIR/$1" ]; then
        echo "[wiredeck] missing vendor dependency: $VENDOR_DIR/$1" >&2
        echo "[wiredeck] run ./scripts/fetch_vendor_deps.sh first" >&2
        exit 1
    fi
}

prepare_env() {
    mkdir -p "$BUILD_ROOT" "$PREFIX_DIR"
    export PKG_CONFIG_PATH="$PREFIX_DIR/lib/pkgconfig:$PREFIX_DIR/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
    export LD_LIBRARY_PATH="$PREFIX_DIR/lib:$PREFIX_DIR/lib64:${LD_LIBRARY_PATH:-}"
    export LIBRARY_PATH="$PREFIX_DIR/lib:$PREFIX_DIR/lib64:${LIBRARY_PATH:-}"
    export C_INCLUDE_PATH="$PREFIX_DIR/include:${C_INCLUDE_PATH:-}"
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
    require_vendor_dir "$name"

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
    require_vendor_dir "$name"

    echo "[wiredeck] building $name (meson)"
    meson setup "$build_dir" "$src_dir" \
        --prefix="$PREFIX_DIR" \
        --buildtype=release \
        "$@" \
        --reconfigure
    meson compile -C "$build_dir"
    meson install -C "$build_dir"
}

main() {
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

main "$@"
