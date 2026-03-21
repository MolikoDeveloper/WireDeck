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
