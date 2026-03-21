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
