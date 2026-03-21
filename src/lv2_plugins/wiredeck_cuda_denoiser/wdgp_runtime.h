#ifndef WIREDECK_CUDA_DENOISER_WDGP_RUNTIME_H
#define WIREDECK_CUDA_DENOISER_WDGP_RUNTIME_H

#include "config_store.h"

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WireDeckWdgpTensorInfo {
  char name[96];
  int dtype_code;
  int rank;
  int dims[4];
  size_t offset;
  size_t byte_length;
} WireDeckWdgpTensorInfo;

typedef struct WireDeckWdgpModel {
  WireDeckWdgpMetadata metadata;
  WireDeckWdgpTensorInfo* tensors;
  int tensor_count;
  unsigned char* payload;
  size_t payload_size;
  int architecture_valid;
} WireDeckWdgpModel;

void wd_wdgp_model_init(WireDeckWdgpModel* model);
void wd_wdgp_model_deinit(WireDeckWdgpModel* model);
int wd_wdgp_model_load(const char* models_dir, const char* file_name, WireDeckWdgpModel* out_model, char* error_message, size_t error_message_size);
const WireDeckWdgpTensorInfo* wd_wdgp_find_tensor(const WireDeckWdgpModel* model, const char* name);
int wd_wdgp_validate_architecture(const WireDeckWdgpModel* model, char* error_message, size_t error_message_size);

#ifdef __cplusplus
}
#endif

#endif
