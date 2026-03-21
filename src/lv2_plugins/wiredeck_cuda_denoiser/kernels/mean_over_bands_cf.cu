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
