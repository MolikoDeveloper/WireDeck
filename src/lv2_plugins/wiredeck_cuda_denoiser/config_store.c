#include "config_store.h"
#include "wiredeck_cuda_denoiser_shared.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static int
wd_extract_json_string(const char* json, const char* key, char* output, size_t output_size)
{
  char needle[128];
  const char* start;
  const char* end;
  size_t len;

  if (!json || !key || !output || output_size == 0) {
    return 0;
  }

  snprintf(needle, sizeof(needle), "\"%s\"", key);
  start = strstr(json, needle);
  if (!start) {
    return 0;
  }

  start = strchr(start + strlen(needle), ':');
  if (!start) {
    return 0;
  }
  start = strchr(start, '"');
  if (!start) {
    return 0;
  }
  ++start;
  end = strchr(start, '"');
  if (!end) {
    return 0;
  }

  len = (size_t)(end - start);
  if (len >= output_size) {
    len = output_size - 1;
  }
  memcpy(output, start, len);
  output[len] = '\0';
  return 1;
}

static int
wd_extract_json_int(const char* json, const char* key, int* output)
{
  char needle[128];
  const char* start;
  if (!json || !key || !output) {
    return 0;
  }

  snprintf(needle, sizeof(needle), "\"%s\"", key);
  start = strstr(json, needle);
  if (!start) {
    return 0;
  }
  start = strchr(start + strlen(needle), ':');
  if (!start) {
    return 0;
  }
  ++start;
  while (*start == ' ' || *start == '\n' || *start == '\r' || *start == '\t') {
    ++start;
  }
  *output = atoi(start);
  return 1;
}

static void
wd_write_error(char* error_message, size_t error_message_size, const char* fmt, const char* value)
{
  if (!error_message || error_message_size == 0) {
    return;
  }

  if (!fmt) {
    error_message[0] = '\0';
    return;
  }

  snprintf(error_message, error_message_size, fmt, value ? value : "");
}

static int
wd_has_bin_extension(const char* name)
{
  size_t len;
  if (!name) {
    return 0;
  }
  len = strlen(name);
  return len > 4 && strcmp(name + len - 4, ".bin") == 0;
}

static char*
wd_string_duplicate(const char* input)
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
wd_compare_strings(const void* lhs, const void* rhs)
{
  const char* const* lhs_string = (const char* const*)lhs;
  const char* const* rhs_string = (const char* const*)rhs;
  return strcmp(*lhs_string, *rhs_string);
}

static char*
wd_trim(char* text)
{
  char* end;
  while (*text != '\0' && isspace((unsigned char)*text)) {
    ++text;
  }
  end = text + strlen(text);
  while (end > text && isspace((unsigned char)end[-1])) {
    --end;
  }
  *end = '\0';
  return text;
}

static int
wd_read_model_magic(const char* models_dir, const char* file_name)
{
  char path[WD_CONFIG_PATH_CAP];
  FILE* file;
  char magic[4];

  snprintf(path, sizeof(path), "%s/%s", models_dir, file_name);
  file = fopen(path, "rb");
  if (!file) {
    return 0;
  }

  if (fread(magic, 1, sizeof(magic), file) != sizeof(magic)) {
    fclose(file);
    return 0;
  }

  fclose(file);
  return memcmp(magic, "WDGP", 4) == 0;
}

int
wd_expand_home_path(const char* input, char* output, size_t output_size)
{
  const char* home;

  if (!input || !output || output_size == 0) {
    return 0;
  }

  if (input[0] == '~' && input[1] == '/') {
    home = getenv("HOME");
    if (!home || home[0] == '\0') {
      return 0;
    }
    snprintf(output, output_size, "%s/%s", home, input + 2);
    return 1;
  }

  snprintf(output, output_size, "%s", input);
  return 1;
}

int
wd_config_resolve_path(char* out_path, size_t out_path_size)
{
  return wd_expand_home_path(WIREDECK_CUDA_DENOISER_CONFIG_PATH, out_path, out_path_size);
}

long long
wd_config_mtime_seconds(void)
{
  char config_path[WD_CONFIG_PATH_CAP];
  struct stat st;
  if (!wd_config_resolve_path(config_path, sizeof(config_path))) {
    return 0;
  }
  if (stat(config_path, &st) != 0) {
    return 0;
  }
  return (long long)st.st_mtime;
}

void
wd_config_init_defaults(WireDeckCudaDenoiserConfig* config)
{
  if (!config) {
    return;
  }

  memset(config, 0, sizeof(*config));
  snprintf(config->models_dir, sizeof(config->models_dir), "%s", WIREDECK_CUDA_DENOISER_DEFAULT_MODELS_DIR);
}

int
wd_config_load(WireDeckCudaDenoiserConfig* config, char* error_message, size_t error_message_size)
{
  char config_path[WD_CONFIG_PATH_CAP];
  FILE* file;
  char line[2048];

  if (!config) {
    return 0;
  }

  wd_config_init_defaults(config);

  if (!wd_config_resolve_path(config_path, sizeof(config_path))) {
    wd_write_error(error_message, error_message_size, "could not resolve config path", NULL);
    return 0;
  }

  file = fopen(config_path, "r");
  if (!file) {
    return 0;
  }

  while (fgets(line, sizeof(line), file)) {
    char* equal_sign;
    char* key;
    char* value;

    key = wd_trim(line);
    if (key[0] == '\0' || key[0] == '#') {
      continue;
    }

    equal_sign = strchr(key, '=');
    if (!equal_sign) {
      continue;
    }

    *equal_sign = '\0';
    value = wd_trim(equal_sign + 1);
    key = wd_trim(key);

    if (strcmp(key, "models_dir") == 0) {
      snprintf(config->models_dir, sizeof(config->models_dir), "%s", value);
    } else if (strcmp(key, "selected_model") == 0) {
      snprintf(config->selected_model, sizeof(config->selected_model), "%s", value);
    }
  }

  fclose(file);
  return 1;
}

int
wd_config_save(const WireDeckCudaDenoiserConfig* config, char* error_message, size_t error_message_size)
{
  char config_path[WD_CONFIG_PATH_CAP];
  char config_dir[WD_CONFIG_PATH_CAP];
  char* slash;
  FILE* file;

  if (!config) {
    return 0;
  }

  if (!wd_config_resolve_path(config_path, sizeof(config_path))) {
    wd_write_error(error_message, error_message_size, "could not resolve config path", NULL);
    return 0;
  }

  snprintf(config_dir, sizeof(config_dir), "%s", config_path);
  slash = strrchr(config_dir, '/');
  if (!slash) {
    wd_write_error(error_message, error_message_size, "invalid config path", NULL);
    return 0;
  }
  *slash = '\0';

  if (mkdir(config_dir, 0755) != 0 && errno != EEXIST) {
    char parent_dir[WD_CONFIG_PATH_CAP];
    char* parent_slash;
    snprintf(parent_dir, sizeof(parent_dir), "%s", config_dir);
    parent_slash = strrchr(parent_dir, '/');
    if (parent_slash) {
      *parent_slash = '\0';
      if (mkdir(parent_dir, 0755) != 0 && errno != EEXIST) {
        wd_write_error(error_message, error_message_size, "could not create config directory: %s", strerror(errno));
        return 0;
      }
      if (mkdir(config_dir, 0755) != 0 && errno != EEXIST) {
        wd_write_error(error_message, error_message_size, "could not create config directory: %s", strerror(errno));
        return 0;
      }
    }
  }

  file = fopen(config_path, "w");
  if (!file) {
    wd_write_error(error_message, error_message_size, "could not open config file: %s", strerror(errno));
    return 0;
  }

  fprintf(file, "models_dir=%s\n", config->models_dir);
  fprintf(file, "selected_model=%s\n", config->selected_model);
  fclose(file);
  return 1;
}

int
wd_scan_models(const char* models_dir, WireDeckModelScanResult* out_result, char* error_message, size_t error_message_size)
{
  DIR* dir;
  struct dirent* entry;
  char expanded_dir[WD_MODELS_DIR_CAP];
  char** names = NULL;
  int capacity = 0;
  int count = 0;
  int* is_wdgp = NULL;
  int index;

  if (!out_result) {
    return 0;
  }

  memset(out_result, 0, sizeof(*out_result));

  if (!wd_expand_home_path(models_dir, expanded_dir, sizeof(expanded_dir))) {
    wd_write_error(error_message, error_message_size, "could not expand models dir", NULL);
    return 0;
  }

  dir = opendir(expanded_dir);
  if (!dir) {
    wd_write_error(error_message, error_message_size, "could not open models dir: %s", strerror(errno));
    return 0;
  }

  while ((entry = readdir(dir)) != NULL) {
    char* owned_name;

    if (entry->d_name[0] == '.') {
      continue;
    }
    if (!wd_has_bin_extension(entry->d_name)) {
      continue;
    }

    if (count == capacity) {
      int new_capacity = capacity == 0 ? 8 : capacity * 2;
      char** new_names = (char**)realloc(names, sizeof(char*) * (size_t)new_capacity);
      if (!new_names) {
        closedir(dir);
        wd_write_error(error_message, error_message_size, "out of memory", NULL);
        goto fail;
      }
      names = new_names;
      capacity = new_capacity;
    }

    owned_name = wd_string_duplicate(entry->d_name);
    if (!owned_name) {
      closedir(dir);
      wd_write_error(error_message, error_message_size, "out of memory", NULL);
      goto fail;
    }

    names[count] = owned_name;
    ++count;
  }

  closedir(dir);
  qsort(names, (size_t)count, sizeof(char*), wd_compare_strings);

  if (count > 0) {
    is_wdgp = (int*)calloc((size_t)count, sizeof(int));
    if (!is_wdgp) {
      wd_write_error(error_message, error_message_size, "out of memory", NULL);
      goto fail;
    }
    for (index = 0; index < count; ++index) {
      is_wdgp[index] = wd_read_model_magic(expanded_dir, names[index]);
    }
  }

  out_result->names = names;
  out_result->is_wdgp = is_wdgp;
  out_result->count = count;
  return 1;

fail:
  if (names) {
    for (index = 0; index < count; ++index) {
      free(names[index]);
    }
    free(names);
  }
  free(is_wdgp);
  return 0;
}

void
wd_free_model_scan_result(WireDeckModelScanResult* result)
{
  int index;
  if (!result) {
    return;
  }
  for (index = 0; index < result->count; ++index) {
    free(result->names[index]);
  }
  free(result->names);
  free(result->is_wdgp);
  memset(result, 0, sizeof(*result));
}

int
wd_find_model_index(const WireDeckModelScanResult* result, const char* model_name)
{
  int index;
  if (!result || !model_name || model_name[0] == '\0') {
    return -1;
  }
  for (index = 0; index < result->count; ++index) {
    if (strcmp(result->names[index], model_name) == 0) {
      return index;
    }
  }
  return -1;
}

const char*
wd_status_code_label(int status_code)
{
  switch (status_code) {
  case WD_STATUS_CUDA_READY:
    return "CUDA runtime ready";
  case WD_STATUS_CUDA_UNAVAILABLE:
    return "CUDA unavailable";
  case WD_STATUS_NO_MODELS:
    return "No models found";
  case WD_STATUS_MODEL_INDEX_INVALID:
    return "Selected model index is invalid";
  case WD_STATUS_MODEL_FORMAT_UNSUPPORTED:
    return "Model format is not WDGP";
  case WD_STATUS_RUNTIME_NOT_IMPLEMENTED:
    return "WDGP model detected, CUDA runtime pending";
  case WD_STATUS_GPU_INDEX_INVALID:
    return "Selected GPU index is invalid";
  case WD_STATUS_MODEL_LOAD_FAILED:
    return "Could not load WDGP model";
  case WD_STATUS_CUDA_CONTEXT_FAILED:
    return "Could not create CUDA context";
  case WD_STATUS_WDGP_MODEL_READY:
    return "WDGP model and CUDA context ready";
  case WD_STATUS_KERNELS_MISSING:
    return "CUDA kernels missing";
  case WD_STATUS_KERNEL_LOAD_FAILED:
    return "Could not load CUDA kernels";
  case WD_STATUS_WEIGHTS_UPLOAD_FAILED:
    return "Could not upload model weights";
  case WD_STATUS_SAMPLE_RATE_MISMATCH:
    return "Host sample rate does not match model sample rate";
  default:
    return "Unknown status";
  }
}

int
wd_load_wdgp_metadata(const char* models_dir, const char* file_name, WireDeckWdgpMetadata* out_metadata, char* error_message, size_t error_message_size)
{
  char expanded_dir[WD_MODELS_DIR_CAP];
  char path[WD_CONFIG_PATH_CAP];
  unsigned char header[20];
  FILE* file;
  unsigned int version;
  unsigned int tensor_count;
  unsigned int metadata_size;
  unsigned int tensor_table_size;
  char* metadata_json;
  size_t read_count;

  if (!models_dir || !file_name || !out_metadata) {
    wd_write_error(error_message, error_message_size, "invalid metadata arguments", NULL);
    return 0;
  }

  memset(out_metadata, 0, sizeof(*out_metadata));

  if (!wd_expand_home_path(models_dir, expanded_dir, sizeof(expanded_dir))) {
    wd_write_error(error_message, error_message_size, "could not expand models dir", NULL);
    return 0;
  }

  snprintf(path, sizeof(path), "%s/%s", expanded_dir, file_name);
  file = fopen(path, "rb");
  if (!file) {
    wd_write_error(error_message, error_message_size, "could not open model: %s", strerror(errno));
    return 0;
  }

  if (fread(header, 1, sizeof(header), file) != sizeof(header)) {
    fclose(file);
    wd_write_error(error_message, error_message_size, "could not read model header", NULL);
    return 0;
  }

  if (memcmp(header, "WDGP", 4) != 0) {
    fclose(file);
    wd_write_error(error_message, error_message_size, "model is not WDGP", NULL);
    return 0;
  }

  version = (unsigned int)header[4] | ((unsigned int)header[5] << 8) | ((unsigned int)header[6] << 16) | ((unsigned int)header[7] << 24);
  tensor_count = (unsigned int)header[8] | ((unsigned int)header[9] << 8) | ((unsigned int)header[10] << 16) | ((unsigned int)header[11] << 24);
  metadata_size = (unsigned int)header[12] | ((unsigned int)header[13] << 8) | ((unsigned int)header[14] << 16) | ((unsigned int)header[15] << 24);
  tensor_table_size = (unsigned int)header[16] | ((unsigned int)header[17] << 8) | ((unsigned int)header[18] << 16) | ((unsigned int)header[19] << 24);
  (void)tensor_table_size;

  metadata_json = (char*)malloc((size_t)metadata_size + 1);
  if (!metadata_json) {
    fclose(file);
    wd_write_error(error_message, error_message_size, "out of memory", NULL);
    return 0;
  }

  read_count = fread(metadata_json, 1, metadata_size, file);
  fclose(file);
  if (read_count != metadata_size) {
    free(metadata_json);
    wd_write_error(error_message, error_message_size, "could not read model metadata", NULL);
    return 0;
  }
  metadata_json[metadata_size] = '\0';

  out_metadata->valid = version == 1;
  out_metadata->tensor_count = (int)tensor_count;
  wd_extract_json_string(metadata_json, "model_name", out_metadata->model_name, sizeof(out_metadata->model_name));
  wd_extract_json_string(metadata_json, "export_format", out_metadata->export_format, sizeof(out_metadata->export_format));
  wd_extract_json_int(metadata_json, "sample_rate_hz", &out_metadata->sample_rate_hz);
  wd_extract_json_int(metadata_json, "stft_size", &out_metadata->stft_size);
  wd_extract_json_int(metadata_json, "hop_size", &out_metadata->hop_size);
  wd_extract_json_int(metadata_json, "bands", &out_metadata->bands);
  wd_extract_json_int(metadata_json, "channels", &out_metadata->channels);
  wd_extract_json_int(metadata_json, "hidden_channels", &out_metadata->hidden_channels);
  wd_extract_json_int(metadata_json, "residual_blocks", &out_metadata->residual_blocks);
  wd_extract_json_int(metadata_json, "kernel_time", &out_metadata->kernel_time);
  wd_extract_json_int(metadata_json, "kernel_freq", &out_metadata->kernel_freq);
  wd_extract_json_int(metadata_json, "lookahead_frames", &out_metadata->lookahead_frames);
  free(metadata_json);

  if (!out_metadata->valid) {
    wd_write_error(error_message, error_message_size, "unsupported WDGP version", NULL);
    return 0;
  }

  return 1;
}
