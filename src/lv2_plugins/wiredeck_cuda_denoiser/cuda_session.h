#ifndef WIREDECK_CUDA_DENOISER_CUDA_SESSION_H
#define WIREDECK_CUDA_DENOISER_CUDA_SESSION_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WireDeckCudaSession {
  void* libcuda_handle;
  void* context;
  int device_index;
  int ready;
} WireDeckCudaSession;

void wd_cuda_session_init(WireDeckCudaSession* session);
void wd_cuda_session_deinit(WireDeckCudaSession* session);
int wd_cuda_session_open(WireDeckCudaSession* session, int device_index, char* error_message, size_t error_message_size);
int wd_cuda_session_make_current(WireDeckCudaSession* session, char* error_message, size_t error_message_size);

#ifdef __cplusplus
}
#endif

#endif
