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
