#include "cuda_probe.h"

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef int CUdevice;
typedef int CUresult;

#define CUDA_SUCCESS 0

typedef CUresult (*WdCuInitFn)(unsigned int flags);
typedef CUresult (*WdCuDeviceGetCountFn)(int* count);
typedef CUresult (*WdCuDeviceGetNameFn)(char* name, int len, CUdevice dev);

static void
wd_set_error(WireDeckCudaProbeInfo* out_info, const char* message)
{
  if (!out_info) {
    return;
  }

  out_info->available = 0;
  out_info->device_count = 0;
  if (message && message[0] != '\0') {
    snprintf(out_info->error_message, sizeof(out_info->error_message), "%s", message);
  } else {
    out_info->error_message[0] = '\0';
  }
}

int
wd_cuda_probe(WireDeckCudaProbeInfo* out_info)
{
  void* handle;
  WdCuInitFn cu_init;
  WdCuDeviceGetCountFn cu_device_get_count;
  WdCuDeviceGetNameFn cu_device_get_name;
  int count = 0;
  int index;

  if (!out_info) {
    return 0;
  }

  memset(out_info, 0, sizeof(*out_info));

  handle = dlopen("libcuda.so.1", RTLD_LAZY | RTLD_LOCAL);
  if (!handle) {
    wd_set_error(out_info, "libcuda.so.1 not available");
    return 0;
  }

  cu_init = (WdCuInitFn)dlsym(handle, "cuInit");
  cu_device_get_count = (WdCuDeviceGetCountFn)dlsym(handle, "cuDeviceGetCount");
  cu_device_get_name = (WdCuDeviceGetNameFn)dlsym(handle, "cuDeviceGetName");
  if (!cu_init || !cu_device_get_count || !cu_device_get_name) {
    dlclose(handle);
    wd_set_error(out_info, "missing CUDA driver symbols");
    return 0;
  }

  if (cu_init(0) != CUDA_SUCCESS) {
    dlclose(handle);
    wd_set_error(out_info, "cuInit failed");
    return 0;
  }

  if (cu_device_get_count(&count) != CUDA_SUCCESS || count <= 0) {
    dlclose(handle);
    wd_set_error(out_info, "no CUDA devices found");
    return 0;
  }

  if (count > WD_CUDA_MAX_DEVICES) {
    count = WD_CUDA_MAX_DEVICES;
  }

  out_info->available = 1;
  out_info->device_count = count;
  out_info->error_message[0] = '\0';

  for (index = 0; index < count; ++index) {
    if (cu_device_get_name(out_info->device_names[index], WD_CUDA_MAX_NAME, index) != CUDA_SUCCESS) {
      snprintf(out_info->device_names[index], WD_CUDA_MAX_NAME, "CUDA Device %d", index);
    }
  }

  dlclose(handle);
  return 1;
}
