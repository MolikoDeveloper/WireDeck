#include "cuda_backend.h"
#include "config_store.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int CUresult;
typedef unsigned long long CUdeviceptr;

#define CUDA_SUCCESS 0

typedef CUresult (*WdCuModuleLoadDataExFn)(void** module, const void* image, unsigned int numOptions, void* options, void* optionValues);
typedef CUresult (*WdCuModuleGetFunctionFn)(void** hfunc, void* hmod, const char* name);
typedef CUresult (*WdCuMemAllocFn)(CUdeviceptr* dptr, size_t bytesize);
typedef CUresult (*WdCuMemFreeFn)(CUdeviceptr dptr);
typedef CUresult (*WdCuMemcpyHtoDFn)(CUdeviceptr dstDevice, const void* srcHost, size_t ByteCount);
typedef CUresult (*WdCuMemcpyDtoHFn)(void* dstHost, CUdeviceptr srcDevice, size_t ByteCount);
typedef CUresult (*WdCuLaunchKernelFn)(void* f, unsigned int gridDimX, unsigned int gridDimY, unsigned int gridDimZ, unsigned int blockDimX, unsigned int blockDimY, unsigned int blockDimZ, unsigned int sharedMemBytes, void* hStream, void** kernelParams, void** extra);

static const char* const wd_kernel_file_names[WD_CUDA_KERNEL_COUNT] = {
  "input_projection.ptx",
  "conv2d_same_cfb.ptx",
  "groupnorm_silu_cfb.ptx",
  "add_tensors_cfb.ptx",
  "silu_cfb.ptx",
  "sigmoid_cfb.ptx",
  "mean_over_bands_cf.ptx",
};

static const char* const wd_kernel_symbol_names[WD_CUDA_KERNEL_COUNT] = {
  "input_projection",
  "conv2d_same_cfb",
  "groupnorm_silu_cfb",
  "add_tensors_cfb",
  "silu_cfb",
  "sigmoid_cfb",
  "mean_over_bands_cf",
};

static void
wd_backend_error(char* error_message, size_t error_message_size, const char* fmt, const char* value)
{
  if (!error_message || error_message_size == 0) {
    return;
  }
  snprintf(error_message, error_message_size, fmt ? fmt : "%s", value ? value : "");
}

static const WireDeckCudaWeightBuffer*
wd_find_weight_buffer(const WireDeckCudaBackend* backend, const char* name)
{
  int index;
  if (!backend || !name) {
    return NULL;
  }
  for (index = 0; index < backend->weight_count; ++index) {
    if (strcmp(backend->weights[index].name, name) == 0) {
      return &backend->weights[index];
    }
  }
  return NULL;
}

static unsigned char*
wd_read_file_bytes(const char* path, size_t* out_size)
{
  FILE* file;
  long file_size;
  unsigned char* bytes;

  *out_size = 0;
  file = fopen(path, "rb");
  if (!file) {
    return NULL;
  }
  if (fseek(file, 0, SEEK_END) != 0) {
    fclose(file);
    return NULL;
  }
  file_size = ftell(file);
  if (file_size <= 0 || fseek(file, 0, SEEK_SET) != 0) {
    fclose(file);
    return NULL;
  }
  bytes = (unsigned char*)malloc((size_t)file_size + 1);
  if (!bytes) {
    fclose(file);
    return NULL;
  }
  if (fread(bytes, 1, (size_t)file_size, file) != (size_t)file_size) {
    fclose(file);
    free(bytes);
    return NULL;
  }
  fclose(file);
  bytes[file_size] = '\0';
  *out_size = (size_t)file_size;
  return bytes;
}

static int
wd_find_kernel_path(const char* bundle_path, const char* models_dir, const char* file_name, char* output, size_t output_size)
{
  char expanded_models_dir[WD_MODELS_DIR_CAP];
  char candidate[WD_CONFIG_PATH_CAP];
  char fallback_bundle[WD_CONFIG_PATH_CAP];
  const char* home;
  FILE* file;

  if (models_dir && wd_expand_home_path(models_dir, expanded_models_dir, sizeof(expanded_models_dir))) {
    snprintf(candidate, sizeof(candidate), "%s/kernels/%s", expanded_models_dir, file_name);
    file = fopen(candidate, "rb");
    if (file) {
      fclose(file);
      snprintf(output, output_size, "%s", candidate);
      return 1;
    }
  }

  if (bundle_path) {
    snprintf(candidate, sizeof(candidate), "%s/kernels/%s", bundle_path, file_name);
    file = fopen(candidate, "rb");
    if (file) {
      fclose(file);
      snprintf(output, output_size, "%s", candidate);
      return 1;
    }
  }

  home = getenv("HOME");
  if (home && home[0] != '\0') {
    snprintf(fallback_bundle, sizeof(fallback_bundle), "%s/.lv2/wiredeck-cuda-denoiser.lv2/kernels/%s", home, file_name);
    file = fopen(fallback_bundle, "rb");
    if (file) {
      fclose(file);
      snprintf(output, output_size, "%s", fallback_bundle);
      return 1;
    }
  }

  return 0;
}

void
wd_cuda_backend_init(WireDeckCudaBackend* backend)
{
  if (!backend) {
    return;
  }
  memset(backend, 0, sizeof(*backend));
}

void
wd_cuda_backend_deinit(WireDeckCudaBackend* backend, WireDeckCudaSession* session)
{
  WdCuMemFreeFn cu_mem_free;
  int index;
  if (!backend) {
    return;
  }

  cu_mem_free = NULL;
  if (session && session->libcuda_handle) {
    cu_mem_free = (WdCuMemFreeFn)dlsym(session->libcuda_handle, "cuMemFree_v2");
    if (!cu_mem_free) {
      cu_mem_free = (WdCuMemFreeFn)dlsym(session->libcuda_handle, "cuMemFree");
    }
  }

  if (cu_mem_free) {
    for (index = 0; index < backend->weight_count; ++index) {
      if (backend->weights[index].device_ptr != 0) {
        cu_mem_free((CUdeviceptr)backend->weights[index].device_ptr);
      }
    }
    if (backend->input_device_ptr != 0) {
      cu_mem_free((CUdeviceptr)backend->input_device_ptr);
    }
    if (backend->x_device_ptr != 0) cu_mem_free((CUdeviceptr)backend->x_device_ptr);
    if (backend->a_device_ptr != 0) cu_mem_free((CUdeviceptr)backend->a_device_ptr);
    if (backend->b_device_ptr != 0) cu_mem_free((CUdeviceptr)backend->b_device_ptr);
    if (backend->c_device_ptr != 0) cu_mem_free((CUdeviceptr)backend->c_device_ptr);
    if (backend->hidden_device_ptr != 0) cu_mem_free((CUdeviceptr)backend->hidden_device_ptr);
    if (backend->mask_device_ptr != 0) cu_mem_free((CUdeviceptr)backend->mask_device_ptr);
    if (backend->vad_map_device_ptr != 0) cu_mem_free((CUdeviceptr)backend->vad_map_device_ptr);
    if (backend->vad_scalar_device_ptr != 0) cu_mem_free((CUdeviceptr)backend->vad_scalar_device_ptr);
  }

  free((void*)(uintptr_t)backend->mask_host_ptr);
  free((void*)(uintptr_t)backend->vad_host_ptr);
  free(backend->weights);
  memset(backend, 0, sizeof(*backend));
}

static int
wd_launch_input_projection(
    WireDeckCudaBackend* backend,
    WireDeckCudaSession* session,
    const WireDeckWdgpModel* model,
    const float* features,
    unsigned int frames,
    char* error_message,
    size_t error_message_size)
{
  WdCuMemcpyHtoDFn cu_memcpy_htod;
  WdCuLaunchKernelFn cu_launch_kernel;
  const WireDeckCudaWeightBuffer* weight_buffer = wd_find_weight_buffer(backend, "input_proj.weight");
  const WireDeckCudaWeightBuffer* bias_buffer = wd_find_weight_buffer(backend, "input_proj.bias");
  unsigned int bands;
  unsigned int channels;
  unsigned int block_x = 16;
  unsigned int block_y = 8;
  unsigned int grid_x;
  unsigned int grid_y;
  unsigned int grid_z;
  void* kernel_params[7];

  if (!weight_buffer || !bias_buffer) {
    wd_backend_error(error_message, error_message_size, "missing uploaded input projection weights", NULL);
    return 0;
  }

  cu_memcpy_htod = (WdCuMemcpyHtoDFn)dlsym(session->libcuda_handle, "cuMemcpyHtoD_v2");
  if (!cu_memcpy_htod) cu_memcpy_htod = (WdCuMemcpyHtoDFn)dlsym(session->libcuda_handle, "cuMemcpyHtoD");
  cu_launch_kernel = (WdCuLaunchKernelFn)dlsym(session->libcuda_handle, "cuLaunchKernel");
  if (!cu_memcpy_htod || !cu_launch_kernel) {
    wd_backend_error(error_message, error_message_size, "missing CUDA execution symbols", NULL);
    return 0;
  }

  bands = (unsigned int)model->metadata.bands;
  channels = (unsigned int)model->metadata.channels;
  grid_x = (bands + block_x - 1) / block_x;
  grid_y = (frames + block_y - 1) / block_y;
  grid_z = channels;

  if (cu_memcpy_htod((CUdeviceptr)backend->input_device_ptr, features, backend->input_size_bytes) != CUDA_SUCCESS) {
    wd_backend_error(error_message, error_message_size, "could not upload frontend features", NULL);
    return 0;
  }

  kernel_params[0] = &backend->input_device_ptr;
  kernel_params[1] = (void*)&weight_buffer->device_ptr;
  kernel_params[2] = (void*)&bias_buffer->device_ptr;
  kernel_params[3] = &backend->x_device_ptr;
  kernel_params[4] = &frames;
  kernel_params[5] = &bands;
  kernel_params[6] = &channels;

  if (cu_launch_kernel(
          backend->function_handles[0],
          grid_x, grid_y, grid_z,
          block_x, block_y, 1,
          0, NULL, kernel_params, NULL) != CUDA_SUCCESS) {
    wd_backend_error(error_message, error_message_size, "could not launch input_projection kernel", NULL);
    return 0;
  }

  return 1;
}

static int
wd_launch_groupnorm_silu(
    WireDeckCudaBackend* backend,
    WireDeckCudaSession* session,
    const char* weight_name,
    const char* bias_name,
    unsigned long long input_ptr,
    unsigned long long output_ptr,
    unsigned int channels,
    unsigned int frames,
    unsigned int bands,
    char* error_message,
    size_t error_message_size)
{
  WdCuLaunchKernelFn cu_launch_kernel;
  const WireDeckCudaWeightBuffer* weight_buffer = wd_find_weight_buffer(backend, weight_name);
  const WireDeckCudaWeightBuffer* bias_buffer = wd_find_weight_buffer(backend, bias_name);
  float epsilon = 1.0e-5f;
  void* params[8];

  if (!weight_buffer || !bias_buffer) {
    wd_backend_error(error_message, error_message_size, "missing norm tensor: %s", weight_name);
    return 0;
  }

  cu_launch_kernel = (WdCuLaunchKernelFn)dlsym(session->libcuda_handle, "cuLaunchKernel");
  if (!cu_launch_kernel) {
    wd_backend_error(error_message, error_message_size, "missing cuLaunchKernel", NULL);
    return 0;
  }

  params[0] = &input_ptr;
  params[1] = (void*)&weight_buffer->device_ptr;
  params[2] = (void*)&bias_buffer->device_ptr;
  params[3] = &output_ptr;
  params[4] = &channels;
  params[5] = &frames;
  params[6] = &bands;
  params[7] = &epsilon;

  if (cu_launch_kernel(backend->function_handles[2], 1, 1, 1, 256, 1, 1, 0, NULL, params, NULL) != CUDA_SUCCESS) {
    wd_backend_error(error_message, error_message_size, "could not launch groupnorm_silu kernel", NULL);
    return 0;
  }
  return 1;
}

static int
wd_launch_conv2d(
    WireDeckCudaBackend* backend,
    WireDeckCudaSession* session,
    const char* weight_name,
    const char* bias_name,
    unsigned long long input_ptr,
    unsigned long long output_ptr,
    unsigned int in_channels,
    unsigned int out_channels,
    unsigned int frames,
    unsigned int bands,
    unsigned int kernel_time,
    unsigned int kernel_freq,
    char* error_message,
    size_t error_message_size)
{
  WdCuLaunchKernelFn cu_launch_kernel;
  const WireDeckCudaWeightBuffer* weight_buffer = wd_find_weight_buffer(backend, weight_name);
  const WireDeckCudaWeightBuffer* bias_buffer = wd_find_weight_buffer(backend, bias_name);
  unsigned int block_x = 16;
  unsigned int block_y = 8;
  unsigned int grid_x = (bands + block_x - 1) / block_x;
  unsigned int grid_y = (frames + block_y - 1) / block_y;
  void* params[9];

  if (!weight_buffer || !bias_buffer) {
    wd_backend_error(error_message, error_message_size, "missing conv tensor: %s", weight_name);
    return 0;
  }
  cu_launch_kernel = (WdCuLaunchKernelFn)dlsym(session->libcuda_handle, "cuLaunchKernel");
  if (!cu_launch_kernel) {
    wd_backend_error(error_message, error_message_size, "missing cuLaunchKernel", NULL);
    return 0;
  }

  params[0] = &input_ptr;
  params[1] = (void*)&weight_buffer->device_ptr;
  params[2] = (void*)&bias_buffer->device_ptr;
  params[3] = &output_ptr;
  params[4] = &in_channels;
  params[5] = &out_channels;
  params[6] = &frames;
  params[7] = &bands;
  params[8] = &kernel_time;
  {
    void* extra_params[11];
    extra_params[0] = params[0];
    extra_params[1] = params[1];
    extra_params[2] = params[2];
    extra_params[3] = params[3];
    extra_params[4] = params[4];
    extra_params[5] = params[5];
    extra_params[6] = params[6];
    extra_params[7] = params[7];
    extra_params[8] = params[8];
    extra_params[9] = &kernel_freq;
    extra_params[10] = NULL;
    if (cu_launch_kernel(backend->function_handles[1], grid_x, grid_y, out_channels, block_x, block_y, 1, 0, NULL, extra_params, NULL) != CUDA_SUCCESS) {
      wd_backend_error(error_message, error_message_size, "could not launch conv2d kernel", NULL);
      return 0;
    }
  }
  return 1;
}

static int
wd_launch_add(
    WireDeckCudaBackend* backend,
    WireDeckCudaSession* session,
    unsigned long long lhs_ptr,
    unsigned long long rhs_ptr,
    unsigned long long output_ptr,
    unsigned int total,
    char* error_message,
    size_t error_message_size)
{
  WdCuLaunchKernelFn cu_launch_kernel = (WdCuLaunchKernelFn)dlsym(session->libcuda_handle, "cuLaunchKernel");
  unsigned int block = 256;
  unsigned int grid = (total + block - 1) / block;
  void* params[4];
  if (!cu_launch_kernel) {
    wd_backend_error(error_message, error_message_size, "missing cuLaunchKernel", NULL);
    return 0;
  }
  params[0] = &lhs_ptr;
  params[1] = &rhs_ptr;
  params[2] = &output_ptr;
  params[3] = &total;
  if (cu_launch_kernel(backend->function_handles[3], grid, 1, 1, block, 1, 1, 0, NULL, params, NULL) != CUDA_SUCCESS) {
    wd_backend_error(error_message, error_message_size, "could not launch add kernel", NULL);
    return 0;
  }
  return 1;
}

static int
wd_launch_silu(
    WireDeckCudaBackend* backend,
    WireDeckCudaSession* session,
    unsigned long long input_ptr,
    unsigned long long output_ptr,
    unsigned int total,
    char* error_message,
    size_t error_message_size)
{
  WdCuLaunchKernelFn cu_launch_kernel = (WdCuLaunchKernelFn)dlsym(session->libcuda_handle, "cuLaunchKernel");
  unsigned int block = 256;
  unsigned int grid = (total + block - 1) / block;
  void* params[3];
  if (!cu_launch_kernel) {
    wd_backend_error(error_message, error_message_size, "missing cuLaunchKernel", NULL);
    return 0;
  }
  params[0] = &input_ptr;
  params[1] = &output_ptr;
  params[2] = &total;
  if (cu_launch_kernel(backend->function_handles[4], grid, 1, 1, block, 1, 1, 0, NULL, params, NULL) != CUDA_SUCCESS) {
    wd_backend_error(error_message, error_message_size, "could not launch silu kernel", NULL);
    return 0;
  }
  return 1;
}

static int
wd_launch_sigmoid(
    WireDeckCudaBackend* backend,
    WireDeckCudaSession* session,
    unsigned long long input_ptr,
    unsigned long long output_ptr,
    unsigned int total,
    char* error_message,
    size_t error_message_size)
{
  WdCuLaunchKernelFn cu_launch_kernel = (WdCuLaunchKernelFn)dlsym(session->libcuda_handle, "cuLaunchKernel");
  unsigned int block = 256;
  unsigned int grid = (total + block - 1) / block;
  void* params[3];
  if (!cu_launch_kernel) {
    wd_backend_error(error_message, error_message_size, "missing cuLaunchKernel", NULL);
    return 0;
  }
  params[0] = &input_ptr;
  params[1] = &output_ptr;
  params[2] = &total;
  if (cu_launch_kernel(backend->function_handles[5], grid, 1, 1, block, 1, 1, 0, NULL, params, NULL) != CUDA_SUCCESS) {
    wd_backend_error(error_message, error_message_size, "could not launch sigmoid kernel", NULL);
    return 0;
  }
  return 1;
}

static int
wd_launch_mean_over_bands(
    WireDeckCudaBackend* backend,
    WireDeckCudaSession* session,
    unsigned long long input_ptr,
    unsigned long long output_ptr,
    unsigned int channels,
    unsigned int frames,
    unsigned int bands,
    char* error_message,
    size_t error_message_size)
{
  WdCuLaunchKernelFn cu_launch_kernel = (WdCuLaunchKernelFn)dlsym(session->libcuda_handle, "cuLaunchKernel");
  unsigned int block = 64;
  unsigned int grid_x = (frames + block - 1) / block;
  void* params[5];
  if (!cu_launch_kernel) {
    wd_backend_error(error_message, error_message_size, "missing cuLaunchKernel", NULL);
    return 0;
  }
  params[0] = &input_ptr;
  params[1] = &output_ptr;
  params[2] = &channels;
  params[3] = &frames;
  params[4] = &bands;
  if (cu_launch_kernel(backend->function_handles[6], grid_x, channels, 1, block, 1, 1, 0, NULL, params, NULL) != CUDA_SUCCESS) {
    wd_backend_error(error_message, error_message_size, "could not launch mean_over_bands kernel", NULL);
    return 0;
  }
  return 1;
}

int
wd_cuda_backend_prepare(
    WireDeckCudaBackend* backend,
    WireDeckCudaSession* session,
    const WireDeckWdgpModel* model,
    const char* bundle_path,
    const char* models_dir,
    char* error_message,
    size_t error_message_size)
{
  WdCuModuleLoadDataExFn cu_module_load_data_ex;
  WdCuModuleGetFunctionFn cu_module_get_function;
  WdCuMemAllocFn cu_mem_alloc;
  WdCuMemcpyHtoDFn cu_memcpy_htod;
  int index;

  if (!backend || !session || !session->libcuda_handle || !model) {
    wd_backend_error(error_message, error_message_size, "invalid CUDA backend state", NULL);
    return 0;
  }
  if (!wd_cuda_session_make_current(session, error_message, error_message_size)) {
    return 0;
  }

  wd_cuda_backend_deinit(backend, session);

  cu_module_load_data_ex = (WdCuModuleLoadDataExFn)dlsym(session->libcuda_handle, "cuModuleLoadDataEx");
  cu_module_get_function = (WdCuModuleGetFunctionFn)dlsym(session->libcuda_handle, "cuModuleGetFunction");
  cu_mem_alloc = (WdCuMemAllocFn)dlsym(session->libcuda_handle, "cuMemAlloc_v2");
  if (!cu_mem_alloc) {
    cu_mem_alloc = (WdCuMemAllocFn)dlsym(session->libcuda_handle, "cuMemAlloc");
  }
  cu_memcpy_htod = (WdCuMemcpyHtoDFn)dlsym(session->libcuda_handle, "cuMemcpyHtoD_v2");
  if (!cu_memcpy_htod) {
    cu_memcpy_htod = (WdCuMemcpyHtoDFn)dlsym(session->libcuda_handle, "cuMemcpyHtoD");
  }
  if (!cu_module_load_data_ex || !cu_module_get_function || !cu_mem_alloc || !cu_memcpy_htod) {
    wd_backend_error(error_message, error_message_size, "missing CUDA backend symbols", NULL);
    return 0;
  }

  for (index = 0; index < WD_CUDA_KERNEL_COUNT; ++index) {
    char kernel_path[WD_CONFIG_PATH_CAP];
    unsigned char* ptx_bytes;
    size_t ptx_size;
    void* module_handle = NULL;
    void* function_handle = NULL;

    if (!wd_find_kernel_path(bundle_path, models_dir, wd_kernel_file_names[index], kernel_path, sizeof(kernel_path))) {
      wd_backend_error(error_message, error_message_size, "missing kernel PTX: %s", wd_kernel_file_names[index]);
      return 0;
    }

    ptx_bytes = wd_read_file_bytes(kernel_path, &ptx_size);
    if (!ptx_bytes || ptx_size == 0) {
      free(ptx_bytes);
      wd_backend_error(error_message, error_message_size, "could not read kernel PTX: %s", wd_kernel_file_names[index]);
      return 0;
    }

    if (cu_module_load_data_ex(&module_handle, ptx_bytes, 0, NULL, NULL) != CUDA_SUCCESS ||
        cu_module_get_function(&function_handle, module_handle, wd_kernel_symbol_names[index]) != CUDA_SUCCESS) {
      free(ptx_bytes);
      wd_backend_error(error_message, error_message_size, "could not load kernel: %s", wd_kernel_symbol_names[index]);
      return 0;
    }

    free(ptx_bytes);
    backend->module_handles[index] = module_handle;
    backend->function_handles[index] = function_handle;
  }
  backend->kernels_ready = 1;

  backend->weights = (WireDeckCudaWeightBuffer*)calloc((size_t)model->tensor_count, sizeof(WireDeckCudaWeightBuffer));
  if (!backend->weights) {
    wd_backend_error(error_message, error_message_size, "out of memory", NULL);
    return 0;
  }
  backend->weight_count = model->tensor_count;

  for (index = 0; index < model->tensor_count; ++index) {
    const WireDeckWdgpTensorInfo* tensor = &model->tensors[index];
    CUdeviceptr device_ptr = 0;
    if (tensor->offset + tensor->byte_length > model->payload_size) {
      wd_backend_error(error_message, error_message_size, "tensor payload out of bounds: %s", tensor->name);
      return 0;
    }
    if (cu_mem_alloc(&device_ptr, tensor->byte_length) != CUDA_SUCCESS ||
        cu_memcpy_htod(device_ptr, model->payload + tensor->offset, tensor->byte_length) != CUDA_SUCCESS) {
      wd_backend_error(error_message, error_message_size, "could not upload weights for tensor: %s", tensor->name);
      return 0;
    }
    snprintf(backend->weights[index].name, sizeof(backend->weights[index].name), "%s", tensor->name);
    backend->weights[index].device_ptr = device_ptr;
    backend->weights[index].size_bytes = tensor->byte_length;
  }
  backend->weights_ready = 1;
  backend->sequence_frames = (unsigned int)(model->metadata.kernel_time + (model->metadata.lookahead_frames > 0 ? model->metadata.lookahead_frames : 0));
  if (backend->sequence_frames == 0) {
    backend->sequence_frames = 1;
  }
  if ((unsigned int)(model->metadata.lookahead_frames > 0 ? model->metadata.lookahead_frames : 0) >= backend->sequence_frames) {
    backend->target_frame_index = 0;
  } else {
    backend->target_frame_index = backend->sequence_frames - 1u - (unsigned int)(model->metadata.lookahead_frames > 0 ? model->metadata.lookahead_frames : 0);
  }
  backend->input_size_bytes = (size_t)backend->sequence_frames * (size_t)model->metadata.bands * sizeof(float);
  backend->channels_size_bytes = (size_t)model->metadata.channels * (size_t)backend->sequence_frames * (size_t)model->metadata.bands * sizeof(float);
  backend->hidden_size_bytes = (size_t)model->metadata.hidden_channels * (size_t)backend->sequence_frames * (size_t)model->metadata.bands * sizeof(float);
  backend->mask_size_bytes = (size_t)backend->sequence_frames * (size_t)model->metadata.bands * sizeof(float);
  backend->vad_size_bytes = (size_t)backend->sequence_frames * sizeof(float);
  if (cu_mem_alloc((CUdeviceptr*)&backend->input_device_ptr, backend->input_size_bytes) != CUDA_SUCCESS ||
      cu_mem_alloc((CUdeviceptr*)&backend->x_device_ptr, backend->channels_size_bytes) != CUDA_SUCCESS ||
      cu_mem_alloc((CUdeviceptr*)&backend->a_device_ptr, backend->channels_size_bytes) != CUDA_SUCCESS ||
      cu_mem_alloc((CUdeviceptr*)&backend->b_device_ptr, backend->channels_size_bytes) != CUDA_SUCCESS ||
      cu_mem_alloc((CUdeviceptr*)&backend->c_device_ptr, backend->channels_size_bytes) != CUDA_SUCCESS ||
      cu_mem_alloc((CUdeviceptr*)&backend->hidden_device_ptr, backend->hidden_size_bytes) != CUDA_SUCCESS ||
      cu_mem_alloc((CUdeviceptr*)&backend->mask_device_ptr, backend->mask_size_bytes) != CUDA_SUCCESS ||
      cu_mem_alloc((CUdeviceptr*)&backend->vad_map_device_ptr, backend->mask_size_bytes) != CUDA_SUCCESS ||
      cu_mem_alloc((CUdeviceptr*)&backend->vad_scalar_device_ptr, backend->vad_size_bytes) != CUDA_SUCCESS) {
    wd_backend_error(error_message, error_message_size, "could not allocate CUDA activation buffers", NULL);
    return 0;
  }
  backend->mask_host_ptr = (unsigned long long)(uintptr_t)calloc((size_t)backend->sequence_frames * (size_t)model->metadata.bands, sizeof(float));
  backend->vad_host_ptr = (unsigned long long)(uintptr_t)calloc((size_t)backend->sequence_frames, sizeof(float));
  if (backend->mask_host_ptr == 0 || backend->vad_host_ptr == 0) {
    wd_backend_error(error_message, error_message_size, "out of memory", NULL);
    return 0;
  }

  if (error_message && error_message_size > 0) {
    error_message[0] = '\0';
  }
  return 1;
}

int
wd_cuda_backend_run_input_projection(
    WireDeckCudaBackend* backend,
    WireDeckCudaSession* session,
    const WireDeckWdgpModel* model,
    const float* features,
    char* error_message,
    size_t error_message_size)
{
  return wd_launch_input_projection(backend, session, model, features, backend->sequence_frames, error_message, error_message_size);
}

int
wd_cuda_backend_run_model(
    WireDeckCudaBackend* backend,
    WireDeckCudaSession* session,
    const WireDeckWdgpModel* model,
    const float* features,
    float* out_mask,
    float* out_mask_mean,
    float* out_vad,
    char* error_message,
    size_t error_message_size)
{
  WdCuMemcpyDtoHFn cu_memcpy_dtoh;
  unsigned int channels;
  unsigned int hidden_channels;
  unsigned int bands;
  unsigned int frames;
  unsigned int total_channels;
  unsigned int total_hidden;
  unsigned int total_mask_values;
  unsigned int one = 1;
  int block_index;
  float mask_mean = 0.0f;
  int band_index;
  float* mask_values;
  float* vad_values;

  if (!backend || !session || !model || !features) {
    wd_backend_error(error_message, error_message_size, "invalid CUDA model run state", NULL);
    return 0;
  }
  if (!wd_cuda_session_make_current(session, error_message, error_message_size)) {
    return 0;
  }

  channels = (unsigned int)model->metadata.channels;
  hidden_channels = (unsigned int)model->metadata.hidden_channels;
  bands = (unsigned int)model->metadata.bands;
  frames = backend->sequence_frames;
  total_channels = channels * frames * bands;
  total_hidden = hidden_channels * frames * bands;
  total_mask_values = frames * bands;

  if (!wd_launch_input_projection(backend, session, model, features, frames, error_message, error_message_size)) {
    return 0;
  }

  for (block_index = 0; block_index < model->metadata.residual_blocks; ++block_index) {
    char name_weight[96];
    char name_bias[96];

    snprintf(name_weight, sizeof(name_weight), "blocks.%d.norm1.weight", block_index);
    snprintf(name_bias, sizeof(name_bias), "blocks.%d.norm1.bias", block_index);
    if (!wd_launch_groupnorm_silu(backend, session, name_weight, name_bias, backend->x_device_ptr, backend->a_device_ptr, channels, frames, bands, error_message, error_message_size)) return 0;

    snprintf(name_weight, sizeof(name_weight), "blocks.%d.conv1.weight", block_index);
    snprintf(name_bias, sizeof(name_bias), "blocks.%d.conv1.bias", block_index);
    if (!wd_launch_conv2d(backend, session, name_weight, name_bias, backend->a_device_ptr, backend->b_device_ptr, channels, channels, frames, bands, (unsigned int)model->metadata.kernel_time, (unsigned int)model->metadata.kernel_freq, error_message, error_message_size)) return 0;

    snprintf(name_weight, sizeof(name_weight), "blocks.%d.norm2.weight", block_index);
    snprintf(name_bias, sizeof(name_bias), "blocks.%d.norm2.bias", block_index);
    if (!wd_launch_groupnorm_silu(backend, session, name_weight, name_bias, backend->b_device_ptr, backend->a_device_ptr, channels, frames, bands, error_message, error_message_size)) return 0;

    snprintf(name_weight, sizeof(name_weight), "blocks.%d.conv2.weight", block_index);
    snprintf(name_bias, sizeof(name_bias), "blocks.%d.conv2.bias", block_index);
    if (!wd_launch_conv2d(backend, session, name_weight, name_bias, backend->a_device_ptr, backend->b_device_ptr, channels, channels, frames, bands, (unsigned int)model->metadata.kernel_time, (unsigned int)model->metadata.kernel_freq, error_message, error_message_size)) return 0;

    if (!wd_launch_add(backend, session, backend->x_device_ptr, backend->b_device_ptr, backend->c_device_ptr, total_channels, error_message, error_message_size)) return 0;
    {
      unsigned long long swap = backend->x_device_ptr;
      backend->x_device_ptr = backend->c_device_ptr;
      backend->c_device_ptr = swap;
    }
  }

  if (!wd_launch_groupnorm_silu(backend, session, "bottleneck.0.weight", "bottleneck.0.bias", backend->x_device_ptr, backend->a_device_ptr, channels, frames, bands, error_message, error_message_size)) return 0;
  if (!wd_launch_conv2d(backend, session, "bottleneck.2.weight", "bottleneck.2.bias", backend->a_device_ptr, backend->hidden_device_ptr, channels, hidden_channels, frames, bands, 1, 1, error_message, error_message_size)) return 0;
  if (!wd_launch_silu(backend, session, backend->hidden_device_ptr, backend->hidden_device_ptr, total_hidden, error_message, error_message_size)) return 0;
  if (!wd_launch_conv2d(backend, session, "bottleneck.4.weight", "bottleneck.4.bias", backend->hidden_device_ptr, backend->b_device_ptr, hidden_channels, channels, frames, bands, 1, 1, error_message, error_message_size)) return 0;
  if (!wd_launch_add(backend, session, backend->x_device_ptr, backend->b_device_ptr, backend->x_device_ptr, total_channels, error_message, error_message_size)) return 0;

  if (!wd_launch_groupnorm_silu(backend, session, "mask_head.0.weight", "mask_head.0.bias", backend->x_device_ptr, backend->a_device_ptr, channels, frames, bands, error_message, error_message_size)) return 0;
  if (!wd_launch_conv2d(backend, session, "mask_head.2.weight", "mask_head.2.bias", backend->a_device_ptr, backend->mask_device_ptr, channels, one, frames, bands, 1, 1, error_message, error_message_size)) return 0;
  if (!wd_launch_sigmoid(backend, session, backend->mask_device_ptr, backend->mask_device_ptr, total_mask_values, error_message, error_message_size)) return 0;

  if (!wd_launch_groupnorm_silu(backend, session, "vad_head.0.weight", "vad_head.0.bias", backend->x_device_ptr, backend->a_device_ptr, channels, frames, bands, error_message, error_message_size)) return 0;
  if (!wd_launch_conv2d(backend, session, "vad_head.2.weight", "vad_head.2.bias", backend->a_device_ptr, backend->vad_map_device_ptr, channels, one, frames, bands, 1, 1, error_message, error_message_size)) return 0;
  if (!wd_launch_sigmoid(backend, session, backend->vad_map_device_ptr, backend->vad_map_device_ptr, total_mask_values, error_message, error_message_size)) return 0;
  if (!wd_launch_mean_over_bands(backend, session, backend->vad_map_device_ptr, backend->vad_scalar_device_ptr, one, frames, bands, error_message, error_message_size)) return 0;

  cu_memcpy_dtoh = (WdCuMemcpyDtoHFn)dlsym(session->libcuda_handle, "cuMemcpyDtoH_v2");
  if (!cu_memcpy_dtoh) cu_memcpy_dtoh = (WdCuMemcpyDtoHFn)dlsym(session->libcuda_handle, "cuMemcpyDtoH");
  if (!cu_memcpy_dtoh) {
    wd_backend_error(error_message, error_message_size, "missing cuMemcpyDtoH", NULL);
    return 0;
  }
  if (cu_memcpy_dtoh((void*)(uintptr_t)backend->mask_host_ptr, (CUdeviceptr)backend->mask_device_ptr, backend->mask_size_bytes) != CUDA_SUCCESS ||
      cu_memcpy_dtoh((void*)(uintptr_t)backend->vad_host_ptr, (CUdeviceptr)backend->vad_scalar_device_ptr, backend->vad_size_bytes) != CUDA_SUCCESS) {
    wd_backend_error(error_message, error_message_size, "could not download model outputs", NULL);
    return 0;
  }

  mask_values = (float*)(uintptr_t)backend->mask_host_ptr;
  vad_values = (float*)(uintptr_t)backend->vad_host_ptr;
  if (out_mask_mean || out_mask) {
    size_t target_offset = (size_t)backend->target_frame_index * (size_t)bands;
    for (band_index = 0; band_index < (int)bands; ++band_index) mask_mean += mask_values[target_offset + (size_t)band_index];
    if (out_mask) {
      memcpy(out_mask, mask_values + target_offset, (size_t)bands * sizeof(float));
    }
  }
  if (out_mask_mean) {
    *out_mask_mean = mask_mean / (float)bands;
  }
  if (out_vad) {
    *out_vad = vad_values[backend->target_frame_index];
  }
  if (error_message && error_message_size > 0) error_message[0] = '\0';
  return 1;
}
