#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT_DIR/scripts/obs-plugin-common.sh"

OBS_DIR="$ROOT_DIR/OBS"
BUILD_TYPE="${BUILD_TYPE:-RelWithDebInfo}"
GENERATOR="${CMAKE_GENERATOR:-}"
HOST_OS=$(obs_plugin_detect_os 2>/dev/null || printf '%s\n' "unknown")
HOST_ARCH=$(obs_plugin_detect_arch)
TARGET_OS="${OBS_TARGET_OS:-$HOST_OS}"
TARGET_ARCH="${OBS_TARGET_ARCH:-$HOST_ARCH}"
BUILD_DIR="${OBS_BUILD_DIR:-$(obs_plugin_default_build_dir "$ROOT_DIR" "$TARGET_OS" "$TARGET_ARCH")}"
MACOS_ARCHS="${CMAKE_OSX_ARCHITECTURES:-${OBS_MACOS_ARCHS:-}}"
MACOS_DEPLOYMENT_TARGET="${CMAKE_OSX_DEPLOYMENT_TARGET:-${OBS_MACOS_DEPLOYMENT_TARGET:-}}"

usage() {
    cat <<'EOF'
Usage:
  ./scripts/build-obs.sh [build] [--target-os <os>] [--target-arch <arch>] [-- <extra cmake --build args>]
  ./scripts/build-obs.sh clean [--target-os <os>] [--target-arch <arch>]

Environment:
  OBS_TARGET_OS       Target platform metadata (default: detected host OS)
  OBS_TARGET_ARCH     Target architecture metadata (default: detected host arch)
  OBS_BUILD_DIR       Override build directory (default: ./OBS/build/<os>-<arch>)
  BUILD_TYPE          CMake build type (default: RelWithDebInfo)
  CMAKE_GENERATOR     Override generator. If empty, Ninja is preferred when available.
  CMAKE_PREFIX_PATH   Extra CMake prefix path for libobs
  libobs_DIR          Path to libobsConfig.cmake directory
  OBS_MACOS_ARCHS     Value for CMAKE_OSX_ARCHITECTURES when building on macOS
  OBS_MACOS_DEPLOYMENT_TARGET
                      Value for CMAKE_OSX_DEPLOYMENT_TARGET when building on macOS

Examples:
  ./scripts/build-obs.sh
  ./scripts/build-obs.sh --target-os macos
  ./scripts/build-obs.sh -- -j8
  libobs_DIR=/path/to/libobs/cmake ./scripts/build-obs.sh
EOF
}

[ -d "$OBS_DIR" ] || {
    echo "Missing OBS directory at $OBS_DIR" >&2
    exit 1
}

command_name="build"
while [ "$#" -gt 0 ]; do
    case "$1" in
        build)
            shift
            ;;
        clean)
            command_name="clean"
            shift
            ;;
        --target-os)
            shift
            [ "$#" -gt 0 ] || {
                echo "Missing value for --target-os" >&2
                exit 1
            }
            TARGET_OS="$1"
            shift
            ;;
        --target-arch)
            shift
            [ "$#" -gt 0 ] || {
                echo "Missing value for --target-arch" >&2
                exit 1
            }
            TARGET_ARCH="$1"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            break
            ;;
    esac
done

BUILD_DIR="${OBS_BUILD_DIR:-$(obs_plugin_default_build_dir "$ROOT_DIR" "$TARGET_OS" "$TARGET_ARCH")}"

if [ "$command_name" = "clean" ]; then
    rm -rf "$BUILD_DIR"
    echo "[wiredeck-obs] removed build directory: $BUILD_DIR"
    exit 0
fi

case "$TARGET_OS" in
    linux|macos|windows)
        ;;
    *)
        echo "[wiredeck-obs] unsupported target OS: $TARGET_OS" >&2
        exit 1
        ;;
esac

if [ "$TARGET_OS" != "$HOST_OS" ] && [ -z "${CMAKE_TOOLCHAIN_FILE:-}" ]; then
    cat >&2 <<EOF
[wiredeck-obs] target OS '$TARGET_OS' does not match host OS '$HOST_OS'.

By default this script expects a native build. For macOS builds, run it on macOS,
or provide an explicit CMake toolchain via CMAKE_TOOLCHAIN_FILE for cross-compiling.
EOF
    exit 1
fi

mkdir -p "$BUILD_DIR"

if [ -z "$GENERATOR" ] && command -v ninja >/dev/null 2>&1; then
    GENERATOR="Ninja"
fi

if [ -f "$BUILD_DIR/CMakeCache.txt" ] && [ -z "${CMAKE_GENERATOR:-}" ]; then
    existing_generator=$(sed -n 's/^CMAKE_GENERATOR:INTERNAL=//p' "$BUILD_DIR/CMakeCache.txt" | head -n 1)
    if [ -n "$existing_generator" ]; then
        GENERATOR="$existing_generator"
    fi
fi

echo "[wiredeck-obs] root: $ROOT_DIR"
echo "[wiredeck-obs] source: $OBS_DIR"
echo "[wiredeck-obs] build: $BUILD_DIR"
echo "[wiredeck-obs] host: $HOST_OS/$HOST_ARCH"
echo "[wiredeck-obs] target: $TARGET_OS/$TARGET_ARCH"
echo "[wiredeck-obs] build type: $BUILD_TYPE"
if [ -n "$GENERATOR" ]; then
    echo "[wiredeck-obs] generator: $GENERATOR"
fi
if [ -n "${libobs_DIR:-}" ]; then
    echo "[wiredeck-obs] libobs_DIR: $libobs_DIR"
fi
if [ -n "${CMAKE_PREFIX_PATH:-}" ]; then
    echo "[wiredeck-obs] CMAKE_PREFIX_PATH: $CMAKE_PREFIX_PATH"
fi
if [ -n "$MACOS_ARCHS" ]; then
    echo "[wiredeck-obs] CMAKE_OSX_ARCHITECTURES: $MACOS_ARCHS"
fi
if [ -n "$MACOS_DEPLOYMENT_TARGET" ]; then
    echo "[wiredeck-obs] CMAKE_OSX_DEPLOYMENT_TARGET: $MACOS_DEPLOYMENT_TARGET"
fi

run_configure() (
    set -- cmake -S "$OBS_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
    if [ -n "$GENERATOR" ]; then
        set -- "$@" -G "$GENERATOR"
    fi
    if [ -n "$MACOS_ARCHS" ]; then
        set -- "$@" "-DCMAKE_OSX_ARCHITECTURES=$MACOS_ARCHS"
    fi
    if [ -n "$MACOS_DEPLOYMENT_TARGET" ]; then
        set -- "$@" "-DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_DEPLOYMENT_TARGET"
    fi
    "$@"
)

set +e
run_configure
configure_status=$?
set -e

if [ "$configure_status" -ne 0 ]; then
    cat >&2 <<'EOF'
[wiredeck-obs] cmake configure failed.

Most likely cause:
  libobs development files are not installed or not visible to CMake.

Try one of these:
  1. Install the OBS/libobs development package for your distro
  2. Export CMAKE_PREFIX_PATH to the OBS SDK prefix
  3. Export libobs_DIR to the directory containing libobsConfig.cmake

Example:
  libobs_DIR=/opt/obs/lib/cmake/libobs ./scripts/build-obs.sh
EOF
    exit "$configure_status"
fi

cmake --build "$BUILD_DIR" "$@"

echo "[wiredeck-obs] build complete"
