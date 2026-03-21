#ifndef WIREDECK_CUDA_DENOISER_CUDA_BACKEND_H
#define WIREDECK_CUDA_DENOISER_CUDA_BACKEND_H

#include "cuda_session.h"
#include "wdgp_runtime.h"

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define WD_CUDA_KERNEL_COUNT 7

typedef struct WireDeckCudaWeightBuffer {
  char name[96];
  unsigned long long device_ptr;
  size_t size_bytes;
} WireDeckCudaWeightBuffer;

typedef struct WireDeckCudaBackend {
  void* module_handles[WD_CUDA_KERNEL_COUNT];
  void* function_handles[WD_CUDA_KERNEL_COUNT];
  WireDeckCudaWeightBuffer* weights;
  int weight_count;
  unsigned long long input_device_ptr;
  unsigned long long x_device_ptr;
  unsigned long long a_device_ptr;
  unsigned long long b_device_ptr;
  unsigned long long c_device_ptr;
  unsigned long long hidden_device_ptr;
  unsigned long long mask_device_ptr;
  unsigned long long vad_map_device_ptr;
  unsigned long long vad_scalar_device_ptr;
  unsigned long long mask_host_ptr;
  unsigned long long vad_host_ptr;
  size_t input_size_bytes;
  size_t channels_size_bytes;
  size_t hidden_size_bytes;
  size_t mask_size_bytes;
  size_t vad_size_bytes;
  unsigned int sequence_frames;
  unsigned int target_frame_index;
  int kernels_ready;
  int weights_ready;
} WireDeckCudaBackend;

void wd_cuda_backend_init(WireDeckCudaBackend* backend);
void wd_cuda_backend_deinit(WireDeckCudaBackend* backend, WireDeckCudaSession* session);
int wd_cuda_backend_prepare(
    WireDeckCudaBackend* backend,
    WireDeckCudaSession* session,
    const WireDeckWdgpModel* model,
    const char* bundle_path,
    const char* models_dir,
    char* error_message,
    size_t error_message_size);
int wd_cuda_backend_run_input_projection(
    WireDeckCudaBackend* backend,
    WireDeckCudaSession* session,
    const WireDeckWdgpModel* model,
    const float* features,
    char* error_message,
    size_t error_message_size);
int wd_cuda_backend_run_model(
    WireDeckCudaBackend* backend,
    WireDeckCudaSession* session,
    const WireDeckWdgpModel* model,
    const float* features,
    float* out_mask,
    float* out_mask_mean,
    float* out_vad,
    char* error_message,
    size_t error_message_size);

#ifdef __cplusplus
}
#endif

#endif
