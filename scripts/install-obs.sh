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

usage() {
    cat <<'EOF'
Usage:
  ./scripts/install-obs.sh [--target-os <os>] [--target-arch <arch>]
  ./scripts/install-obs.sh --skip-build
  ./scripts/install-obs.sh --help

Environment:
  OBS_TARGET_OS         Target platform metadata (default: detected host OS)
  OBS_TARGET_ARCH       Target architecture metadata (default: detected host arch)
  OBS_BUILD_DIR         Override build directory
  OBS_USER_PLUGIN_DIR   Override final install path
  OBS_PLUGIN_BUILD_PATH Override compiled plugin binary path

Examples:
  ./scripts/install-obs.sh
  ./scripts/install-obs.sh --target-os macos
  OBS_USER_PLUGIN_DIR="$HOME/.config/obs-studio/plugins/wiredeck_obs_output_source" ./scripts/install-obs.sh
EOF
}

skip_build=0
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
OBS_USER_PLUGIN_DIR="${OBS_USER_PLUGIN_DIR:-$(obs_plugin_default_install_path "$PLUGIN_NAME" "$TARGET_OS")}"
PLUGIN_BUILD_PATH="${OBS_PLUGIN_BUILD_PATH:-$(obs_plugin_find_binary "$BUILD_DIR" "$PLUGIN_NAME")}"

if [ "$skip_build" -ne 1 ]; then
    OBS_TARGET_OS="$TARGET_OS" OBS_TARGET_ARCH="$TARGET_ARCH" OBS_BUILD_DIR="$BUILD_DIR" \
        "$ROOT_DIR/scripts/build-obs.sh"
    PLUGIN_BUILD_PATH="${OBS_PLUGIN_BUILD_PATH:-$(obs_plugin_find_binary "$BUILD_DIR" "$PLUGIN_NAME")}"
fi

[ -f "$PLUGIN_BUILD_PATH" ] || {
    echo "[wiredeck-obs] built plugin not found: $PLUGIN_BUILD_PATH" >&2
    exit 1
}

stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/wiredeck-obs-install.XXXXXX")
trap 'rm -rf "$stage_dir"' EXIT INT TERM

obs_plugin_stage_layout "$TARGET_OS" "$PLUGIN_NAME" "$PLUGIN_BUILD_PATH" "$stage_dir" "dev" \
    "${OBS_PLUGIN_BUNDLE_ID:-com.wiredeck.${PLUGIN_NAME}}"

stage_entry=$(obs_plugin_top_level_entry "$PLUGIN_NAME" "$TARGET_OS")
rm -rf "$OBS_USER_PLUGIN_DIR"
mkdir -p "$(dirname "$OBS_USER_PLUGIN_DIR")"
cp -R "$stage_dir/$stage_entry" "$OBS_USER_PLUGIN_DIR"

echo "[wiredeck-obs] installed plugin:"
echo "  host: $HOST_OS/$HOST_ARCH"
echo "  target: $TARGET_OS/$TARGET_ARCH"
echo "  binary: $PLUGIN_BUILD_PATH"
echo "  install: $OBS_USER_PLUGIN_DIR"
