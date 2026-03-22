#include "wdgp_runtime.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void
wd_runtime_error(char* error_message, size_t error_message_size, const char* fmt, const char* value)
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
wd_read_file_range(FILE* file, unsigned char* buffer, size_t size)
{
  return fread(buffer, 1, size, file) == size;
}

static int
wd_parse_json_string_field(const char* json, const char* key, char* output, size_t output_size)
{
  char needle[128];
  const char* start;
  const char* end;
  size_t len;

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
wd_parse_json_int_field(const char* json, const char* key, int* output)
{
  char needle[128];
  const char* start;

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

static int
wd_count_tensor_entries(const char* json)
{
  int count = 0;
  const char* cursor = json;
  while ((cursor = strstr(cursor, "\"name\"")) != NULL) {
    ++count;
    cursor += 6;
  }
  return count;
}

static int
wd_parse_tensor_table(const char* json, WireDeckWdgpTensorInfo* tensors, int tensor_count)
{
  const char* cursor = json;
  int index;

  for (index = 0; index < tensor_count; ++index) {
    const char* object_start;
    const char* object_end;
    char chunk[2048];
    size_t len;
    int parsed_value;

    object_start = strchr(cursor, '{');
    if (!object_start) {
      return 0;
    }
    object_end = strchr(object_start, '}');
    if (!object_end) {
      return 0;
    }
    len = (size_t)(object_end - object_start + 1);
    if (len >= sizeof(chunk)) {
      len = sizeof(chunk) - 1;
    }
    memcpy(chunk, object_start, len);
    chunk[len] = '\0';

    memset(&tensors[index], 0, sizeof(tensors[index]));
    if (!wd_parse_json_string_field(chunk, "name", tensors[index].name, sizeof(tensors[index].name))) {
      return 0;
    }
    if (!wd_parse_json_int_field(chunk, "dtype_code", &parsed_value)) {
      return 0;
    }
    tensors[index].dtype_code = parsed_value;
    if (!wd_parse_json_int_field(chunk, "offset", &parsed_value)) {
      return 0;
    }
    tensors[index].offset = (size_t)parsed_value;
    if (!wd_parse_json_int_field(chunk, "byte_length", &parsed_value)) {
      return 0;
    }
    tensors[index].byte_length = (size_t)parsed_value;

    {
      const char* shape = strstr(chunk, "\"shape\"");
      const char* open = shape ? strchr(shape, '[') : NULL;
      const char* close = open ? strchr(open, ']') : NULL;
      const char* item = open;
      int rank = 0;
      if (!open || !close) {
        return 0;
      }
      ++item;
      while (item < close && rank < 4) {
        while (item < close && (*item == ' ' || *item == ',')) {
          ++item;
        }
        if (item >= close) {
          break;
        }
        tensors[index].dims[rank] = atoi(item);
        ++rank;
        while (item < close && *item != ',') {
          ++item;
        }
      }
      tensors[index].rank = rank;
    }

    cursor = object_end + 1;
  }

  return 1;
}

void
wd_wdgp_model_init(WireDeckWdgpModel* model)
{
  if (!model) {
    return;
  }
  memset(model, 0, sizeof(*model));
}

void
wd_wdgp_model_deinit(WireDeckWdgpModel* model)
{
  if (!model) {
    return;
  }
  free(model->tensors);
  free(model->payload);
  memset(model, 0, sizeof(*model));
}

const WireDeckWdgpTensorInfo*
wd_wdgp_find_tensor(const WireDeckWdgpModel* model, const char* name)
{
  int index;
  if (!model || !name) {
    return NULL;
  }
  for (index = 0; index < model->tensor_count; ++index) {
    if (strcmp(model->tensors[index].name, name) == 0) {
      return &model->tensors[index];
    }
  }
  return NULL;
}

int
wd_wdgp_validate_architecture(const WireDeckWdgpModel* model, char* error_message, size_t error_message_size)
{
  char tensor_name[96];
  int block_index;
  const WireDeckWdgpTensorInfo* vad_head0_weight;
  const WireDeckWdgpTensorInfo* vad_head0_bias;
  const WireDeckWdgpTensorInfo* vad_head2_weight;
  const WireDeckWdgpTensorInfo* vad_head2_bias;

  if (!model) {
    wd_runtime_error(error_message, error_message_size, "missing model", NULL);
    return 0;
  }

  if (!wd_wdgp_find_tensor(model, "input_proj.weight") || !wd_wdgp_find_tensor(model, "input_proj.bias")) {
    wd_runtime_error(error_message, error_message_size, "missing input projection tensors", NULL);
    return 0;
  }

  for (block_index = 0; block_index < model->metadata.residual_blocks; ++block_index) {
    snprintf(tensor_name, sizeof(tensor_name), "blocks.%d.conv1.weight", block_index);
    if (!wd_wdgp_find_tensor(model, tensor_name)) {
      wd_runtime_error(error_message, error_message_size, "missing tensor: %s", tensor_name);
      return 0;
    }
    snprintf(tensor_name, sizeof(tensor_name), "blocks.%d.conv2.weight", block_index);
    if (!wd_wdgp_find_tensor(model, tensor_name)) {
      wd_runtime_error(error_message, error_message_size, "missing tensor: %s", tensor_name);
      return 0;
    }
  }

  if (!wd_wdgp_find_tensor(model, "bottleneck.2.weight") ||
      !wd_wdgp_find_tensor(model, "bottleneck.4.weight") ||
      !wd_wdgp_find_tensor(model, "mask_head.2.weight")) {
    wd_runtime_error(error_message, error_message_size, "missing head or bottleneck tensors", NULL);
    return 0;
  }

  vad_head0_weight = wd_wdgp_find_tensor(model, "vad_head.0.weight");
  vad_head0_bias = wd_wdgp_find_tensor(model, "vad_head.0.bias");
  vad_head2_weight = wd_wdgp_find_tensor(model, "vad_head.2.weight");
  vad_head2_bias = wd_wdgp_find_tensor(model, "vad_head.2.bias");
  if (!vad_head0_weight || !vad_head0_bias || !vad_head2_weight || !vad_head2_bias) {
    wd_runtime_error(error_message, error_message_size, "missing latest VAD head tensors", NULL);
    return 0;
  }
  if (vad_head0_weight->rank != 3 || vad_head0_bias->rank != 1 || vad_head2_weight->rank != 3 || vad_head2_bias->rank != 1) {
    wd_runtime_error(error_message, error_message_size, "unsupported WDGP architecture: legacy VAD head is no longer supported", NULL);
    return 0;
  }

  return 1;
}

int
wd_wdgp_model_load(const char* models_dir, const char* file_name, WireDeckWdgpModel* out_model, char* error_message, size_t error_message_size)
{
  char expanded_dir[WD_MODELS_DIR_CAP];
  char path[WD_CONFIG_PATH_CAP];
  FILE* file;
  unsigned char header[20];
  unsigned int metadata_size;
  unsigned int tensor_table_size;
  unsigned int tensor_count_header;
  char* metadata_json;
  char* tensor_json;
  long payload_start;
  long file_end;
  int tensor_count;

  if (!models_dir || !file_name || !out_model) {
    wd_runtime_error(error_message, error_message_size, "invalid model load args", NULL);
    return 0;
  }

  wd_wdgp_model_init(out_model);

  if (!wd_expand_home_path(models_dir, expanded_dir, sizeof(expanded_dir))) {
    wd_runtime_error(error_message, error_message_size, "could not expand model dir", NULL);
    return 0;
  }

  snprintf(path, sizeof(path), "%s/%s", expanded_dir, file_name);
  file = fopen(path, "rb");
  if (!file) {
    wd_runtime_error(error_message, error_message_size, "could not open model: %s", strerror(errno));
    return 0;
  }

  if (!wd_read_file_range(file, header, sizeof(header))) {
    fclose(file);
    wd_runtime_error(error_message, error_message_size, "could not read model header", NULL);
    return 0;
  }
  if (memcmp(header, "WDGP", 4) != 0) {
    fclose(file);
    wd_runtime_error(error_message, error_message_size, "model is not WDGP", NULL);
    return 0;
  }

  tensor_count_header = (unsigned int)header[8] | ((unsigned int)header[9] << 8) | ((unsigned int)header[10] << 16) | ((unsigned int)header[11] << 24);
  metadata_size = (unsigned int)header[12] | ((unsigned int)header[13] << 8) | ((unsigned int)header[14] << 16) | ((unsigned int)header[15] << 24);
  tensor_table_size = (unsigned int)header[16] | ((unsigned int)header[17] << 8) | ((unsigned int)header[18] << 16) | ((unsigned int)header[19] << 24);

  metadata_json = (char*)malloc((size_t)metadata_size + 1);
  tensor_json = (char*)malloc((size_t)tensor_table_size + 1);
  if (!metadata_json || !tensor_json) {
    fclose(file);
    free(metadata_json);
    free(tensor_json);
    wd_runtime_error(error_message, error_message_size, "out of memory", NULL);
    return 0;
  }

  if (!wd_read_file_range(file, (unsigned char*)metadata_json, metadata_size) ||
      !wd_read_file_range(file, (unsigned char*)tensor_json, tensor_table_size)) {
    fclose(file);
    free(metadata_json);
    free(tensor_json);
    wd_runtime_error(error_message, error_message_size, "could not read model json", NULL);
    return 0;
  }
  metadata_json[metadata_size] = '\0';
  tensor_json[tensor_table_size] = '\0';

  if (!wd_load_wdgp_metadata(models_dir, file_name, &out_model->metadata, error_message, error_message_size)) {
    fclose(file);
    free(metadata_json);
    free(tensor_json);
    return 0;
  }

  tensor_count = wd_count_tensor_entries(tensor_json);
  if (tensor_count <= 0 || (unsigned int)tensor_count != tensor_count_header) {
    fclose(file);
    free(metadata_json);
    free(tensor_json);
    wd_runtime_error(error_message, error_message_size, "tensor table count mismatch", NULL);
    return 0;
  }

  out_model->tensors = (WireDeckWdgpTensorInfo*)calloc((size_t)tensor_count, sizeof(WireDeckWdgpTensorInfo));
  if (!out_model->tensors) {
    fclose(file);
    free(metadata_json);
    free(tensor_json);
    wd_runtime_error(error_message, error_message_size, "out of memory", NULL);
    return 0;
  }
  out_model->tensor_count = tensor_count;
  if (!wd_parse_tensor_table(tensor_json, out_model->tensors, tensor_count)) {
    fclose(file);
    free(metadata_json);
    free(tensor_json);
    wd_runtime_error(error_message, error_message_size, "could not parse tensor table", NULL);
    wd_wdgp_model_deinit(out_model);
    return 0;
  }

  payload_start = ftell(file);
  if (payload_start < 0) {
    fclose(file);
    free(metadata_json);
    free(tensor_json);
    wd_runtime_error(error_message, error_message_size, "invalid model payload offset", NULL);
    wd_wdgp_model_deinit(out_model);
    return 0;
  }
  while ((payload_start % 16) != 0) {
    if (fgetc(file) == EOF) {
      fclose(file);
      free(metadata_json);
      free(tensor_json);
      wd_runtime_error(error_message, error_message_size, "invalid alignment padding", NULL);
      wd_wdgp_model_deinit(out_model);
      return 0;
    }
    ++payload_start;
  }

  if (fseek(file, 0, SEEK_END) != 0) {
    fclose(file);
    free(metadata_json);
    free(tensor_json);
    wd_runtime_error(error_message, error_message_size, "could not seek model end", NULL);
    wd_wdgp_model_deinit(out_model);
    return 0;
  }
  file_end = ftell(file);
  if (file_end < payload_start) {
    fclose(file);
    free(metadata_json);
    free(tensor_json);
    wd_runtime_error(error_message, error_message_size, "invalid model payload size", NULL);
    wd_wdgp_model_deinit(out_model);
    return 0;
  }

  out_model->payload_size = (size_t)(file_end - payload_start);
  out_model->payload = (unsigned char*)malloc(out_model->payload_size);
  if (!out_model->payload) {
    fclose(file);
    free(metadata_json);
    free(tensor_json);
    wd_runtime_error(error_message, error_message_size, "out of memory", NULL);
    wd_wdgp_model_deinit(out_model);
    return 0;
  }
  if (fseek(file, payload_start, SEEK_SET) != 0 || !wd_read_file_range(file, out_model->payload, out_model->payload_size)) {
    fclose(file);
    free(metadata_json);
    free(tensor_json);
    wd_runtime_error(error_message, error_message_size, "could not read model payload", NULL);
    wd_wdgp_model_deinit(out_model);
    return 0;
  }
  fclose(file);
  free(metadata_json);
  free(tensor_json);

  out_model->architecture_valid = wd_wdgp_validate_architecture(out_model, error_message, error_message_size);
  if (!out_model->architecture_valid) {
    wd_wdgp_model_deinit(out_model);
    return 0;
  }
  return 1;
}
