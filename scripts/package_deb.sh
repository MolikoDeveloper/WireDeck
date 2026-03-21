#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PACKAGE_NAME="${PACKAGE_NAME:-wiredeck}"
PACKAGE_ARCH="${PACKAGE_ARCH:-$(dpkg --print-architecture)}"
PACKAGE_MAINTAINER="${PACKAGE_MAINTAINER:-WireDeck Maintainers <noreply@wiredeck.app>}"
PACKAGE_SECTION="${PACKAGE_SECTION:-sound}"
PACKAGE_PRIORITY="${PACKAGE_PRIORITY:-optional}"
PACKAGE_DESCRIPTION="${PACKAGE_DESCRIPTION:-Modern PipeWire audio routing and control surface}"
OPTIMIZE_MODE="${OPTIMIZE_MODE:-ReleaseSmall}"

BUILD_ROOT="$ROOT_DIR/.dist/deb"
SHLIBDEPS_WORK_DIR="$BUILD_ROOT/debian"

require_bin() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing required command: $1" >&2
        exit 1
    }
}

require_bin dpkg-deb
require_bin dpkg-shlibdeps
require_bin dpkg
require_bin sed

resolve_package_version() {
    if [ -n "${PACKAGE_VERSION_FILE:-}" ] && [ -f "${PACKAGE_VERSION_FILE}" ]; then
        sed -n '1s/[[:space:]]*$//p' "${PACKAGE_VERSION_FILE}"
        return
    fi

    if [ -f "$ROOT_DIR/VERSION" ]; then
        sed -n '1s/[[:space:]]*$//p' "$ROOT_DIR/VERSION"
        return
    fi

    sed -n 's/.*SDL_SetAppMetadata("WireDeck", "\([^"]*\)",.*/\1/p' "$ROOT_DIR/src/platform/sdl.zig" | head -n 1
}

write_maintainer_script() {
    script_name="$1"
    script_path="$DEBIAN_DIR/$script_name"
    cat > "$script_path" <<EOF
#!/bin/sh
set -e

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications || true
fi

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi

exit 0
EOF
    chmod 0755 "$script_path"
}

PACKAGE_VERSION="${PACKAGE_VERSION:-$(resolve_package_version)}"
PKG_ROOT="$BUILD_ROOT/${PACKAGE_NAME}_${PACKAGE_VERSION}_${PACKAGE_ARCH}"
DEBIAN_DIR="$PKG_ROOT/DEBIAN"
OUTPUT_DEB="$BUILD_ROOT/${PACKAGE_NAME}_${PACKAGE_VERSION}_${PACKAGE_ARCH}.deb"
LV2_DST_DIR="$PKG_ROOT/usr/lib/lv2/wiredeck-cuda-denoiser.lv2"
ICON_THEME_DIR_REL="usr/share/icons/hicolor/256x256/apps"
ICON_THEME_DIR="$PKG_ROOT/$ICON_THEME_DIR_REL"
APP_SHARE_DIR="$PKG_ROOT/usr/share/wiredeck"

mkdir -p "$BUILD_ROOT"
rm -rf "$PKG_ROOT"
rm -rf "$SHLIBDEPS_WORK_DIR"

cd "$ROOT_DIR"
./scripts/build.sh build -Doptimize="$OPTIMIZE_MODE"

mkdir -p \
    "$DEBIAN_DIR" \
    "$PKG_ROOT/usr/bin" \
    "$PKG_ROOT/usr/share/applications" \
    "$ICON_THEME_DIR" \
    "$PKG_ROOT/usr/share/pixmaps" \
    "$APP_SHARE_DIR" \
    "$PKG_ROOT/usr/share/doc/$PACKAGE_NAME"

install -m 0755 "$ROOT_DIR/zig-out/bin/wiredeck" "$PKG_ROOT/usr/bin/wiredeck"
install -m 0644 "$ROOT_DIR/packaging/linux/wiredeck.desktop" "$PKG_ROOT/usr/share/applications/wiredeck.desktop"
install -m 0644 "$ROOT_DIR/src/assets/icons/wiredeck.png" "$PKG_ROOT/usr/share/pixmaps/wiredeck.png"
install -m 0644 "$ROOT_DIR/src/assets/icons/wiredeck.png" "$ICON_THEME_DIR/wiredeck.png"
cp -a "$ROOT_DIR/src/assets" "$APP_SHARE_DIR/"

if [ -f "$ROOT_DIR/zig-out/bin/wiredeck-lv2-ui-host" ]; then
    install -m 0755 "$ROOT_DIR/zig-out/bin/wiredeck-lv2-ui-host" "$PKG_ROOT/usr/bin/wiredeck-lv2-ui-host"
fi

if [ -f "$ROOT_DIR/zig-out/lib/libwiredeck_cuda_denoiser.so" ] && [ -f "$ROOT_DIR/zig-out/lib/libwiredeck_cuda_denoiser_ui.so" ]; then
    mkdir -p "$LV2_DST_DIR"
    install -m 0644 "$ROOT_DIR/src/lv2_plugins/wiredeck_cuda_denoiser.bundle/manifest.ttl" "$LV2_DST_DIR/manifest.ttl"
    install -m 0644 "$ROOT_DIR/src/lv2_plugins/wiredeck_cuda_denoiser.bundle/wiredeck_cuda_denoiser.ttl" "$LV2_DST_DIR/wiredeck_cuda_denoiser.ttl"
    install -m 0755 "$ROOT_DIR/zig-out/lib/libwiredeck_cuda_denoiser.so" "$LV2_DST_DIR/libwiredeck_cuda_denoiser.so"
    install -m 0755 "$ROOT_DIR/zig-out/lib/libwiredeck_cuda_denoiser_ui.so" "$LV2_DST_DIR/libwiredeck_cuda_denoiser_ui.so"
    if [ -d "$ROOT_DIR/.cache/wiredeck-cuda-kernels" ]; then
        mkdir -p "$LV2_DST_DIR/kernels"
        find "$ROOT_DIR/.cache/wiredeck-cuda-kernels" -maxdepth 1 -type f -name '*.ptx' -exec install -m 0644 {} "$LV2_DST_DIR/kernels/" \;
    fi
fi

cat > "$PKG_ROOT/usr/share/doc/$PACKAGE_NAME/README.Debian" <<EOF
This package was generated from the local WireDeck workspace.
The main executable is installed as /usr/bin/wiredeck.
EOF

mkdir -p "$SHLIBDEPS_WORK_DIR"
cat > "$SHLIBDEPS_WORK_DIR/control" <<EOF
Source: $PACKAGE_NAME
Section: $PACKAGE_SECTION
Priority: $PACKAGE_PRIORITY
Maintainer: $PACKAGE_MAINTAINER
Standards-Version: 4.7.0

Package: $PACKAGE_NAME
Architecture: $PACKAGE_ARCH
Description: $PACKAGE_DESCRIPTION
EOF

SHLIBDEPS_ARGS="
-O
-e$PKG_ROOT/usr/bin/wiredeck
"

if [ -f "$PKG_ROOT/usr/bin/wiredeck-lv2-ui-host" ]; then
    SHLIBDEPS_ARGS="$SHLIBDEPS_ARGS -e$PKG_ROOT/usr/bin/wiredeck-lv2-ui-host"
fi

if [ -f "$LV2_DST_DIR/libwiredeck_cuda_denoiser.so" ]; then
    SHLIBDEPS_ARGS="$SHLIBDEPS_ARGS -e$LV2_DST_DIR/libwiredeck_cuda_denoiser.so"
fi

if [ -f "$LV2_DST_DIR/libwiredeck_cuda_denoiser_ui.so" ]; then
    SHLIBDEPS_ARGS="$SHLIBDEPS_ARGS -e$LV2_DST_DIR/libwiredeck_cuda_denoiser_ui.so"
fi

# shellcheck disable=SC2086
SHLIBDEPS_OUTPUT=$(cd "$BUILD_ROOT" && dpkg-shlibdeps $SHLIBDEPS_ARGS)
DEPENDS=$(printf '%s\n' "$SHLIBDEPS_OUTPUT" | sed -n 's/^shlibs:Depends=//p')

INSTALLED_SIZE=$(du -sk "$PKG_ROOT" | cut -f1)

cat > "$DEBIAN_DIR/control" <<EOF
Package: $PACKAGE_NAME
Version: $PACKAGE_VERSION
Section: $PACKAGE_SECTION
Priority: $PACKAGE_PRIORITY
Architecture: $PACKAGE_ARCH
Maintainer: $PACKAGE_MAINTAINER
Installed-Size: $INSTALLED_SIZE
Depends: $DEPENDS
Description: $PACKAGE_DESCRIPTION
 WireDeck is a desktop audio routing tool built on PipeWire and SDL.
 This package installs the main application, desktop launcher, icon,
 and optional LV2 helper components when they are available.
EOF

write_maintainer_script postinst
write_maintainer_script postrm

dpkg-deb --root-owner-group --build "$PKG_ROOT" "$OUTPUT_DEB"
printf '%s\n' "$OUTPUT_DEB"
