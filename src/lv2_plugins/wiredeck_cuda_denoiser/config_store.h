#ifndef WIREDECK_CUDA_DENOISER_CONFIG_STORE_H
#define WIREDECK_CUDA_DENOISER_CONFIG_STORE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define WD_CONFIG_PATH_CAP 1024
#define WD_MODELS_DIR_CAP 1024
#define WD_MODEL_NAME_CAP 256

typedef struct WireDeckCudaDenoiserConfig {
  char models_dir[WD_MODELS_DIR_CAP];
  char selected_model[WD_MODEL_NAME_CAP];
} WireDeckCudaDenoiserConfig;

typedef struct WireDeckModelScanResult {
  char** names;
  int* is_wdgp;
  int count;
} WireDeckModelScanResult;

typedef struct WireDeckWdgpMetadata {
  int valid;
  int sample_rate_hz;
  int stft_size;
  int hop_size;
  int bands;
  int channels;
  int hidden_channels;
  int residual_blocks;
  int kernel_time;
  int kernel_freq;
  int lookahead_frames;
  int tensor_count;
  char model_name[128];
  char export_format[128];
} WireDeckWdgpMetadata;

void wd_config_init_defaults(WireDeckCudaDenoiserConfig* config);
int wd_config_load(WireDeckCudaDenoiserConfig* config, char* error_message, size_t error_message_size);
int wd_config_save(const WireDeckCudaDenoiserConfig* config, char* error_message, size_t error_message_size);
int wd_config_resolve_path(char* out_path, size_t out_path_size);
long long wd_config_mtime_seconds(void);
int wd_expand_home_path(const char* input, char* output, size_t output_size);
int wd_scan_models(const char* models_dir, WireDeckModelScanResult* out_result, char* error_message, size_t error_message_size);
void wd_free_model_scan_result(WireDeckModelScanResult* result);
int wd_find_model_index(const WireDeckModelScanResult* result, const char* model_name);
const char* wd_status_code_label(int status_code);
int wd_load_wdgp_metadata(const char* models_dir, const char* file_name, WireDeckWdgpMetadata* out_metadata, char* error_message, size_t error_message_size);

#ifdef __cplusplus
}
#endif

#endif
