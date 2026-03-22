from __future__ import annotations

from pathlib import Path

from cuda import nvrtc


KERNELS = {
    "input_projection": r"""
extern "C" __global__ void input_projection(
    const float* input,
    const float* weight,
    const float* bias,
    float* output,
    unsigned int frames,
    unsigned int bands,
    unsigned int channels) {
  unsigned int band = blockIdx.x * blockDim.x + threadIdx.x;
  unsigned int frame = blockIdx.y * blockDim.y + threadIdx.y;
  unsigned int channel = blockIdx.z;
  if (band >= bands || frame >= frames || channel >= channels) return;
  unsigned int input_index = frame * bands + band;
  unsigned int output_index = (channel * frames + frame) * bands + band;
  output[output_index] = input[input_index] * weight[channel] + bias[channel];
}
""",
    "conv2d_same_cfb": r"""
extern "C" __global__ void conv2d_same_cfb(
    const float* input,
    const float* weight,
    const float* bias,
    float* output,
    unsigned int in_channels,
    unsigned int out_channels,
    unsigned int frames,
    unsigned int bands,
    unsigned int kernel_time,
    unsigned int kernel_freq) {
  unsigned int band = blockIdx.x * blockDim.x + threadIdx.x;
  unsigned int frame = blockIdx.y * blockDim.y + threadIdx.y;
  unsigned int out_channel = blockIdx.z;
  if (band >= bands || frame >= frames || out_channel >= out_channels) return;

  int pad_t = (int)(kernel_time / 2);
  int pad_f = (int)(kernel_freq / 2);
  float acc = bias[out_channel];

  for (unsigned int in_channel = 0; in_channel < in_channels; ++in_channel) {
    for (unsigned int kt = 0; kt < kernel_time; ++kt) {
      int in_frame = (int)frame + (int)kt - pad_t;
      if (in_frame < 0 || in_frame >= (int)frames) continue;
      for (unsigned int kf = 0; kf < kernel_freq; ++kf) {
        int in_band = (int)band + (int)kf - pad_f;
        if (in_band < 0 || in_band >= (int)bands) continue;
        unsigned int input_index = (in_channel * frames + (unsigned int)in_frame) * bands + (unsigned int)in_band;
        unsigned int weight_index = (((out_channel * in_channels) + in_channel) * kernel_time + kt) * kernel_freq + kf;
        acc += input[input_index] * weight[weight_index];
      }
    }
  }

  unsigned int output_index = (out_channel * frames + frame) * bands + band;
  output[output_index] = acc;
}
""",
    "groupnorm_silu_cfb": r"""
extern "C" __global__ void groupnorm_silu_cfb(
    const float* input,
    const float* weight,
    const float* bias,
    float* output,
    unsigned int channels,
    unsigned int frames,
    unsigned int bands,
    float epsilon) {
  unsigned int total = channels * frames * bands;
  unsigned int tid = threadIdx.x;
  if (blockIdx.x != 0 || blockIdx.y != 0 || blockIdx.z != 0 || tid >= 256) return;

  __shared__ float partial_sum[256];
  __shared__ float partial_var[256];
  __shared__ float mean;
  __shared__ float inv_std;

  float local_sum = 0.0f;
  for (unsigned int i = tid; i < total; i += blockDim.x) {
    local_sum += input[i];
  }
  partial_sum[tid] = local_sum;
  __syncthreads();

  for (unsigned int stride = blockDim.x / 2; stride > 0; stride >>= 1) {
    if (tid < stride) {
      partial_sum[tid] += partial_sum[tid + stride];
    }
    __syncthreads();
  }
  if (tid == 0) {
    mean = partial_sum[0] / (float)total;
  }
  __syncthreads();

  float local_var = 0.0f;
  for (unsigned int i = tid; i < total; i += blockDim.x) {
    float d = input[i] - mean;
    local_var += d * d;
  }
  partial_var[tid] = local_var;
  __syncthreads();

  for (unsigned int stride = blockDim.x / 2; stride > 0; stride >>= 1) {
    if (tid < stride) {
      partial_var[tid] += partial_var[tid + stride];
    }
    __syncthreads();
  }
  if (tid == 0) {
    float var = partial_var[0] / (float)total;
    inv_std = rsqrtf(var + epsilon);
  }
  __syncthreads();

  for (unsigned int idx = tid; idx < total; idx += blockDim.x) {
    unsigned int channel_stride = frames * bands;
    unsigned int c = idx / channel_stride;
    float normalized = (input[idx] - mean) * inv_std;
    float affine = normalized * weight[c] + bias[c];
    output[idx] = affine / (1.0f + expf(-affine));
  }
}
""",
    "add_tensors_cfb": r"""
extern "C" __global__ void add_tensors_cfb(
    const float* lhs,
    const float* rhs,
    float* output,
    unsigned int total) {
  unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx >= total) return;
  output[idx] = lhs[idx] + rhs[idx];
}
""",
    "silu_cfb": r"""
extern "C" __global__ void silu_cfb(
    const float* input,
    float* output,
    unsigned int total) {
  unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx >= total) return;
  float value = input[idx];
  output[idx] = value / (1.0f + expf(-value));
}
""",
    "sigmoid_cfb": r"""
extern "C" __global__ void sigmoid_cfb(
    const float* input,
    float* output,
    unsigned int total) {
  unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx >= total) return;
  float value = input[idx];
  output[idx] = 1.0f / (1.0f + expf(-value));
}
""",
    "mean_over_bands_cf": r"""
extern "C" __global__ void mean_over_bands_cf(
    const float* input,
    float* output,
    unsigned int channels,
    unsigned int frames,
    unsigned int bands) {
  unsigned int frame = blockIdx.x * blockDim.x + threadIdx.x;
  unsigned int channel = blockIdx.y;
  if (frame >= frames || channel >= channels) return;

  float acc = 0.0f;
  for (unsigned int band = 0; band < bands; ++band) {
    unsigned int idx = (channel * frames + frame) * bands + band;
    acc += input[idx];
  }
  output[channel * frames + frame] = acc / (float)bands;
}
""",
}


def compile_ptx(source: str, kernel_name: str) -> bytes:
    result, program = nvrtc.nvrtcCreateProgram(source.encode(), f"{kernel_name}.cu".encode(), 0, [], [])
    if int(result) != 0:
        raise RuntimeError(f"nvrtcCreateProgram failed for {kernel_name}: {result}")

    options = [b"--gpu-architecture=compute_86"]
    compile_result = nvrtc.nvrtcCompileProgram(program, len(options), options)[0]

    log_size = nvrtc.nvrtcGetProgramLogSize(program)[1]
    log = bytearray(log_size)
    nvrtc.nvrtcGetProgramLog(program, log)
    log_text = bytes(log).decode("utf-8", "ignore").strip("\x00")
    if log_text:
        print(f"[{kernel_name}]")
        print(log_text)

    if int(compile_result) != 0:
        raise RuntimeError(f"nvrtcCompileProgram failed for {kernel_name}: {compile_result}")

    ptx_size = nvrtc.nvrtcGetPTXSize(program)[1]
    ptx = bytearray(ptx_size)
    nvrtc.nvrtcGetPTX(program, ptx)
    return bytes(ptx)


def main() -> int:
    repo_root = Path(__file__).resolve().parents[3]
    output_dir = repo_root / "src" / "gpu" / "kernels"
    output_dir.mkdir(parents=True, exist_ok=True)

    for kernel_name, source in KERNELS.items():
        output_path = output_dir / f"{kernel_name}.ptx"
        output_path.write_bytes(compile_ptx(source, kernel_name))
        print(f"[wiredeck-rnnoise] wrote PTX: {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
