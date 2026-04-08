#!/bin/sh

obs_plugin_detect_os() {
    case "$(uname -s)" in
        Darwin)
            printf '%s\n' "macos"
            ;;
        Linux)
            printf '%s\n' "linux"
            ;;
        MINGW*|MSYS*|CYGWIN*)
            printf '%s\n' "windows"
            ;;
        *)
            return 1
            ;;
    esac
}

obs_plugin_detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)
            printf '%s\n' "x86_64"
            ;;
        arm64|aarch64)
            printf '%s\n' "arm64"
            ;;
        *)
            uname -m
            ;;
    esac
}

obs_plugin_default_install_path() {
    plugin_name="$1"
    target_os="$2"

    case "$target_os" in
        linux)
            printf '%s\n' "$HOME/.config/obs-studio/plugins/$plugin_name"
            ;;
        macos)
            printf '%s\n' "$HOME/Library/Application Support/obs-studio/plugins/$plugin_name.plugin"
            ;;
        windows)
            if [ -n "${ProgramData:-}" ]; then
                printf '%s\n' "$ProgramData/obs-studio/plugins/$plugin_name"
            else
                printf '%s\n' "$HOME/obs-studio/plugins/$plugin_name"
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

obs_plugin_default_build_dir() {
    root_dir="$1"
    target_os="$2"
    target_arch="$3"

    printf '%s\n' "$root_dir/OBS/build/${target_os}-${target_arch}"
}

obs_plugin_default_archive_name() {
    plugin_name="$1"
    version="$2"
    target_os="$3"
    target_arch="$4"

    printf '%s\n' "${plugin_name}-${version}-${target_os}-${target_arch}.zip"
}

obs_plugin_find_binary() {
    build_dir="$1"
    plugin_name="$2"

    find "$build_dir" -type f \( \
        -name "${plugin_name}.so" -o \
        -name "${plugin_name}.dylib" -o \
        -name "${plugin_name}.dll" \
    \) | sort | head -n 1
}

obs_plugin_stage_layout() {
    target_os="$1"
    plugin_name="$2"
    binary_path="$3"
    stage_dir="$4"
    plugin_version="$5"
    bundle_id="${6:-com.wiredeck.${plugin_name}}"

    [ -f "$binary_path" ] || {
        echo "[wiredeck-obs] plugin binary not found: $binary_path" >&2
        return 1
    }

    rm -rf "$stage_dir"
    mkdir -p "$stage_dir"

    case "$target_os" in
        linux|windows)
            binary_ext=${binary_path##*.}
            plugin_root="$stage_dir/$plugin_name"
            mkdir -p "$plugin_root/bin/64bit" "$plugin_root/data/locale"
            cp "$binary_path" "$plugin_root/bin/64bit/$plugin_name.$binary_ext"
            obs_plugin_write_locale "$plugin_root/data/locale"
            ;;
        macos)
            bundle_root="$stage_dir/$plugin_name.plugin"
            contents_dir="$bundle_root/Contents"
            macos_dir="$contents_dir/MacOS"
            resources_dir="$contents_dir/Resources/locale"
            mkdir -p "$macos_dir" "$resources_dir"
            cp "$binary_path" "$macos_dir/$plugin_name"
            chmod 755 "$macos_dir/$plugin_name" || true
            obs_plugin_write_locale "$resources_dir"
            obs_plugin_write_info_plist "$contents_dir/Info.plist" "$plugin_name" "$plugin_version" "$bundle_id"
            ;;
        *)
            echo "[wiredeck-obs] unsupported target OS for staging: $target_os" >&2
            return 1
            ;;
    esac
}

obs_plugin_top_level_entry() {
    plugin_name="$1"
    target_os="$2"

    case "$target_os" in
        macos)
            printf '%s\n' "$plugin_name.plugin"
            ;;
        linux|windows)
            printf '%s\n' "$plugin_name"
            ;;
        *)
            return 1
            ;;
    esac
}

obs_plugin_write_locale() {
    locale_dir="$1"
    mkdir -p "$locale_dir"
    cat > "$locale_dir/en-US.ini" <<'EOF'
WireDeck Output (UDP)=WireDeck Output (UDP)
EOF
}

obs_plugin_write_info_plist() {
    plist_path="$1"
    plugin_name="$2"
    plugin_version="$3"
    bundle_id="$4"

    cat > "$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${plugin_name}</string>
    <key>CFBundleIdentifier</key>
    <string>${bundle_id}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${plugin_name}</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>${plugin_version}</string>
    <key>CFBundleVersion</key>
    <string>${plugin_version}</string>
</dict>
</plist>
EOF
}
