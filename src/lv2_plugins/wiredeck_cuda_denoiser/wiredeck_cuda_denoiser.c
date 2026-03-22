#include "config_store.h"
#include "cuda_backend.h"
#include "cuda_probe.h"
#include "cuda_session.h"
#include "inference_frontend.h"
#include "shared_runtime_cache.h"
#include "wdgp_runtime.h"
#include "wiredeck_cuda_denoiser_shared.h"

#include "lv2/core/lv2.h"

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

typedef struct WireDeckCudaDenoiser {
  const float* enabled;
  const float* threshold;
  const float* buffer_ms;
  const float* mix;
  const float* output_gain_db;
  const float* gpu_index;
  const float* model_index;
  float* cuda_available;
  float* gpu_count;
  float* model_count;
  float* status_code;
  float* input_level;
  float* output_level;
  float* model_loaded;
  float* runtime_phase;
  const float* input_l;
  const float* input_r;
  float* output_l;
  float* output_r;

  WireDeckCudaProbeInfo cuda_info;
  WireDeckCudaDenoiserConfig config;
  WireDeckModelScanResult models;
  int selected_model_index_from_config;
  WireDeckWdgpMetadata selected_model_metadata;
  WireDeckSharedRuntimeEntry* shared_runtime;
  WireDeckInferenceFrontend frontend;
  int runtime_status_code;
  char* bundle_path;
  float* latest_mask;
  float last_mask_mean;
  float last_vad;
  int active_model_index;
  int active_gpu_index;
  long long last_config_mtime_seconds;
  unsigned int sample_rate_hz;
  float* delay_left;
  float* delay_right;
  unsigned int delay_capacity;
  unsigned int delay_read_index;
  unsigned int delay_write_index;
  unsigned int active_delay_samples;
} WireDeckCudaDenoiser;

static int
wd_ensure_delay_buffers(WireDeckCudaDenoiser* self)
{
  unsigned int desired_capacity;
  if (!self) {
    return 0;
  }
  desired_capacity = self->sample_rate_hz > 0 ? (self->sample_rate_hz / 2) + 4096u : 32768u;
  if (desired_capacity < 4096u) {
    desired_capacity = 4096u;
  }
  if (self->delay_capacity == desired_capacity && self->delay_left && self->delay_right) {
    return 1;
  }
  free(self->delay_left);
  free(self->delay_right);
  self->delay_left = (float*)calloc((size_t)desired_capacity, sizeof(float));
  self->delay_right = (float*)calloc((size_t)desired_capacity, sizeof(float));
  if (!self->delay_left || !self->delay_right) {
    free(self->delay_left);
    free(self->delay_right);
    self->delay_left = NULL;
    self->delay_right = NULL;
    self->delay_capacity = 0;
    return 0;
  }
  self->delay_capacity = desired_capacity;
  self->delay_read_index = 0;
  self->delay_write_index = 0;
  self->active_delay_samples = 0;
  return 1;
}

static void
wd_reset_delay_state(WireDeckCudaDenoiser* self, unsigned int delay_samples)
{
  if (!self || !self->delay_left || !self->delay_right || self->delay_capacity == 0) {
    return;
  }
  memset(self->delay_left, 0, (size_t)self->delay_capacity * sizeof(float));
  memset(self->delay_right, 0, (size_t)self->delay_capacity * sizeof(float));
  self->delay_write_index = delay_samples % self->delay_capacity;
  self->delay_read_index = 0;
  self->active_delay_samples = delay_samples;
}

static char*
wd_duplicate_string(const char* input)
{
  size_t len;
  char* copy;
  if (!input) {
    return NULL;
  }
  len = strlen(input);
  copy = (char*)malloc(len + 1);
  if (!copy) {
    return NULL;
  }
  memcpy(copy, input, len + 1);
  return copy;
}

static int
wd_clamp_index(int requested, int upper_bound)
{
  if (upper_bound <= 0) {
    return -1;
  }
  if (requested < 0) {
    return 0;
  }
  if (requested >= upper_bound) {
    return upper_bound - 1;
  }
  return requested;
}

static int
wd_effective_gpu_index(const WireDeckCudaDenoiser* self)
{
  int requested = 0;
  if (!self) {
    return 0;
  }
  if (self->gpu_index) {
    requested = (int)(*self->gpu_index + 0.5f);
  }
  if (requested < 0) {
    return 0;
  }
  if (requested > 0) {
    requested = 0;
  }
  if (self->cuda_info.device_count <= 0) {
    return 0;
  }
  if (requested >= self->cuda_info.device_count) {
    return self->cuda_info.device_count - 1;
  }
  return requested;
}

static int
wd_compute_status(const WireDeckCudaDenoiser* self, int current_model_index)
{
  if (self->runtime_status_code != 0) {
    return self->runtime_status_code;
  }
  if (!self->cuda_info.available) {
    return WD_STATUS_CUDA_UNAVAILABLE;
  }
  if (self->models.count <= 0) {
    return WD_STATUS_NO_MODELS;
  }
  if (current_model_index < 0 || current_model_index >= self->models.count) {
    return WD_STATUS_MODEL_INDEX_INVALID;
  }
  if (!self->models.is_wdgp[current_model_index]) {
    return WD_STATUS_MODEL_FORMAT_UNSUPPORTED;
  }
  return WD_STATUS_WDGP_MODEL_READY;
}

static void
wd_refresh_runtime_state(WireDeckCudaDenoiser* self, int model_index, int gpu_index)
{
  char error_message[256];

  fprintf(stderr, "[wiredeck-cuda-denoiser] refresh requested model_index=%d gpu_index=%d\n", model_index, gpu_index);

  if (self->runtime_phase) {
    *self->runtime_phase = (float)WD_RUNTIME_LOADING;
  }
  self->runtime_status_code = 0;
  wd_shared_runtime_cache_release(self->shared_runtime);
  self->shared_runtime = NULL;
  wd_frontend_deinit(&self->frontend);
  free(self->latest_mask);
  self->latest_mask = NULL;
  self->active_model_index = -1;
  self->active_gpu_index = -1;
  if (self->model_loaded) {
    *self->model_loaded = 0.0f;
  }

  if (!self->cuda_info.available) {
    self->runtime_status_code = WD_STATUS_CUDA_UNAVAILABLE;
    if (self->runtime_phase) *self->runtime_phase = (float)WD_RUNTIME_ERROR;
    return;
  }
  if (model_index < 0 || model_index >= self->models.count) {
    self->runtime_status_code = WD_STATUS_MODEL_INDEX_INVALID;
    if (self->runtime_phase) *self->runtime_phase = (float)WD_RUNTIME_ERROR;
    return;
  }
  if (!self->models.is_wdgp[model_index]) {
    self->runtime_status_code = WD_STATUS_MODEL_FORMAT_UNSUPPORTED;
    if (self->runtime_phase) *self->runtime_phase = (float)WD_RUNTIME_ERROR;
    return;
  }
  if (gpu_index < 0 || gpu_index >= self->cuda_info.device_count) {
    self->runtime_status_code = WD_STATUS_GPU_INDEX_INVALID;
    if (self->runtime_phase) *self->runtime_phase = (float)WD_RUNTIME_ERROR;
    return;
  }
  self->shared_runtime = wd_shared_runtime_cache_acquire(self->config.models_dir, self->models.names[model_index], gpu_index, self->bundle_path, error_message, sizeof(error_message));
  if (!self->shared_runtime) {
    if (strstr(error_message, "CUDA device index invalid") != NULL) {
      self->runtime_status_code = WD_STATUS_GPU_INDEX_INVALID;
    } else if (strstr(error_message, "could not create CUDA context") != NULL) {
      self->runtime_status_code = WD_STATUS_CUDA_CONTEXT_FAILED;
    } else if (strstr(error_message, "missing kernel PTX") != NULL) {
      self->runtime_status_code = WD_STATUS_KERNELS_MISSING;
    } else if (strstr(error_message, "upload weights") != NULL) {
      self->runtime_status_code = WD_STATUS_WEIGHTS_UPLOAD_FAILED;
    } else if (strstr(error_message, "could not load kernel") != NULL || strstr(error_message, "missing CUDA backend symbols") != NULL) {
      self->runtime_status_code = WD_STATUS_KERNEL_LOAD_FAILED;
    } else {
      self->runtime_status_code = WD_STATUS_MODEL_LOAD_FAILED;
    }
    if (self->runtime_phase) *self->runtime_phase = (float)WD_RUNTIME_ERROR;
    return;
  }
  self->selected_model_metadata = self->shared_runtime->model.metadata;
  if (!wd_frontend_prepare(&self->frontend, &self->shared_runtime->model.metadata)) {
    if (strstr(error_message, "missing kernel PTX") != NULL) {
      self->runtime_status_code = WD_STATUS_KERNELS_MISSING;
    } else {
      self->runtime_status_code = WD_STATUS_KERNEL_LOAD_FAILED;
    }
    if (self->runtime_phase) *self->runtime_phase = (float)WD_RUNTIME_ERROR;
    return;
  }
  self->latest_mask = (float*)calloc((size_t)self->shared_runtime->model.metadata.bands, sizeof(float));
  if (!self->latest_mask) {
    self->runtime_status_code = WD_STATUS_KERNEL_LOAD_FAILED;
    if (self->runtime_phase) *self->runtime_phase = (float)WD_RUNTIME_ERROR;
    return;
  }
  self->active_model_index = model_index;
  self->active_gpu_index = gpu_index;
  self->runtime_status_code = WD_STATUS_WDGP_MODEL_READY;
  if (self->model_loaded) {
    *self->model_loaded = 1.0f;
  }
  if (self->runtime_phase) {
    *self->runtime_phase = (float)WD_RUNTIME_IDLE;
  }
}

static void
wd_reload_environment(WireDeckCudaDenoiser* self, int refresh_runtime)
{
  char error_message[256];
  int model_index;

  wd_free_model_scan_result(&self->models);
  memset(&self->selected_model_metadata, 0, sizeof(self->selected_model_metadata));
  wd_shared_runtime_cache_release(self->shared_runtime);
  self->shared_runtime = NULL;
  wd_config_init_defaults(&self->config);
  wd_config_load(&self->config, error_message, sizeof(error_message));
  self->last_config_mtime_seconds = wd_config_mtime_seconds();
  wd_cuda_probe(&self->cuda_info);
  wd_scan_models(self->config.models_dir, &self->models, error_message, sizeof(error_message));
  self->selected_model_index_from_config = wd_find_model_index(&self->models, self->config.selected_model);

  model_index = self->selected_model_index_from_config;
  if (model_index >= 0 && model_index < self->models.count && self->models.is_wdgp[model_index]) {
    wd_load_wdgp_metadata(self->config.models_dir, self->models.names[model_index], &self->selected_model_metadata, error_message, sizeof(error_message));
  }
  if (refresh_runtime) {
    int gpu_index = wd_effective_gpu_index(self);
    wd_refresh_runtime_state(self, model_index, gpu_index);
  }
}

static LV2_Handle
wd_instantiate(const LV2_Descriptor* descriptor,
               double rate,
               const char* bundle_path,
               const LV2_Feature* const* features)
{
  WireDeckCudaDenoiser* self = (WireDeckCudaDenoiser*)calloc(1, sizeof(WireDeckCudaDenoiser));
  char error_message[256];
  (void)descriptor;
  (void)rate;
  (void)bundle_path;
  (void)features;

  if (!self) {
    return NULL;
  }

  wd_shared_runtime_cache_init();
  wd_frontend_init(&self->frontend);
  self->sample_rate_hz = rate > 1000.0 ? (unsigned int)(rate + 0.5) : 48000u;
  self->active_model_index = -1;
  self->active_gpu_index = -1;
  if (!wd_ensure_delay_buffers(self)) {
    free(self);
    return NULL;
  }
  if (bundle_path) {
    self->bundle_path = wd_duplicate_string(bundle_path);
  }
  wd_reload_environment(self, 0);
  return (LV2_Handle)self;
}

static void
wd_connect_port(LV2_Handle instance, uint32_t port, void* data)
{
  WireDeckCudaDenoiser* self = (WireDeckCudaDenoiser*)instance;

  switch ((WireDeckCudaDenoiserPortIndex)port) {
  case WD_PORT_ENABLED:
    self->enabled = (const float*)data;
    break;
  case WD_PORT_THRESHOLD:
    self->threshold = (const float*)data;
    break;
  case WD_PORT_BUFFER_MS:
    self->buffer_ms = (const float*)data;
    break;
  case WD_PORT_MIX:
    self->mix = (const float*)data;
    break;
  case WD_PORT_OUTPUT_GAIN_DB:
    self->output_gain_db = (const float*)data;
    break;
  case WD_PORT_GPU_INDEX:
    self->gpu_index = (const float*)data;
    break;
  case WD_PORT_MODEL_INDEX:
    self->model_index = (const float*)data;
    break;
  case WD_PORT_CUDA_AVAILABLE:
    self->cuda_available = (float*)data;
    break;
  case WD_PORT_GPU_COUNT:
    self->gpu_count = (float*)data;
    break;
  case WD_PORT_MODEL_COUNT:
    self->model_count = (float*)data;
    break;
  case WD_PORT_STATUS_CODE:
    self->status_code = (float*)data;
    break;
  case WD_PORT_INPUT_LEVEL:
    self->input_level = (float*)data;
    break;
  case WD_PORT_OUTPUT_LEVEL:
    self->output_level = (float*)data;
    break;
  case WD_PORT_MODEL_LOADED:
    self->model_loaded = (float*)data;
    break;
  case WD_PORT_RUNTIME_PHASE:
    self->runtime_phase = (float*)data;
    break;
  case WD_PORT_INPUT_L:
    self->input_l = (const float*)data;
    break;
  case WD_PORT_INPUT_R:
    self->input_r = (const float*)data;
    break;
  case WD_PORT_OUTPUT_L:
    self->output_l = (float*)data;
    break;
  case WD_PORT_OUTPUT_R:
    self->output_r = (float*)data;
    break;
  }
}

static void
wd_activate(LV2_Handle instance)
{
  WireDeckCudaDenoiser* self = (WireDeckCudaDenoiser*)instance;
  wd_reload_environment(self, 0);
}

static void
wd_run(LV2_Handle instance, uint32_t sample_count)
{
  WireDeckCudaDenoiser* self = (WireDeckCudaDenoiser*)instance;
  uint32_t sample_index;
  int model_index = self->selected_model_index_from_config >= 0 ? self->selected_model_index_from_config : 0;
  int status_code;
  const long long config_mtime_seconds = wd_config_mtime_seconds();
  float block_input_peak = 0.0f;
  float block_output_peak = 0.0f;
  unsigned int requested_delay_samples = 0;
  float reduction = self->threshold ? *self->threshold : 0.8f;
  float mix = self->mix ? *self->mix : 1.0f;
  float output_gain_db = self->output_gain_db ? *self->output_gain_db : 0.0f;
  float output_gain;

  if (reduction < 0.0f) reduction = 0.0f;
  if (reduction > 1.0f) reduction = 1.0f;
  if (mix < 0.0f) mix = 0.0f;
  if (mix > 1.0f) mix = 1.0f;
  if (output_gain_db < -24.0f) output_gain_db = -24.0f;
  if (output_gain_db > 24.0f) output_gain_db = 24.0f;
  output_gain = powf(10.0f, output_gain_db / 20.0f);
  if (self->buffer_ms) {
    float buffer_ms = *self->buffer_ms;
    if (buffer_ms < 0.0f) buffer_ms = 0.0f;
    if (buffer_ms > 500.0f) buffer_ms = 500.0f;
    requested_delay_samples = (unsigned int)((buffer_ms * (float)self->sample_rate_hz) / 1000.0f + 0.5f);
  }
  if (!wd_ensure_delay_buffers(self)) {
    requested_delay_samples = 0;
  }
  if (requested_delay_samples >= self->delay_capacity && self->delay_capacity > 0) {
    requested_delay_samples = self->delay_capacity - 1;
  }
  if (requested_delay_samples != self->active_delay_samples) {
    wd_reset_delay_state(self, requested_delay_samples);
  }

  if (config_mtime_seconds != 0 && config_mtime_seconds != self->last_config_mtime_seconds) {
    wd_reload_environment(self, 0);
  }

  if (self->model_index) {
    model_index = wd_clamp_index((int)(*self->model_index + 0.5f), self->models.count);
  }
  {
    int gpu_index = wd_effective_gpu_index(self);
    if (!self->shared_runtime || model_index != self->active_model_index || gpu_index != self->active_gpu_index) {
      self->selected_model_index_from_config = model_index;
      wd_refresh_runtime_state(self, model_index, gpu_index);
    }
  }

  status_code = wd_compute_status(self, model_index);

  if (self->cuda_available) {
    *self->cuda_available = self->cuda_info.available ? 1.0f : 0.0f;
  }
  if (self->gpu_count) {
    *self->gpu_count = (float)self->cuda_info.device_count;
  }
  if (self->model_count) {
    *self->model_count = (float)self->models.count;
  }
  if (self->status_code) {
    *self->status_code = (float)status_code;
  }
  if (self->model_loaded) {
    *self->model_loaded = (status_code == WD_STATUS_WDGP_MODEL_READY && self->shared_runtime != NULL) ? 1.0f : 0.0f;
  }
  if (self->runtime_phase) {
    *self->runtime_phase = (float)((status_code == WD_STATUS_WDGP_MODEL_READY) ? WD_RUNTIME_IDLE : WD_RUNTIME_ERROR);
  }

  if (!self->output_l || !self->output_r || !self->input_l || !self->input_r) {
    return;
  }

  for (sample_index = 0; sample_index < sample_count; ++sample_index) {
    float left = self->input_l[sample_index];
    float right = self->input_r[sample_index];
    float mono = 0.5f * (left + right);
    float input_abs = mono < 0.0f ? -mono : mono;
    float final_left;
    float final_right;

    if (input_abs > block_input_peak) {
      block_input_peak = input_abs;
    }

    if (mix <= 0.001f || reduction <= 0.001f) {
      final_left = left * output_gain;
      final_right = right * output_gain;
      if (self->runtime_phase) *self->runtime_phase = (float)WD_RUNTIME_BYPASS;
    } else if (self->enabled && *self->enabled < 0.5f) {
      final_left = left * output_gain;
      final_right = right * output_gain;
      if (self->runtime_phase) *self->runtime_phase = (float)WD_RUNTIME_BYPASS;
    } else {
      if (status_code == WD_STATUS_WDGP_MODEL_READY && wd_frontend_push(&self->frontend, mono)) {
        char error_message[256];
        const float* features = wd_frontend_latest_features(&self->frontend);
        if (self->runtime_phase) *self->runtime_phase = (float)WD_RUNTIME_RUNNING;
        if (!self->shared_runtime || !wd_cuda_backend_run_model(&self->shared_runtime->backend, &self->shared_runtime->session, &self->shared_runtime->model, features, self->latest_mask, &self->last_mask_mean, &self->last_vad, error_message, sizeof(error_message))) {
          fprintf(stderr, "[wiredeck-cuda-denoiser] run_model failed on gpu=%d model=%d: %s\n", self->active_gpu_index, self->active_model_index, error_message[0] ? error_message : "unknown");
          self->runtime_status_code = WD_STATUS_KERNEL_LOAD_FAILED;
          status_code = self->runtime_status_code;
          if (self->runtime_phase) *self->runtime_phase = (float)WD_RUNTIME_ERROR;
          if (self->status_code) {
            *self->status_code = (float)status_code;
          }
        } else {
          wd_frontend_apply_mask_and_synthesize(&self->frontend, self->latest_mask, reduction);
          if (self->runtime_phase) *self->runtime_phase = (float)WD_RUNTIME_RUNNING;
        }
      }

      if (status_code == WD_STATUS_WDGP_MODEL_READY) {
        float processed = wd_frontend_take_output_sample(&self->frontend);
        final_left = ((processed * mix) + (left * (1.0f - mix))) * output_gain;
        final_right = ((processed * mix) + (right * (1.0f - mix))) * output_gain;
      } else {
        final_left = left * output_gain;
        final_right = right * output_gain;
      }
    }

    if (requested_delay_samples > 0 && self->delay_left && self->delay_right && self->delay_capacity > 0) {
      float delayed_left = self->delay_left[self->delay_read_index];
      float delayed_right = self->delay_right[self->delay_read_index];
      self->delay_left[self->delay_write_index] = final_left;
      self->delay_right[self->delay_write_index] = final_right;
      self->delay_read_index = (self->delay_read_index + 1u) % self->delay_capacity;
      self->delay_write_index = (self->delay_write_index + 1u) % self->delay_capacity;
      final_left = delayed_left;
      final_right = delayed_right;
    }

    self->output_l[sample_index] = final_left;
    self->output_r[sample_index] = final_right;
    if ((final_left < 0.0f ? -final_left : final_left) > block_output_peak) block_output_peak = (final_left < 0.0f ? -final_left : final_left);
    if ((final_right < 0.0f ? -final_right : final_right) > block_output_peak) block_output_peak = (final_right < 0.0f ? -final_right : final_right);
  }

  if (self->input_level) {
    *self->input_level = block_input_peak;
  }
  if (self->output_level) {
    *self->output_level = block_output_peak;
  }
  if (self->runtime_phase && *self->runtime_phase == (float)WD_RUNTIME_RUNNING) {
    *self->runtime_phase = (float)WD_RUNTIME_IDLE;
  }
}

static void
wd_deactivate(LV2_Handle instance)
{
  (void)instance;
}

static void
wd_cleanup(LV2_Handle instance)
{
  WireDeckCudaDenoiser* self = (WireDeckCudaDenoiser*)instance;
  if (!self) {
    return;
  }
  wd_shared_runtime_cache_release(self->shared_runtime);
  wd_frontend_deinit(&self->frontend);
  wd_free_model_scan_result(&self->models);
  free(self->latest_mask);
  free(self->delay_left);
  free(self->delay_right);
  free(self->bundle_path);
  free(self);
}

static const void*
wd_extension_data(const char* uri)
{
  (void)uri;
  return NULL;
}

static const LV2_Descriptor wd_descriptor = {
  WIREDECK_CUDA_DENOISER_URI,
  wd_instantiate,
  wd_connect_port,
  wd_activate,
  wd_run,
  wd_deactivate,
  wd_cleanup,
  wd_extension_data,
};

LV2_SYMBOL_EXPORT
const LV2_Descriptor*
lv2_descriptor(uint32_t index)
{
  return index == 0 ? &wd_descriptor : NULL;
}
