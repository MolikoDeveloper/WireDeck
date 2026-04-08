# WireDeck OBS Plugin

Este plugin vive separado del core de WireDeck en `./OBS/src/wiredeck_obs_output_source`.

## Qué hace

- agrega una fuente de audio a OBS
- pide la IP del host WireDeck
- consulta por UDP los outputs disponibles en WireDeck
- se suscribe al output elegido y recibe PCM `s16le` estéreo a `48 kHz`
- reintenta la conexión automáticamente si el host deja de responder

## Build

Requiere `libobs`/OBS Studio dev packages y CMake:

```bash
./scripts/build-obs.sh
./scripts/install-obs.sh
./scripts/package-obs.sh
```

Si `libobs` no está en una ruta estándar, puedes usar:

```bash
libobs_DIR=/ruta/a/libobs/cmake ./scripts/build-obs.sh
```

El build usa por defecto un directorio separado por plataforma y arquitectura:

```text
./OBS/build/<os>-<arch>
```

### macOS

El script soporta build nativo en macOS y pasa opciones estándar de CMake si las defines:

```bash
OBS_MACOS_ARCHS="arm64;x86_64" \
OBS_MACOS_DEPLOYMENT_TARGET=13.0 \
./scripts/build-obs.sh --target-os macos
```

Por defecto no intenta hacer cross-compile desde Linux a macOS sin un toolchain explícito.

## Install Layouts

La instalación local para OBS en Linux usa esta estructura:

```text
~/.config/obs-studio/plugins/wiredeck_obs_output_source/
  bin/64bit/wiredeck_obs_output_source.so
  data/locale/en-US.ini
```

En macOS el instalador genera un bundle:

```text
~/Library/Application Support/obs-studio/plugins/
  wiredeck_obs_output_source.plugin/
    Contents/
      Info.plist
      MacOS/wiredeck_obs_output_source
      Resources/locale/en-US.ini
```

## Packaging

Para generar un zip listo para distribuir:

```bash
./scripts/package-obs.sh
./scripts/package-obs.sh --target-os macos --version 0.1.0
./scripts/package-obs.sh --skip-build --binary /ruta/al/plugin
```

Los archivos salen por defecto en:

```text
./dist/obs-plugins/
```

## Protocolo

- Puerto fijo de control/audio: `45931/udp`
- Discovery: `DISCOVER_REQUEST` / `DISCOVER_RESPONSE`
- Streaming: `SUBSCRIBE_REQUEST` / `SUBSCRIBE_RESPONSE` + `AUDIO`
- Keepalive: `KEEPALIVE`
- Fin de sesión: `GOODBYE`

El contrato compartido está en:

- `OBS/src/wiredeck_obs_output_source/include/wiredeck_obs_output_protocol.h`

WireDeck usa ese mismo header desde Zig para evitar desalineaciones entre ambos lados.
