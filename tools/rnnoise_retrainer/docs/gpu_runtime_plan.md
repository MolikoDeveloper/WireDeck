# GPU-First Voice Denoiser Plan

## Objetivo

Entrenar y ejecutar un modelo de supresion de ruido para voz usando GPU:

- entrenamiento en Python con PyTorch
- exportacion a binario propio
- inferencia en Zig con Vulkan compute

## Principios

- preservar inteligibilidad de la voz
- reducir ruido de fondo de forma estable
- minimizar jitter de runtime
- evitar dependencias CUDA en el producto final
- mantener un layout de pesos simple de cargar en Zig

## Arquitectura propuesta

Modelo base: `WireDeckVoiceDenoiser`

- entrada: `[batch, frames, bands]`
- bandas por defecto: `64`
- bloque de entrada: proyeccion lineal por banda
- tronco: bloques residuales `Conv2d` ligeros sobre tiempo x frecuencia
- cuello: convoluciones separables para mezclar contexto temporal
- cabeza 1: mascara por banda `[batch, frames, bands]`
- cabeza 2: VAD `[batch, frames, 1]`

Se evita GRU como bloque principal para que la inferencia sea mas natural de mapear a compute shaders.

## Pipeline de runtime en Zig

1. Captura de audio en bloques
2. STFT o banco de bandas
3. Construccion de tensor de entrada en ring buffer
4. Despacho Vulkan:
   - input projection
   - residual blocks
   - mask head
   - vad head
5. Aplicacion de mascara
6. ISTFT / reconstruccion
7. salida de audio

## Forma de tensores sugerida

- activaciones principales: NHWC
  - `N = batch`
  - `H = frames`
  - `W = bands`
  - `C = channels`

Razon:

- facilita el acceso coalescente para kernels por frame/banda
- simplifica empaquetado de features temporales
- reduce complejidad al interoperar con buffers lineales de Zig

## Formato binario de pesos

Archivo: `wiredeck_gpu_model.bin`

Header:

- magic: `WDGP`
- version: `1`
- tensor_count
- metadata_json_size
- tensor_table_json_size

Luego:

- metadata JSON UTF-8
- tabla de tensores JSON UTF-8
- payloads alineados a 16 bytes

Cada tensor describe:

- nombre
- dtype
- rank
- dims
- byte_offset
- byte_length

## Metadata recomendada

- model_name
- export_format_version
- bands
- lookahead_frames
- frame_stride
- input_layout
- output_layout
- sample_rate_hz
- stft_size
- hop_size
- model_hyperparameters

## Criterio de exito

- una sola pasada Vulkan por bloque o pocas pasadas estables
- sin alocaciones dinamicas en el callback de audio
- CPU dedicada solo a IO, STFT/ISTFT si hace falta y coordinacion
- posibilidad de elegir entre CPU y GPU backend sin cambiar el modelo exportado

