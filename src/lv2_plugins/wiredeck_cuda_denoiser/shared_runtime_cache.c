#include "shared_runtime_cache.h"
#include "config_store.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static pthread_mutex_t wd_cache_mutex = PTHREAD_MUTEX_INITIALIZER;
static WireDeckSharedRuntimeEntry* wd_cache_head = NULL;

static char*
wd_cache_strdup(const char* input)
{
  size_t len;
  char* copy;
  if (!input) return NULL;
  len = strlen(input);
  copy = (char*)malloc(len + 1);
  if (!copy) return NULL;
  memcpy(copy, input, len + 1);
  return copy;
}

static void
wd_cache_error(char* error_message, size_t error_message_size, const char* fmt, const char* value)
{
  if (!error_message || error_message_size == 0) return;
  snprintf(error_message, error_message_size, fmt ? fmt : "%s", value ? value : "");
}

static int
wd_resolve_model_path(const char* models_dir, const char* model_file_name, char* output, size_t output_size)
{
  char expanded_dir[WD_MODELS_DIR_CAP];
  if (!wd_expand_home_path(models_dir, expanded_dir, sizeof(expanded_dir))) return 0;
  snprintf(output, output_size, "%s/%s", expanded_dir, model_file_name);
  return 1;
}

void
wd_shared_runtime_cache_init(void)
{
}

void
wd_shared_runtime_cache_shutdown(void)
{
  pthread_mutex_lock(&wd_cache_mutex);
  while (wd_cache_head) {
    WireDeckSharedRuntimeEntry* next = wd_cache_head->next;
    wd_cuda_backend_deinit(&wd_cache_head->backend, &wd_cache_head->session);
    wd_cuda_session_deinit(&wd_cache_head->session);
    wd_wdgp_model_deinit(&wd_cache_head->model);
    free(wd_cache_head->model_path);
    free(wd_cache_head);
    wd_cache_head = next;
  }
  pthread_mutex_unlock(&wd_cache_mutex);
}

WireDeckSharedRuntimeEntry*
wd_shared_runtime_cache_acquire(
    const char* models_dir,
    const char* model_file_name,
    int gpu_index,
    const char* bundle_path,
    char* error_message,
    size_t error_message_size)
{
  char model_path[WD_CONFIG_PATH_CAP];
  WireDeckSharedRuntimeEntry* entry;

  if (!wd_resolve_model_path(models_dir, model_file_name, model_path, sizeof(model_path))) {
    wd_cache_error(error_message, error_message_size, "could not resolve model path", NULL);
    fprintf(stderr, "[wiredeck-cuda-denoiser] acquire failed: could not resolve model path\n");
    return NULL;
  }

  pthread_mutex_lock(&wd_cache_mutex);
  for (entry = wd_cache_head; entry != NULL; entry = entry->next) {
    if (entry->gpu_index == gpu_index && strcmp(entry->model_path, model_path) == 0) {
      entry->ref_count += 1;
      pthread_mutex_unlock(&wd_cache_mutex);
      if (error_message && error_message_size > 0) error_message[0] = '\0';
      return entry;
    }
  }
  pthread_mutex_unlock(&wd_cache_mutex);

  entry = (WireDeckSharedRuntimeEntry*)calloc(1, sizeof(WireDeckSharedRuntimeEntry));
  if (!entry) {
    wd_cache_error(error_message, error_message_size, "out of memory", NULL);
    fprintf(stderr, "[wiredeck-cuda-denoiser] acquire failed: out of memory\n");
    return NULL;
  }
  entry->model_path = wd_cache_strdup(model_path);
  entry->gpu_index = gpu_index;
  entry->ref_count = 1;
  wd_wdgp_model_init(&entry->model);
  wd_cuda_session_init(&entry->session);
  wd_cuda_backend_init(&entry->backend);

  if (!entry->model_path ||
      !wd_wdgp_model_load(models_dir, model_file_name, &entry->model, error_message, error_message_size) ||
      !wd_cuda_session_open(&entry->session, gpu_index, error_message, error_message_size) ||
      !wd_cuda_backend_prepare(&entry->backend, &entry->session, &entry->model, bundle_path, models_dir, error_message, error_message_size)) {
    fprintf(stderr, "[wiredeck-cuda-denoiser] acquire failed for model=%s gpu=%d: %s\n", model_file_name, gpu_index, error_message[0] ? error_message : "unknown");
    wd_cuda_backend_deinit(&entry->backend, &entry->session);
    wd_cuda_session_deinit(&entry->session);
    wd_wdgp_model_deinit(&entry->model);
    free(entry->model_path);
    free(entry);
    return NULL;
  }

  pthread_mutex_lock(&wd_cache_mutex);
  entry->next = wd_cache_head;
  wd_cache_head = entry;
  pthread_mutex_unlock(&wd_cache_mutex);
  fprintf(stderr, "[wiredeck-cuda-denoiser] acquired model=%s gpu=%d refcount=%d\n", model_file_name, gpu_index, entry->ref_count);
  if (error_message && error_message_size > 0) error_message[0] = '\0';
  return entry;
}

void
wd_shared_runtime_cache_release(WireDeckSharedRuntimeEntry* entry)
{
  WireDeckSharedRuntimeEntry** link;
  if (!entry) return;

  pthread_mutex_lock(&wd_cache_mutex);
  entry->ref_count -= 1;
  if (entry->ref_count > 0) {
    fprintf(stderr, "[wiredeck-cuda-denoiser] released shared runtime model=%s gpu=%d refcount=%d\n", entry->model_path, entry->gpu_index, entry->ref_count);
    pthread_mutex_unlock(&wd_cache_mutex);
    return;
  }

  link = &wd_cache_head;
  while (*link && *link != entry) link = &(*link)->next;
  if (*link == entry) *link = entry->next;
  pthread_mutex_unlock(&wd_cache_mutex);

  wd_cuda_backend_deinit(&entry->backend, &entry->session);
  wd_cuda_session_deinit(&entry->session);
  wd_wdgp_model_deinit(&entry->model);
  fprintf(stderr, "[wiredeck-cuda-denoiser] destroyed shared runtime model=%s gpu=%d\n", entry->model_path, entry->gpu_index);
  free(entry->model_path);
  free(entry);
}
