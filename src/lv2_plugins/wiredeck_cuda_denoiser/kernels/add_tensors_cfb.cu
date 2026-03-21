extern "C" __global__ void add_tensors_cfb(
    const float* lhs,
    const float* rhs,
    float* output,
    unsigned int total) {
  unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx >= total) return;
  output[idx] = lhs[idx] + rhs[idx];
}
