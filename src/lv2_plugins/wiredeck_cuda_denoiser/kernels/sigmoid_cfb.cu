extern "C" __global__ void sigmoid_cfb(
    const float* input,
    float* output,
    unsigned int total) {
  unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx >= total) return;
  float value = input[idx];
  output[idx] = 1.0f / (1.0f + expf(-value));
}
