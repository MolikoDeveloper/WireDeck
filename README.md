# WireDeck

WireDeck is a desktop audio routing tool built on Zig, SDL3, PipeWire, Vulkan, and LV2/Lilv.

<img width="1478" height="690" alt="image" src="https://github.com/user-attachments/assets/0b570eb2-0af8-4512-9660-20d73a772547" />

## Requirements

- Linux
- Zig `0.15.2`
- `git`
- `cmake`
- `meson`
- `ninja`
- `pkg-config`
- toolchain C/C++ (`build-essential`)
- PipeWire / SPA development headers
- Vulkan development headers
- GTK2 / X11 development headers
- `libpng`
- ImageMagick MagickWand/MagickCore development headers

On Ubuntu/Debian you can install the required system dependencies with:

```bash
sudo ./scripts/install_system_deps_ubuntu.sh
```

## Vendored Dependencies

This project uses vendored dependencies in `vendor/`.

There are two important groups:

- UI/rendering dependencies such as `SDL`, `cimgui`, `implot`, `volk`, `rnnoise`
- the LV2/Lilv stack for discovery and hosting: `lv2`, `serd`, `zix`, `sord`, `sratom`, `lilv`, `suil`

To fetch and prepare those dependencies:

```bash
./scripts/fetch_vendor_deps.sh
```

That script:

- clones or updates missing vendored dependencies
- builds the LV2/Lilv stack into `.cache/lilv-prefix`
- prepares the environment so `build.sh` can detect `lilv` and `suil`

If the vendored source is already present and you only want to rebuild the LV2/Lilv stack:

```bash
./scripts/build_vendor_lv2.sh
```

## Building

Standard build:

```bash
./scripts/build.sh build
```

Small release build:

```bash
./scripts/build.sh build -Doptimize=ReleaseSmall
```

Build artifacts are generated in:

- `zig-out/bin/wiredeck`
- `zig-out/bin/wiredeck-lv2-ui-host` si `lilv` y `suil` están disponibles
- `zig-out/bin/wiredeck-lv2-ui-host` if `lilv` and `suil` are available

## Running In Debug

To build and run in debug mode:

```bash
./scripts/build.sh run
```

That command:

- builds the project in debug mode
- installs the local LV2 bundle when applicable
- runs `zig-out/bin/wiredeck`

## Recommended Setup Flow

Initial setup on Ubuntu/Debian:

```bash
sudo ./scripts/install_system_deps_ubuntu.sh
./scripts/fetch_vendor_deps.sh
./scripts/build.sh run
```

## Debian Packaging

To build a `.deb` package in `ReleaseSmall` mode:

```bash
./scripts/package_deb.sh
```

The package is generated at:

```bash
.dist/deb/wiredeck_0.2.0_amd64.deb
```

You can override the package version like this:

```bash
PACKAGE_VERSION=0.2.1 ./scripts/package_deb.sh
```
