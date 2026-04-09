#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT_DIR/scripts/obs-plugin-common.sh"

PLUGIN_NAME="wiredeck_obs_output_source"
HOST_OS=$(obs_plugin_detect_os 2>/dev/null || printf '%s\n' "unknown")
HOST_ARCH=$(obs_plugin_detect_arch)
TARGET_OS="${OBS_TARGET_OS:-$HOST_OS}"
TARGET_ARCH="${OBS_TARGET_ARCH:-$HOST_ARCH}"
BUILD_DIR="${OBS_BUILD_DIR:-$(obs_plugin_default_build_dir "$ROOT_DIR" "$TARGET_OS" "$TARGET_ARCH")}"
OUTPUT_DIR="${OBS_PLUGIN_PACKAGE_DIR:-$ROOT_DIR/dist/obs-plugins}"
PLUGIN_VERSION="${OBS_PLUGIN_VERSION:-}"
PLUGIN_BUILD_PATH="${OBS_PLUGIN_BUILD_PATH:-}"
skip_build=0

usage() {
    cat <<'EOF'
Usage:
  ./scripts/package-obs.sh [--target-os <os>] [--target-arch <arch>] [--version <version>]
  ./scripts/package-obs.sh --skip-build --binary /path/to/plugin

Environment:
  OBS_TARGET_OS          Target platform metadata (default: detected host OS)
  OBS_TARGET_ARCH        Target architecture metadata (default: detected host arch)
  OBS_BUILD_DIR          Override build directory
  OBS_PLUGIN_BUILD_PATH  Override compiled plugin binary path
  OBS_PLUGIN_PACKAGE_DIR Output directory for generated zips
  OBS_PLUGIN_VERSION     Version string for archive naming and macOS bundle metadata
  OBS_PLUGIN_BUNDLE_ID   Override macOS CFBundleIdentifier

Examples:
  ./scripts/package-obs.sh
  ./scripts/package-obs.sh --target-os macos --version 0.1.0
  ./scripts/package-obs.sh --skip-build --binary ./OBS/build/macos-arm64/src/wiredeck_obs_output_source/wiredeck_obs_output_source.so
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --skip-build)
            skip_build=1
            ;;
        --target-os)
            shift
            [ "$#" -gt 0 ] || {
                echo "Missing value for --target-os" >&2
                exit 1
            }
            TARGET_OS="$1"
            ;;
        --target-arch)
            shift
            [ "$#" -gt 0 ] || {
                echo "Missing value for --target-arch" >&2
                exit 1
            }
            TARGET_ARCH="$1"
            ;;
        --version)
            shift
            [ "$#" -gt 0 ] || {
                echo "Missing value for --version" >&2
                exit 1
            }
            PLUGIN_VERSION="$1"
            ;;
        --binary)
            shift
            [ "$#" -gt 0 ] || {
                echo "Missing value for --binary" >&2
                exit 1
            }
            PLUGIN_BUILD_PATH="$1"
            ;;
        --output-dir)
            shift
            [ "$#" -gt 0 ] || {
                echo "Missing value for --output-dir" >&2
                exit 1
            }
            OUTPUT_DIR="$1"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

BUILD_DIR="${OBS_BUILD_DIR:-$(obs_plugin_default_build_dir "$ROOT_DIR" "$TARGET_OS" "$TARGET_ARCH")}"

case "$TARGET_OS" in
    linux|macos|windows)
        ;;
    *)
        echo "[wiredeck-obs] unsupported target OS: $TARGET_OS" >&2
        exit 1
        ;;
esac

if [ -z "$PLUGIN_VERSION" ]; then
    PLUGIN_VERSION=$(git -C "$ROOT_DIR" describe --tags --always --dirty 2>/dev/null || printf '%s\n' "dev")
fi

if [ "$skip_build" -ne 1 ]; then
    OBS_TARGET_OS="$TARGET_OS" OBS_TARGET_ARCH="$TARGET_ARCH" OBS_BUILD_DIR="$BUILD_DIR" \
        "$ROOT_DIR/scripts/build-obs.sh"
fi

if [ -z "$PLUGIN_BUILD_PATH" ]; then
    PLUGIN_BUILD_PATH=$(obs_plugin_find_binary "$BUILD_DIR" "$PLUGIN_NAME")
fi

[ -n "$PLUGIN_BUILD_PATH" ] || {
    echo "[wiredeck-obs] unable to locate built plugin in $BUILD_DIR" >&2
    exit 1
}

[ -f "$PLUGIN_BUILD_PATH" ] || {
    echo "[wiredeck-obs] built plugin not found: $PLUGIN_BUILD_PATH" >&2
    exit 1
}

mkdir -p "$OUTPUT_DIR"

stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/wiredeck-obs-package.XXXXXX")
trap 'rm -rf "$stage_dir"' EXIT INT TERM

obs_plugin_stage_layout "$TARGET_OS" "$PLUGIN_NAME" "$PLUGIN_BUILD_PATH" "$stage_dir" "$PLUGIN_VERSION" \
    "${OBS_PLUGIN_BUNDLE_ID:-com.wiredeck.${PLUGIN_NAME}}"

stage_entry=$(obs_plugin_top_level_entry "$PLUGIN_NAME" "$TARGET_OS")
archive_name=$(obs_plugin_default_archive_name "$PLUGIN_NAME" "$PLUGIN_VERSION" "$TARGET_OS" "$TARGET_ARCH")
archive_path="$OUTPUT_DIR/$archive_name"
rm -f "$archive_path"

if command -v zip >/dev/null 2>&1; then
    (
        cd "$stage_dir"
        zip -qry "$archive_path" "$stage_entry"
    )
elif command -v bsdtar >/dev/null 2>&1; then
    bsdtar -acf "$archive_path" -C "$stage_dir" "$stage_entry"
else
    echo "[wiredeck-obs] neither 'zip' nor 'bsdtar' is available to create the archive" >&2
    exit 1
fi

echo "[wiredeck-obs] packaged plugin:"
echo "  host: $HOST_OS/$HOST_ARCH"
echo "  target: $TARGET_OS/$TARGET_ARCH"
echo "  version: $PLUGIN_VERSION"
echo "  binary: $PLUGIN_BUILD_PATH"
echo "  archive: $archive_path"
