#ifndef WIREDECK_CUDA_DENOISER_CUDA_PROBE_H
#define WIREDECK_CUDA_DENOISER_CUDA_PROBE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define WD_CUDA_MAX_DEVICES 16
#define WD_CUDA_MAX_NAME 128

typedef struct WireDeckCudaProbeInfo {
  int available;
  int device_count;
  char device_names[WD_CUDA_MAX_DEVICES][WD_CUDA_MAX_NAME];
  char error_message[256];
} WireDeckCudaProbeInfo;

int wd_cuda_probe(WireDeckCudaProbeInfo* out_info);

#ifdef __cplusplus
}
#endif

#endif
