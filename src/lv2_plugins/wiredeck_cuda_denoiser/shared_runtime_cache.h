#ifndef WIREDECK_CUDA_DENOISER_SHARED_RUNTIME_CACHE_H
#define WIREDECK_CUDA_DENOISER_SHARED_RUNTIME_CACHE_H

#include "cuda_backend.h"
#include "cuda_probe.h"
#include "cuda_session.h"
#include "wdgp_runtime.h"

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WireDeckSharedRuntimeEntry {
  char* model_path;
  int gpu_index;
  int ref_count;
  WireDeckWdgpModel model;
  WireDeckCudaSession session;
  WireDeckCudaBackend backend;
  struct WireDeckSharedRuntimeEntry* next;
} WireDeckSharedRuntimeEntry;

void wd_shared_runtime_cache_init(void);
void wd_shared_runtime_cache_shutdown(void);
WireDeckSharedRuntimeEntry* wd_shared_runtime_cache_acquire(
    const char* models_dir,
    const char* model_file_name,
    int gpu_index,
    const char* bundle_path,
    char* error_message,
    size_t error_message_size);
void wd_shared_runtime_cache_release(WireDeckSharedRuntimeEntry* entry);

#ifdef __cplusplus
}
#endif

#endif
