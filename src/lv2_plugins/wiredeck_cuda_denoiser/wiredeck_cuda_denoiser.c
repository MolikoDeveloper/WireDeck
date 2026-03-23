#define _POSIX_C_SOURCE 200809L

#include "config_store.h"
#include "cuda_backend.h"
#include "cuda_probe.h"
#include "cuda_session.h"
#include "inference_frontend.h"
#include "shared_runtime_cache.h"
#include "wdgp_runtime.h"
#include "wiredeck_cuda_denoiser_shared.h"

#include "lv2/core/lv2.h"

#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct WireDeckPluginRuntime {
  WireDeckSharedRuntimeEntry* shared_runtime;
  WireDeckInferenceFrontend frontend;
  float* latest_mask;
  float* smoothed_mask;
  float last_mask_mean;
  float last_vad;
  int model_index;
  int gpu_index;
  unsigned int sample_rate_hz;
  pthread_t inference_thread;
  int inference_thread_started;
  int inference_stop;
  unsigned int inference_request_generation;
  unsigned int inference_processed_generation;
  unsigned int inference_request_slot;
  unsigned int inference_result_slot;
  float* inference_feature_buffers[2];
  float* inference_mask_buffers[2];
  float inference_mask_means[2];
  float inference_vad_values[2];
  struct WireDeckPluginRuntime* retired_next;
} WireDeckPluginRuntime;

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
  float* suppressed_noise_level;
  float* voice_preservation_level;
  const float* input_l;
  const float* input_r;
  float* output_l;
  float* output_r;

  WireDeckCudaProbeInfo cuda_info;
  WireDeckCudaDenoiserConfig config;
  WireDeckModelScanResult models;
  WireDeckWdgpMetadata selected_model_metadata;
  int runtime_status_code;
  char* bundle_path;
  long long last_config_mtime_seconds;
  unsigned int sample_rate_hz;

  float* delay_left;
  float* delay_right;
  unsigned int delay_capacity;
  unsigned int delay_read_index;
  unsigned int delay_write_index;
  unsigned int active_delay_samples;

  pthread_t worker_thread;
  int worker_thread_started;
  int worker_stop;
  int snapshot_status_code;
  int snapshot_cuda_available;
  int snapshot_gpu_count;
  int snapshot_model_count;
  int host_active;
  int desired_enabled;
  int desired_model_index;
  int desired_gpu_index;
  unsigned int request_generation;
  unsigned int prepared_generation;
  WireDeckPluginRuntime* current_runtime;
  WireDeckPluginRuntime* staged_runtime;
  WireDeckPluginRuntime* retired_runtime_head;
} WireDeckCudaDenoiser;

static void wd_runtime_retire(WireDeckCudaDenoiser* self, WireDeckPluginRuntime* runtime);
static WireDeckPluginRuntime* wd_atomic_exchange_runtime(WireDeckPluginRuntime** slot, WireDeckPluginRuntime* value);

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
wd_effective_gpu_index_from_value(int requested, int device_count)
{
  if (device_count <= 0) {
    return 0;
  }
  if (requested < 0) {
    return 0;
  }
  if (requested >= device_count) {
    return device_count - 1;
  }
  return requested;
}

static int
wd_effective_enabled(const WireDeckCudaDenoiser* self)
{
  if (!self || !self->enabled) {
    return 1;
  }
  return *self->enabled >= 0.5f;
}

static void
wd_release_active_runtimes(WireDeckCudaDenoiser* self)
{
  WireDeckPluginRuntime* runtime;

  if (!self) {
    return;
  }

  runtime = wd_atomic_exchange_runtime(&self->staged_runtime, NULL);
  if (runtime) {
    wd_runtime_retire(self, runtime);
  }

  runtime = wd_atomic_exchange_runtime(&self->current_runtime, NULL);
  if (runtime) {
    wd_runtime_retire(self, runtime);
  }
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
  return wd_effective_gpu_index_from_value(requested, self->snapshot_gpu_count);
}

static float
wd_downmix_input_sample(float left, float right)
{
  const float silence_threshold = 1.0e-6f;
  float left_abs = left < 0.0f ? -left : left;
  float right_abs = right < 0.0f ? -right : right;

  if (left_abs <= silence_threshold && right_abs > silence_threshold) {
    return right;
  }
  if (right_abs <= silence_threshold && left_abs > silence_threshold) {
    return left;
  }
  return 0.5f * (left + right);
}

static unsigned int
wd_atomic_load_u32(const unsigned int* value)
{
  return __atomic_load_n(value, __ATOMIC_ACQUIRE);
}

static int
wd_atomic_load_int(const int* value)
{
  return __atomic_load_n(value, __ATOMIC_ACQUIRE);
}

static void
wd_atomic_store_u32(unsigned int* value, unsigned int next)
{
  __atomic_store_n(value, next, __ATOMIC_RELEASE);
}

static void
wd_atomic_store_int(int* value, int next)
{
  __atomic_store_n(value, next, __ATOMIC_RELEASE);
}

static WireDeckPluginRuntime*
wd_atomic_load_runtime(WireDeckPluginRuntime* const* slot)
{
  return __atomic_load_n(slot, __ATOMIC_ACQUIRE);
}

static WireDeckPluginRuntime*
wd_atomic_exchange_runtime(WireDeckPluginRuntime** slot, WireDeckPluginRuntime* value)
{
  return __atomic_exchange_n(slot, value, __ATOMIC_ACQ_REL);
}

static void
wd_runtime_destroy(WireDeckPluginRuntime* runtime)
{
  int index;
  if (!runtime) {
    return;
  }
  __atomic_store_n(&runtime->inference_stop, 1, __ATOMIC_RELEASE);
  if (runtime->inference_thread_started) {
    pthread_join(runtime->inference_thread, NULL);
  }
  wd_shared_runtime_cache_release(runtime->shared_runtime);
  wd_frontend_deinit(&runtime->frontend);
  free(runtime->latest_mask);
  free(runtime->smoothed_mask);
  for (index = 0; index < 2; ++index) {
    free(runtime->inference_feature_buffers[index]);
    free(runtime->inference_mask_buffers[index]);
  }
  free(runtime);
}

static void*
wd_inference_worker_main(void* opaque)
{
  WireDeckPluginRuntime* runtime = (WireDeckPluginRuntime*)opaque;
  unsigned int processed_generation = 0;

  while (!__atomic_load_n(&runtime->inference_stop, __ATOMIC_ACQUIRE)) {
    unsigned int request_generation = __atomic_load_n(&runtime->inference_request_generation, __ATOMIC_ACQUIRE);
    if (request_generation != processed_generation) {
      unsigned int slot = __atomic_load_n(&runtime->inference_request_slot, __ATOMIC_ACQUIRE) & 1u;
      char error_message[256];
      float mask_mean = 1.0f;
      float vad_value = 1.0f;

      if (runtime->shared_runtime &&
          wd_cuda_backend_run_model(
              &runtime->shared_runtime->backend,
              &runtime->shared_runtime->session,
              &runtime->shared_runtime->model,
              runtime->inference_feature_buffers[slot],
              runtime->inference_mask_buffers[slot],
              &mask_mean,
              &vad_value,
              error_message,
              sizeof(error_message))) {
        runtime->inference_mask_means[slot] = mask_mean;
        runtime->inference_vad_values[slot] = vad_value;
        __atomic_store_n(&runtime->inference_result_slot, slot, __ATOMIC_RELEASE);
        __atomic_store_n(&runtime->inference_processed_generation, request_generation, __ATOMIC_RELEASE);
      }
      processed_generation = request_generation;
      continue;
    }

    {
      struct timespec sleep_time;
      sleep_time.tv_sec = 0;
      sleep_time.tv_nsec = 1000 * 1000;
      nanosleep(&sleep_time, NULL);
    }
  }

  return NULL;
}

static void
wd_runtime_retire(WireDeckCudaDenoiser* self, WireDeckPluginRuntime* runtime)
{
  WireDeckPluginRuntime* head;
  if (!self || !runtime) {
    return;
  }
  do {
    head = wd_atomic_load_runtime((WireDeckPluginRuntime* const*)&self->retired_runtime_head);
    runtime->retired_next = head;
  } while (!__atomic_compare_exchange_n(&self->retired_runtime_head, &head, runtime, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE));
}

static void
wd_runtime_drain_retired(WireDeckCudaDenoiser* self)
{
  WireDeckPluginRuntime* runtime = wd_atomic_exchange_runtime(&self->retired_runtime_head, NULL);
  while (runtime) {
    WireDeckPluginRuntime* next = runtime->retired_next;
    runtime->retired_next = NULL;
    wd_runtime_destroy(runtime);
    runtime = next;
  }
}

static WireDeckPluginRuntime*
wd_runtime_create(
    WireDeckCudaDenoiser* self,
    const char* models_dir,
    const char* model_name,
    int model_index,
    int gpu_index,
    char* error_message,
    size_t error_message_size)
{
  WireDeckPluginRuntime* runtime;

  if (!self || !models_dir || !model_name) {
    if (error_message && error_message_size > 0) {
      snprintf(error_message, error_message_size, "invalid runtime arguments");
    }
    return NULL;
  }

  runtime = (WireDeckPluginRuntime*)calloc(1, sizeof(WireDeckPluginRuntime));
  if (!runtime) {
    if (error_message && error_message_size > 0) {
      snprintf(error_message, error_message_size, "out of memory");
    }
    return NULL;
  }

  wd_frontend_init(&runtime->frontend);
  runtime->shared_runtime = wd_shared_runtime_cache_acquire(models_dir, model_name, gpu_index, self->bundle_path, error_message, error_message_size);
  if (!runtime->shared_runtime) {
    wd_runtime_destroy(runtime);
    return NULL;
  }
  if (!wd_frontend_prepare(&runtime->frontend, &runtime->shared_runtime->model.metadata)) {
    if (error_message && error_message_size > 0) {
      snprintf(error_message, error_message_size, "could not prepare inference frontend");
    }
    wd_runtime_destroy(runtime);
    return NULL;
  }
  runtime->latest_mask = (float*)calloc((size_t)runtime->shared_runtime->model.metadata.bands, sizeof(float));
  runtime->smoothed_mask = (float*)calloc((size_t)runtime->shared_runtime->model.metadata.bands, sizeof(float));
  runtime->inference_feature_buffers[0] = (float*)calloc(
      (size_t)runtime->shared_runtime->backend.sequence_frames * (size_t)runtime->shared_runtime->model.metadata.bands,
      sizeof(float));
  runtime->inference_feature_buffers[1] = (float*)calloc(
      (size_t)runtime->shared_runtime->backend.sequence_frames * (size_t)runtime->shared_runtime->model.metadata.bands,
      sizeof(float));
  runtime->inference_mask_buffers[0] = (float*)calloc((size_t)runtime->shared_runtime->model.metadata.bands, sizeof(float));
  runtime->inference_mask_buffers[1] = (float*)calloc((size_t)runtime->shared_runtime->model.metadata.bands, sizeof(float));
  if (!runtime->latest_mask || !runtime->smoothed_mask || !runtime->inference_feature_buffers[0] || !runtime->inference_feature_buffers[1] || !runtime->inference_mask_buffers[0] || !runtime->inference_mask_buffers[1]) {
    if (error_message && error_message_size > 0) {
      snprintf(error_message, error_message_size, "out of memory");
    }
    wd_runtime_destroy(runtime);
    return NULL;
  }
  memset(runtime->latest_mask, 0x00, (size_t)runtime->shared_runtime->model.metadata.bands * sizeof(float));
  memset(runtime->smoothed_mask, 0x00, (size_t)runtime->shared_runtime->model.metadata.bands * sizeof(float));
  {
    int band_index;
    for (band_index = 0; band_index < runtime->shared_runtime->model.metadata.bands; ++band_index) {
      runtime->latest_mask[band_index] = 1.0f;
      runtime->smoothed_mask[band_index] = 1.0f;
      runtime->inference_mask_buffers[0][band_index] = 1.0f;
      runtime->inference_mask_buffers[1][band_index] = 1.0f;
    }
  }
  runtime->model_index = model_index;
  runtime->gpu_index = gpu_index;
  runtime->sample_rate_hz = runtime->shared_runtime->model.metadata.sample_rate_hz > 0
      ? (unsigned int)runtime->shared_runtime->model.metadata.sample_rate_hz
      : 48000u;
  if (pthread_create(&runtime->inference_thread, NULL, wd_inference_worker_main, runtime) == 0) {
    runtime->inference_thread_started = 1;
  } else {
    if (error_message && error_message_size > 0) {
      snprintf(error_message, error_message_size, "could not create inference worker");
    }
    wd_runtime_destroy(runtime);
    return NULL;
  }
  if (error_message && error_message_size > 0) {
    error_message[0] = '\0';
  }
  return runtime;
}

static int
wd_error_to_status_code(const char* error_message)
{
  if (!error_message || error_message[0] == '\0') {
    return WD_STATUS_MODEL_LOAD_FAILED;
  }
  if (strstr(error_message, "CUDA device index invalid") != NULL) {
    return WD_STATUS_GPU_INDEX_INVALID;
  }
  if (strstr(error_message, "could not create CUDA context") != NULL) {
    return WD_STATUS_CUDA_CONTEXT_FAILED;
  }
  if (strstr(error_message, "missing kernel PTX") != NULL) {
    return WD_STATUS_KERNELS_MISSING;
  }
  if (strstr(error_message, "upload weights") != NULL) {
    return WD_STATUS_WEIGHTS_UPLOAD_FAILED;
  }
  if (strstr(error_message, "could not load kernel") != NULL ||
      strstr(error_message, "missing CUDA backend symbols") != NULL ||
      strstr(error_message, "could not prepare inference frontend") != NULL) {
    return WD_STATUS_KERNEL_LOAD_FAILED;
  }
  return WD_STATUS_MODEL_LOAD_FAILED;
}

static void
wd_request_reload(WireDeckCudaDenoiser* self)
{
  if (!self) {
    return;
  }
  __atomic_add_fetch(&self->request_generation, 1u, __ATOMIC_ACQ_REL);
}

static void
wd_sync_requested_runtime(WireDeckCudaDenoiser* self)
{
  int model_index = self->model_index ? (int)(*self->model_index + 0.5f) : -1;
  int gpu_index = self->gpu_index ? (int)(*self->gpu_index + 0.5f) : 0;
  int enabled = wd_effective_enabled(self);
  int previous_model = wd_atomic_load_int(&self->desired_model_index);
  int previous_gpu = wd_atomic_load_int(&self->desired_gpu_index);
  int previous_enabled = wd_atomic_load_int(&self->desired_enabled);

  if (previous_model != model_index) {
    wd_atomic_store_int(&self->desired_model_index, model_index);
    wd_request_reload(self);
  }
  if (previous_gpu != gpu_index) {
    wd_atomic_store_int(&self->desired_gpu_index, gpu_index);
    wd_request_reload(self);
  }
  if (previous_enabled != enabled) {
    wd_atomic_store_int(&self->desired_enabled, enabled);
    wd_request_reload(self);
  }
}

static void
wd_swap_staged_runtime(WireDeckCudaDenoiser* self)
{
  WireDeckPluginRuntime* staged;
  WireDeckPluginRuntime* previous;

  if (!self) {
    return;
  }

  staged = wd_atomic_exchange_runtime(&self->staged_runtime, NULL);
  if (!staged) {
    return;
  }

  previous = wd_atomic_exchange_runtime(&self->current_runtime, staged);
  if (previous) {
    wd_runtime_retire(self, previous);
  }
}

static void
wd_worker_publish_runtime(WireDeckCudaDenoiser* self, WireDeckPluginRuntime* runtime)
{
  WireDeckPluginRuntime* previous;
  if (!self || !runtime) {
    return;
  }
  previous = wd_atomic_exchange_runtime(&self->staged_runtime, runtime);
  if (previous) {
    wd_runtime_destroy(previous);
  }
}

static void
wd_worker_refresh_snapshot(WireDeckCudaDenoiser* self)
{
  wd_atomic_store_int(&self->snapshot_cuda_available, self->cuda_info.available ? 1 : 0);
  wd_atomic_store_int(&self->snapshot_gpu_count, self->cuda_info.device_count);
  wd_atomic_store_int(&self->snapshot_model_count, self->models.count);
}

static void
wd_worker_process_request(WireDeckCudaDenoiser* self, unsigned int request_generation)
{
  char error_message[256];
  int desired_model_index;
  int desired_gpu_index;
  int desired_enabled;
  int host_active;
  int effective_gpu_index;
  int active_model_index;
  int status_code = WD_STATUS_NO_MODELS;
  WireDeckPluginRuntime* runtime = NULL;

  wd_free_model_scan_result(&self->models);
  memset(&self->selected_model_metadata, 0, sizeof(self->selected_model_metadata));
  wd_config_init_defaults(&self->config);
  wd_config_load(&self->config, error_message, sizeof(error_message));
  self->last_config_mtime_seconds = wd_config_mtime_seconds();
  wd_cuda_probe(&self->cuda_info);
  wd_scan_models(self->config.models_dir, &self->models, error_message, sizeof(error_message));
  wd_worker_refresh_snapshot(self);

  desired_model_index = wd_atomic_load_int(&self->desired_model_index);
  desired_gpu_index = wd_atomic_load_int(&self->desired_gpu_index);
  desired_enabled = wd_atomic_load_int(&self->desired_enabled);
  host_active = wd_atomic_load_int(&self->host_active);
  effective_gpu_index = wd_effective_gpu_index_from_value(desired_gpu_index, self->cuda_info.device_count);

  active_model_index = desired_model_index;
  if (active_model_index < 0) {
    active_model_index = wd_find_model_index(&self->models, self->config.selected_model);
  }
  if (active_model_index < 0 && self->models.count > 0) {
    active_model_index = 0;
  }

  if (!self->cuda_info.available) {
    status_code = WD_STATUS_CUDA_UNAVAILABLE;
  } else if (self->models.count <= 0) {
    status_code = WD_STATUS_NO_MODELS;
  } else if (active_model_index < 0 || active_model_index >= self->models.count) {
    status_code = WD_STATUS_MODEL_INDEX_INVALID;
  } else if (!self->models.is_wdgp[active_model_index]) {
    status_code = WD_STATUS_MODEL_FORMAT_UNSUPPORTED;
  } else if (!host_active || !desired_enabled) {
    status_code = WD_STATUS_WDGP_MODEL_READY;
  } else {
    if (!wd_load_wdgp_metadata(self->config.models_dir, self->models.names[active_model_index], &self->selected_model_metadata, error_message, sizeof(error_message))) {
      memset(&self->selected_model_metadata, 0, sizeof(self->selected_model_metadata));
    }
    runtime = wd_runtime_create(self, self->config.models_dir, self->models.names[active_model_index], active_model_index, effective_gpu_index, error_message, sizeof(error_message));
    if (runtime) {
      status_code = WD_STATUS_WDGP_MODEL_READY;
      self->selected_model_metadata = runtime->shared_runtime->model.metadata;
      wd_worker_publish_runtime(self, runtime);
    } else {
      status_code = wd_error_to_status_code(error_message);
    }
  }

  wd_atomic_store_int(&self->runtime_status_code, status_code);
  wd_atomic_store_int(&self->snapshot_status_code, status_code);
  wd_atomic_store_u32(&self->prepared_generation, request_generation);
}

static void*
wd_worker_main(void* opaque)
{
  WireDeckCudaDenoiser* self = (WireDeckCudaDenoiser*)opaque;
  unsigned int processed_generation = 0;
  long long observed_config_mtime = -1;

  while (!wd_atomic_load_int(&self->worker_stop)) {
    unsigned int request_generation = wd_atomic_load_u32(&self->request_generation);
    long long current_config_mtime = wd_config_mtime_seconds();

    if (observed_config_mtime == -1) {
      observed_config_mtime = current_config_mtime;
    } else if (current_config_mtime != observed_config_mtime) {
      observed_config_mtime = current_config_mtime;
      wd_request_reload(self);
      request_generation = wd_atomic_load_u32(&self->request_generation);
    }

    if (request_generation != processed_generation) {
      wd_worker_process_request(self, request_generation);
      processed_generation = request_generation;
      observed_config_mtime = self->last_config_mtime_seconds;
      wd_runtime_drain_retired(self);
      continue;
    }

    wd_runtime_drain_retired(self);
    {
      struct timespec sleep_time;
      sleep_time.tv_sec = 0;
      sleep_time.tv_nsec = 50 * 1000 * 1000;
      nanosleep(&sleep_time, NULL);
    }
  }

  wd_runtime_drain_retired(self);
  return NULL;
}

static LV2_Handle
wd_instantiate(const LV2_Descriptor* descriptor,
               double rate,
               const char* bundle_path,
               const LV2_Feature* const* features)
{
  WireDeckCudaDenoiser* self = (WireDeckCudaDenoiser*)calloc(1, sizeof(WireDeckCudaDenoiser));
  (void)descriptor;
  (void)features;

  if (!self) {
    return NULL;
  }

  wd_shared_runtime_cache_init();
  self->sample_rate_hz = rate > 1000.0 ? (unsigned int)(rate + 0.5) : 48000u;
  self->desired_model_index = -1;
  self->desired_gpu_index = 0;
  self->host_active = 0;
  self->desired_enabled = 1;
  self->snapshot_status_code = WD_STATUS_RUNTIME_NOT_IMPLEMENTED;
  if (!wd_ensure_delay_buffers(self)) {
    free(self);
    return NULL;
  }
  if (bundle_path) {
    self->bundle_path = wd_duplicate_string(bundle_path);
  }
  if (pthread_create(&self->worker_thread, NULL, wd_worker_main, self) == 0) {
    self->worker_thread_started = 1;
  } else {
    free(self->delay_left);
    free(self->delay_right);
    free(self->bundle_path);
    free(self);
    return NULL;
  }
  wd_request_reload(self);
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
  case WD_PORT_SUPPRESSED_NOISE_LEVEL:
    self->suppressed_noise_level = (float*)data;
    break;
  case WD_PORT_VOICE_PRESERVATION_LEVEL:
    self->voice_preservation_level = (float*)data;
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
  wd_atomic_store_int(&self->host_active, 1);
  wd_request_reload(self);
}

static void
wd_run(LV2_Handle instance, uint32_t sample_count)
{
  WireDeckCudaDenoiser* self = (WireDeckCudaDenoiser*)instance;
  WireDeckPluginRuntime* runtime;
  uint32_t sample_index;
  unsigned int request_generation;
  unsigned int prepared_generation;
  int status_code;
  int snapshot_status_code;
  int runtime_matches_request = 0;
  unsigned int expected_sample_rate_hz = 48000u;
  float block_input_peak = 0.0f;
  float block_output_peak = 0.0f;
  float suppressed_noise_level = 0.0f;
  float voice_preservation_level = 0.0f;
  unsigned int requested_delay_samples = 0;
  float reduction = self->threshold ? *self->threshold : 0.8f;
  float mix = self->mix ? *self->mix : 1.0f;
  float output_gain_db = self->output_gain_db ? *self->output_gain_db : 0.0f;
  float output_gain;
  int requested_model_index;
  int requested_gpu_index;

  wd_sync_requested_runtime(self);
  wd_swap_staged_runtime(self);
  runtime = wd_atomic_load_runtime((WireDeckPluginRuntime* const*)&self->current_runtime);

  request_generation = wd_atomic_load_u32(&self->request_generation);
  prepared_generation = wd_atomic_load_u32(&self->prepared_generation);
  snapshot_status_code = wd_atomic_load_int(&self->snapshot_status_code);
  requested_model_index = self->model_index ? (int)(*self->model_index + 0.5f) : -1;
  requested_gpu_index = wd_effective_gpu_index(self);

  if (!wd_atomic_load_int(&self->host_active) || !wd_effective_enabled(self)) {
    wd_release_active_runtimes(self);
    runtime = NULL;
  }

  if (runtime) {
    runtime_matches_request = runtime->model_index == requested_model_index && runtime->gpu_index == requested_gpu_index;
    if (requested_model_index < 0) {
      runtime_matches_request = runtime->gpu_index == requested_gpu_index;
    }
    expected_sample_rate_hz = runtime->sample_rate_hz > 0u ? runtime->sample_rate_hz : 48000u;
  }

  status_code = snapshot_status_code;
  if (request_generation != prepared_generation) {
    status_code = WD_STATUS_RUNTIME_NOT_IMPLEMENTED;
  } else if (runtime_matches_request && status_code == WD_STATUS_WDGP_MODEL_READY && self->sample_rate_hz != expected_sample_rate_hz) {
    status_code = WD_STATUS_SAMPLE_RATE_MISMATCH;
  }

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
  if (!self->delay_left || !self->delay_right || self->delay_capacity == 0) {
    requested_delay_samples = 0;
  }
  if (requested_delay_samples >= self->delay_capacity && self->delay_capacity > 0) {
    requested_delay_samples = self->delay_capacity - 1;
  }
  if (requested_delay_samples != self->active_delay_samples) {
    wd_reset_delay_state(self, requested_delay_samples);
  }

  if (self->cuda_available) {
    *self->cuda_available = wd_atomic_load_int(&self->snapshot_cuda_available) ? 1.0f : 0.0f;
  }
  if (self->gpu_count) {
    *self->gpu_count = (float)wd_atomic_load_int(&self->snapshot_gpu_count);
  }
  if (self->model_count) {
    *self->model_count = (float)wd_atomic_load_int(&self->snapshot_model_count);
  }
  if (self->status_code) {
    *self->status_code = (float)status_code;
  }
  if (self->model_loaded) {
    *self->model_loaded = (status_code == WD_STATUS_WDGP_MODEL_READY && runtime_matches_request) ? 1.0f : 0.0f;
  }
  if (self->runtime_phase) {
    *self->runtime_phase = (float)((status_code == WD_STATUS_WDGP_MODEL_READY && runtime_matches_request) ? WD_RUNTIME_IDLE : WD_RUNTIME_BYPASS);
  }

  if (!self->output_l || !self->output_r || !self->input_l || !self->input_r) {
    return;
  }

  for (sample_index = 0; sample_index < sample_count; ++sample_index) {
    float left = self->input_l[sample_index];
    float right = self->input_r[sample_index];
    float mono = wd_downmix_input_sample(left, right);
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
      if (status_code == WD_STATUS_WDGP_MODEL_READY && runtime_matches_request && runtime && wd_frontend_push(&runtime->frontend, mono)) {
        const float* features = wd_frontend_latest_features(&runtime->frontend);
        unsigned int request_slot = (__atomic_load_n(&runtime->inference_request_generation, __ATOMIC_RELAXED) + 1u) & 1u;
        unsigned int result_generation;
        unsigned int result_slot;
        if (self->runtime_phase) *self->runtime_phase = (float)WD_RUNTIME_RUNNING;
        memcpy(
            runtime->inference_feature_buffers[request_slot],
            features,
            (size_t)runtime->shared_runtime->backend.sequence_frames * (size_t)runtime->shared_runtime->model.metadata.bands * sizeof(float));
        __atomic_store_n(&runtime->inference_request_slot, request_slot, __ATOMIC_RELEASE);
        __atomic_add_fetch(&runtime->inference_request_generation, 1u, __ATOMIC_ACQ_REL);

        result_generation = __atomic_load_n(&runtime->inference_processed_generation, __ATOMIC_ACQUIRE);
        if (result_generation > 0u) {
          result_slot = __atomic_load_n(&runtime->inference_result_slot, __ATOMIC_ACQUIRE) & 1u;
          memcpy(
              runtime->latest_mask,
              runtime->inference_mask_buffers[result_slot],
              (size_t)runtime->shared_runtime->model.metadata.bands * sizeof(float));
          runtime->last_mask_mean = runtime->inference_mask_means[result_slot];
          runtime->last_vad = runtime->inference_vad_values[result_slot];
        }
        {
          int band_index;
          int band_count = runtime->shared_runtime->model.metadata.bands;
          for (band_index = 0; band_index < band_count; ++band_index) {
            float target = runtime->latest_mask[band_index];
            float previous = runtime->smoothed_mask ? runtime->smoothed_mask[band_index] : target;
            float smoothing = target > previous ? 0.2f : 0.95f;
            float smoothed = (smoothing * previous) + ((1.0f - smoothing) * target);
            if (runtime->smoothed_mask) {
              runtime->smoothed_mask[band_index] = smoothed;
            }
          }
          wd_frontend_apply_mask_and_synthesize(&runtime->frontend, runtime->smoothed_mask ? runtime->smoothed_mask : runtime->latest_mask, reduction);
          if (self->runtime_phase) *self->runtime_phase = (float)WD_RUNTIME_RUNNING;
        }
      }

      if (status_code == WD_STATUS_WDGP_MODEL_READY && runtime_matches_request && runtime) {
        float processed = wd_frontend_take_output_sample(&runtime->frontend);
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
  if (status_code == WD_STATUS_WDGP_MODEL_READY && runtime_matches_request && runtime) {
    float mask_keep = runtime->last_mask_mean;
    if (mask_keep < 0.0f) mask_keep = 0.0f;
    if (mask_keep > 1.0f) mask_keep = 1.0f;
    suppressed_noise_level = block_input_peak * (1.0f - mask_keep);
    /* This port is used by the UI as a mask-keep estimate. It is not a real
       voice detector, so keep it tied to the retained mask energy only. */
    voice_preservation_level = block_output_peak * mask_keep;
  }
  if (self->suppressed_noise_level) {
    *self->suppressed_noise_level = suppressed_noise_level;
  }
  if (self->voice_preservation_level) {
    *self->voice_preservation_level = voice_preservation_level;
  }
  if (self->runtime_phase && *self->runtime_phase == (float)WD_RUNTIME_RUNNING) {
    *self->runtime_phase = (float)WD_RUNTIME_IDLE;
  }
}

static void
wd_deactivate(LV2_Handle instance)
{
  WireDeckCudaDenoiser* self = (WireDeckCudaDenoiser*)instance;
  if (!self) {
    return;
  }
  wd_atomic_store_int(&self->host_active, 0);
  wd_release_active_runtimes(self);
  wd_request_reload(self);
}

static void
wd_cleanup(LV2_Handle instance)
{
  WireDeckCudaDenoiser* self = (WireDeckCudaDenoiser*)instance;
  if (!self) {
    return;
  }

  wd_atomic_store_int(&self->worker_stop, 1);
  if (self->worker_thread_started) {
    pthread_join(self->worker_thread, NULL);
  }

  wd_runtime_destroy(wd_atomic_exchange_runtime(&self->staged_runtime, NULL));
  wd_runtime_destroy(wd_atomic_exchange_runtime(&self->current_runtime, NULL));
  wd_runtime_drain_retired(self);
  wd_free_model_scan_result(&self->models);
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
