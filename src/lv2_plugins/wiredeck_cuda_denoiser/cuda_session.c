#include "cuda_session.h"

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef int CUdevice;
typedef int CUresult;
typedef struct CUctx_st* CUcontext;

#define CUDA_SUCCESS 0

typedef CUresult (*WdCuInitFn)(unsigned int flags);
typedef CUresult (*WdCuDeviceGetCountFn)(int* count);
typedef CUresult (*WdCuDeviceGetFn)(CUdevice* device, int ordinal);
typedef CUresult (*WdCuCtxCreateFn)(CUcontext* pctx, unsigned int flags, CUdevice dev);
typedef CUresult (*WdCuCtxDestroyFn)(CUcontext ctx);
typedef CUresult (*WdCuCtxSetCurrentFn)(CUcontext ctx);

static void
wd_session_error(char* error_message, size_t error_message_size, const char* fmt, const char* value)
{
  if (!error_message || error_message_size == 0) {
    return;
  }
  snprintf(error_message, error_message_size, fmt ? fmt : "%s", value ? value : "");
}

void
wd_cuda_session_init(WireDeckCudaSession* session)
{
  if (!session) {
    return;
  }
  memset(session, 0, sizeof(*session));
  session->device_index = -1;
}

void
wd_cuda_session_deinit(WireDeckCudaSession* session)
{
  WdCuCtxDestroyFn cu_ctx_destroy;
  if (!session) {
    return;
  }
  if (session->libcuda_handle && session->context) {
    cu_ctx_destroy = (WdCuCtxDestroyFn)dlsym(session->libcuda_handle, "cuCtxDestroy_v2");
    if (!cu_ctx_destroy) {
      cu_ctx_destroy = (WdCuCtxDestroyFn)dlsym(session->libcuda_handle, "cuCtxDestroy");
    }
    if (cu_ctx_destroy) {
      cu_ctx_destroy((CUcontext)session->context);
    }
  }
  if (session->libcuda_handle) {
    dlclose(session->libcuda_handle);
  }
  wd_cuda_session_init(session);
}

int
wd_cuda_session_open(WireDeckCudaSession* session, int device_index, char* error_message, size_t error_message_size)
{
  WdCuInitFn cu_init;
  WdCuDeviceGetCountFn cu_device_get_count;
  WdCuDeviceGetFn cu_device_get;
  WdCuCtxCreateFn cu_ctx_create;
  int device_count = 0;
  CUdevice device = 0;
  CUcontext context = NULL;

  if (!session) {
    wd_session_error(error_message, error_message_size, "invalid CUDA session", NULL);
    return 0;
  }

  wd_cuda_session_deinit(session);
  session->libcuda_handle = dlopen("libcuda.so.1", RTLD_LAZY | RTLD_LOCAL);
  if (!session->libcuda_handle) {
    wd_session_error(error_message, error_message_size, "libcuda.so.1 not available", NULL);
    return 0;
  }

  cu_init = (WdCuInitFn)dlsym(session->libcuda_handle, "cuInit");
  cu_device_get_count = (WdCuDeviceGetCountFn)dlsym(session->libcuda_handle, "cuDeviceGetCount");
  cu_device_get = (WdCuDeviceGetFn)dlsym(session->libcuda_handle, "cuDeviceGet");
  cu_ctx_create = (WdCuCtxCreateFn)dlsym(session->libcuda_handle, "cuCtxCreate_v2");
  if (!cu_ctx_create) {
    cu_ctx_create = (WdCuCtxCreateFn)dlsym(session->libcuda_handle, "cuCtxCreate");
  }
  if (!cu_init || !cu_device_get_count || !cu_device_get || !cu_ctx_create) {
    wd_cuda_session_deinit(session);
    wd_session_error(error_message, error_message_size, "missing CUDA driver symbols", NULL);
    return 0;
  }

  if (cu_init(0) != CUDA_SUCCESS || cu_device_get_count(&device_count) != CUDA_SUCCESS) {
    wd_cuda_session_deinit(session);
    wd_session_error(error_message, error_message_size, "CUDA driver init failed", NULL);
    return 0;
  }
  if (device_index < 0 || device_index >= device_count) {
    wd_cuda_session_deinit(session);
    wd_session_error(error_message, error_message_size, "CUDA device index invalid", NULL);
    return 0;
  }
  if (cu_device_get(&device, device_index) != CUDA_SUCCESS) {
    wd_cuda_session_deinit(session);
    wd_session_error(error_message, error_message_size, "could not open CUDA device", NULL);
    return 0;
  }
  if (cu_ctx_create(&context, 0, device) != CUDA_SUCCESS) {
    wd_cuda_session_deinit(session);
    wd_session_error(error_message, error_message_size, "could not create CUDA context", NULL);
    return 0;
  }

  session->context = context;
  session->device_index = device_index;
  session->ready = 1;
  if (error_message && error_message_size > 0) {
    error_message[0] = '\0';
  }
  return 1;
}

int
wd_cuda_session_make_current(WireDeckCudaSession* session, char* error_message, size_t error_message_size)
{
  WdCuCtxSetCurrentFn cu_ctx_set_current;
  if (!session || !session->libcuda_handle || !session->context) {
    wd_session_error(error_message, error_message_size, "invalid CUDA session", NULL);
    return 0;
  }
  cu_ctx_set_current = (WdCuCtxSetCurrentFn)dlsym(session->libcuda_handle, "cuCtxSetCurrent");
  if (!cu_ctx_set_current) {
    wd_session_error(error_message, error_message_size, "missing cuCtxSetCurrent", NULL);
    return 0;
  }
  if (cu_ctx_set_current((CUcontext)session->context) != CUDA_SUCCESS) {
    wd_session_error(error_message, error_message_size, "could not make CUDA context current", NULL);
    return 0;
  }
  if (error_message && error_message_size > 0) {
    error_message[0] = '\0';
  }
  return 1;
}
