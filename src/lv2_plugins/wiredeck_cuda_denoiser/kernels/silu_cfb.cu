extern "C" __global__ void silu_cfb(
    const float* input,
    float* output,
    unsigned int total) {
  unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx >= total) return;
  float value = input[idx];
  output[idx] = value / (1.0f + expf(-value));
}
