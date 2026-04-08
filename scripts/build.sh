#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SDL_SRC_DIR="$ROOT_DIR/vendor/sdl"
SDL_BUILD_DIR="$ROOT_DIR/.cache/sdl3-build"
SDL_PREFIX_DIR="$ROOT_DIR/.cache/sdl3-prefix"
LILV_PREFIX_DIR="${LILV_PREFIX:-$ROOT_DIR/.cache/lilv-prefix}"

[ -f "$SDL_SRC_DIR/CMakeLists.txt" ] || {
    echo "Missing vendored SDL3 in $SDL_SRC_DIR" >&2
    exit 1
}

if [ ! -f "$SDL_PREFIX_DIR/lib/libSDL3.a" ] && [ ! -f "$SDL_PREFIX_DIR/lib64/libSDL3.a" ]; then
    cmake -S "$SDL_SRC_DIR" -B "$SDL_BUILD_DIR" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$SDL_PREFIX_DIR" \
        -DSDL_SHARED=ON \
        -DSDL_STATIC=ON \
        -DSDL_TEST_LIBRARY=OFF \
        -DSDL_TESTS=OFF
    cmake --build "$SDL_BUILD_DIR"
    cmake --install "$SDL_BUILD_DIR"
fi

export PKG_CONFIG_PATH="$SDL_PREFIX_DIR/lib/pkgconfig:$SDL_PREFIX_DIR/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="$SDL_PREFIX_DIR/lib:$SDL_PREFIX_DIR/lib64:${LD_LIBRARY_PATH:-}"
export LIBRARY_PATH="$SDL_PREFIX_DIR/lib:$SDL_PREFIX_DIR/lib64:${LIBRARY_PATH:-}"
export C_INCLUDE_PATH="$SDL_PREFIX_DIR/include:${C_INCLUDE_PATH:-}"

configure_lilv_support() {
    if [ -f "$LILV_PREFIX_DIR/lib/pkgconfig/lilv-0.pc" ] || [ -f "$LILV_PREFIX_DIR/lib64/pkgconfig/lilv-0.pc" ]; then
        export PKG_CONFIG_PATH="$LILV_PREFIX_DIR/lib/pkgconfig:$LILV_PREFIX_DIR/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
        export LD_LIBRARY_PATH="$LILV_PREFIX_DIR/lib:$LILV_PREFIX_DIR/lib64:${LD_LIBRARY_PATH:-}"
        export LIBRARY_PATH="$LILV_PREFIX_DIR/lib:$LILV_PREFIX_DIR/lib64:${LIBRARY_PATH:-}"
        export C_INCLUDE_PATH="$LILV_PREFIX_DIR/include:${C_INCLUDE_PATH:-}"
    fi

    if pkg-config --exists lilv-0 2>/dev/null; then
        return 0
    fi
    return 1
}

install_wiredeck_lv2_bundle() {
    BUNDLE_SRC_DIR="$ROOT_DIR/src/lv2_plugins/wiredeck_cuda_denoiser.bundle"
    BUNDLE_DST_DIR="$HOME/.lv2/wiredeck-cuda-denoiser.lv2"
    KERNEL_SRC_DIR="$ROOT_DIR/src/lv2_plugins/wiredeck_cuda_denoiser/kernels"
    KERNEL_BUILD_DIR="$ROOT_DIR/.cache/wiredeck-cuda-kernels"
    PLUGIN_SO="$ROOT_DIR/zig-out/lib/libwiredeck_cuda_denoiser.so"
    UI_SO="$ROOT_DIR/zig-out/lib/libwiredeck_cuda_denoiser_ui.so"

    [ -d "$BUNDLE_SRC_DIR" ] || return 0
    [ -f "$PLUGIN_SO" ] || return 0
    [ -f "$UI_SO" ] || return 0

    mkdir -p "$BUNDLE_DST_DIR"
    mkdir -p "$KERNEL_BUILD_DIR"
    mkdir -p "$BUNDLE_DST_DIR/kernels"

    if command -v nvcc >/dev/null 2>&1; then
        for kernel_src in "$KERNEL_SRC_DIR"/*.cu; do
            [ -f "$kernel_src" ] || continue
            kernel_name=$(basename "$kernel_src" .cu)
            nvcc -ptx -arch=compute_80 -o "$KERNEL_BUILD_DIR/$kernel_name.ptx" "$kernel_src"
            cp "$KERNEL_BUILD_DIR/$kernel_name.ptx" "$BUNDLE_DST_DIR/kernels/"
        done
    fi

    cp "$BUNDLE_SRC_DIR/manifest.ttl" "$BUNDLE_DST_DIR/"
    cp "$BUNDLE_SRC_DIR/wiredeck_cuda_denoiser.ttl" "$BUNDLE_DST_DIR/"
    cp "$PLUGIN_SO" "$BUNDLE_DST_DIR/"
    cp "$UI_SO" "$BUNDLE_DST_DIR/"
    echo "[wiredeck] installed LV2 bundle: $BUNDLE_DST_DIR"
}

cd "$ROOT_DIR"

zig_args=""
if configure_lilv_support; then
    echo "[wiredeck] lilv support: enabled"
    zig_args="$zig_args -Denable-lilv=true"
    if pkg-config --exists suil-0 gtk+-2.0 gtk+-x11-2.0 x11 2>/dev/null; then
        echo "[wiredeck] suil support: enabled"
        zig_args="$zig_args -Denable-suil=true"
    fi
fi

command_name="${1:-build}"
if [ "$#" -gt 0 ]; then
    shift
fi

if [ "$command_name" = "convert" ]; then
    APP_NAME=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -app|--app)
                shift
                [ "$#" -gt 0 ] || {
                    echo "Missing value for -app" >&2
                    exit 1
                }
                APP_NAME="$1"
                ;;
            *)
                echo "Unknown convert argument: $1" >&2
                exit 1
                ;;
        esac
        shift
    done

    [ -n "$APP_NAME" ] || {
        echo "Usage: ./scripts/build.sh convert -app <name>" >&2
        exit 1
    }

    zig build $zig_args run -- --convert-app "$APP_NAME"
    exit 0
fi

if [ "$command_name" = "activity" ]; then
    SOURCE_FILTER=""
    ACTIVITY_TICKS=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -app|--app|-source|--source|--filter)
                shift
                [ "$#" -gt 0 ] || {
                    echo "Missing value for source filter" >&2
                    exit 1
                }
                SOURCE_FILTER="$1"
                ;;
            -ticks|--ticks)
                shift
                [ "$#" -gt 0 ] || {
                    echo "Missing value for ticks" >&2
                    exit 1
                }
                ACTIVITY_TICKS="$1"
                ;;
            *)
                echo "Unknown activity argument: $1" >&2
                exit 1
                ;;
        esac
        shift
    done

    set -- run -- --print-source-activity
    if [ -n "$SOURCE_FILTER" ]; then
        set -- "$@" --source-filter "$SOURCE_FILTER"
    fi
    if [ -n "$ACTIVITY_TICKS" ]; then
        set -- "$@" --activity-ticks "$ACTIVITY_TICKS"
    fi

    zig build $zig_args "$@"
    exit 0
fi

case "$command_name" in
    build)
        zig build $zig_args "$@"
        install_wiredeck_lv2_bundle
        ;;
    run)
        zig build $zig_args "$@"
        install_wiredeck_lv2_bundle
        exec "$ROOT_DIR/zig-out/bin/wiredeck" "$@"
        ;;
    test)
        zig build $zig_args test "$@"
        ;;
    client)
        client_mode="build"
        if [ "$#" -gt 0 ] && [ "$1" = "run" ]; then
            client_mode="run"
            shift
        elif [ "$#" -gt 0 ] && [ "$1" = "build" ]; then
            shift
        fi

        case "$client_mode" in
            build)
                zig build $zig_args client "$@"
                ;;
            run)
                zig build $zig_args client
                exec "$ROOT_DIR/zig-out/bin/wiredeck-client" "$@"
                ;;
            *)
                echo "Unknown client mode: $client_mode" >&2
                exit 1
                ;;
        esac
        ;;
    *)
        echo "Unknown command: $command_name" >&2
        exit 1
        ;;
esac
