#include "inference_frontend.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static float
wd_resample_linear_at(const float* input, int input_size, float position)
{
  int index0;
  int index1;
  float fraction;

  if (!input || input_size <= 0) {
    return 0.0f;
  }
  if (input_size == 1) {
    return input[0];
  }
  if (position <= 0.0f) {
    return input[0];
  }
  if (position >= (float)(input_size - 1)) {
    return input[input_size - 1];
  }

  index0 = (int)position;
  index1 = index0 + 1;
  fraction = position - (float)index0;
  return input[index0] + (input[index1] - input[index0]) * fraction;
}

static void
wd_resample_linear(const float* input, int input_size, float* output, int output_size)
{
  int output_index;

  if (!output || output_size <= 0) {
    return;
  }
  if (!input || input_size <= 0) {
    memset(output, 0, (size_t)output_size * sizeof(float));
    return;
  }
  if (input_size == output_size) {
    memcpy(output, input, (size_t)output_size * sizeof(float));
    return;
  }

  for (output_index = 0; output_index < output_size; ++output_index) {
    float position = (((float)output_index + 0.5f) * (float)input_size / (float)output_size) - 0.5f;
    output[output_index] = wd_resample_linear_at(input, input_size, position);
  }
}

static void
wd_fft_inplace(float* real, float* imag, int size, int inverse)
{
  int i;
  int j;
  int len;

  j = 0;
  for (i = 1; i < size; ++i) {
    int bit = size >> 1;
    while (j & bit) {
      j ^= bit;
      bit >>= 1;
    }
    j ^= bit;
    if (i < j) {
      float tmp_real = real[i];
      float tmp_imag = imag[i];
      real[i] = real[j];
      imag[i] = imag[j];
      real[j] = tmp_real;
      imag[j] = tmp_imag;
    }
  }

  for (len = 2; len <= size; len <<= 1) {
    float angle = (inverse ? 2.0f : -2.0f) * (float)M_PI / (float)len;
    float wlen_cos = cosf(angle);
    float wlen_sin = sinf(angle);
    int start;
    for (start = 0; start < size; start += len) {
      float w_cos = 1.0f;
      float w_sin = 0.0f;
      int half = len >> 1;
      int k;
      for (k = 0; k < half; ++k) {
        int even = start + k;
        int odd = even + half;
        float odd_real = real[odd] * w_cos - imag[odd] * w_sin;
        float odd_imag = real[odd] * w_sin + imag[odd] * w_cos;
        float even_real = real[even];
        float even_imag = imag[even];

        real[even] = even_real + odd_real;
        imag[even] = even_imag + odd_imag;
        real[odd] = even_real - odd_real;
        imag[odd] = even_imag - odd_imag;

        {
          float next_w_cos = w_cos * wlen_cos - w_sin * wlen_sin;
          float next_w_sin = w_cos * wlen_sin + w_sin * wlen_cos;
          w_cos = next_w_cos;
          w_sin = next_w_sin;
        }
      }
    }
  }

  if (inverse) {
    for (i = 0; i < size; ++i) {
      real[i] /= (float)size;
      imag[i] /= (float)size;
    }
  }
}

static void
wd_frontend_compute_spectrum(WireDeckInferenceFrontend* frontend)
{
  int k;
  int n;

  for (n = 0; n < frontend->stft_size; ++n) {
    int sample_index = (frontend->write_index + n) % frontend->stft_size;
    frontend->fft_real[n] = frontend->ring_buffer[sample_index] * frontend->window[n];
    frontend->fft_imag[n] = 0.0f;
  }

  wd_fft_inplace(frontend->fft_real, frontend->fft_imag, frontend->stft_size, 0);

  for (k = 0; k < frontend->fft_bins; ++k) {
    double real = (double)frontend->fft_real[k];
    double imag = (double)frontend->fft_imag[k];
    frontend->fft_magnitude[k] = (float)sqrt(real * real + imag * imag);
  }
}

static void
wd_frontend_compress_bands(WireDeckInferenceFrontend* frontend)
{
  int band;
  float* output;

  if (!frontend || !frontend->feature_history || frontend->temporal_frame_count <= 0) {
    return;
  }

  output = frontend->feature_history + (size_t)(frontend->temporal_frame_count - 1) * (size_t)frontend->bands;
  wd_resample_linear(frontend->fft_magnitude, frontend->fft_bins, output, frontend->bands);
  for (band = 0; band < frontend->bands; ++band) {
    output[band] = log1pf(output[band]);
  }
}

void
wd_frontend_init(WireDeckInferenceFrontend* frontend)
{
  if (!frontend) {
    return;
  }
  memset(frontend, 0, sizeof(*frontend));
}

void
wd_frontend_deinit(WireDeckInferenceFrontend* frontend)
{
  if (!frontend) {
    return;
  }
  free(frontend->window);
  free(frontend->ring_buffer);
  free(frontend->fft_magnitude);
  free(frontend->fft_real);
  free(frontend->fft_imag);
  free(frontend->feature_history);
  free(frontend->spectrum_real_history);
  free(frontend->spectrum_imag_history);
  free(frontend->synthesis_frame);
  free(frontend->ola_buffer);
  free(frontend->shaped_mask);
  free(frontend->expanded_mask);
  memset(frontend, 0, sizeof(*frontend));
}

int
wd_frontend_prepare(WireDeckInferenceFrontend* frontend, const WireDeckWdgpMetadata* metadata)
{
  int index;
  size_t temporal_feature_count;
  size_t temporal_spectrum_count;
  if (!frontend || !metadata || metadata->stft_size <= 0 || metadata->hop_size <= 0 || metadata->bands <= 0) {
    return 0;
  }

  wd_frontend_deinit(frontend);
  frontend->stft_size = metadata->stft_size;
  frontend->hop_size = metadata->hop_size;
  frontend->bands = metadata->bands;
  frontend->fft_bins = (metadata->stft_size / 2) + 1;
  frontend->lookahead_frames = metadata->lookahead_frames > 0 ? metadata->lookahead_frames : 0;
  frontend->temporal_frames = metadata->kernel_time + frontend->lookahead_frames;
  if (frontend->temporal_frames <= 0) {
    frontend->temporal_frames = 1;
  }
  temporal_feature_count = (size_t)frontend->temporal_frames * (size_t)frontend->bands;
  temporal_spectrum_count = (size_t)frontend->temporal_frames * (size_t)frontend->fft_bins;
  frontend->window = (float*)calloc((size_t)frontend->stft_size, sizeof(float));
  frontend->ring_buffer = (float*)calloc((size_t)frontend->stft_size, sizeof(float));
  frontend->fft_magnitude = (float*)calloc((size_t)frontend->fft_bins, sizeof(float));
  frontend->fft_real = (float*)calloc((size_t)frontend->stft_size, sizeof(float));
  frontend->fft_imag = (float*)calloc((size_t)frontend->stft_size, sizeof(float));
  frontend->feature_history = (float*)calloc(temporal_feature_count, sizeof(float));
  frontend->spectrum_real_history = (float*)calloc(temporal_spectrum_count, sizeof(float));
  frontend->spectrum_imag_history = (float*)calloc(temporal_spectrum_count, sizeof(float));
  frontend->synthesis_frame = (float*)calloc((size_t)frontend->stft_size, sizeof(float));
  frontend->ola_buffer = (float*)calloc((size_t)(frontend->stft_size * 4), sizeof(float));
  frontend->shaped_mask = (float*)calloc((size_t)frontend->bands, sizeof(float));
  frontend->expanded_mask = (float*)calloc((size_t)frontend->fft_bins, sizeof(float));
  if (!frontend->window || !frontend->ring_buffer || !frontend->fft_magnitude || !frontend->fft_real || !frontend->fft_imag || !frontend->feature_history || !frontend->spectrum_real_history || !frontend->spectrum_imag_history || !frontend->synthesis_frame || !frontend->ola_buffer || !frontend->shaped_mask || !frontend->expanded_mask) {
    wd_frontend_deinit(frontend);
    return 0;
  }

  for (index = 0; index < frontend->stft_size; ++index) {
    frontend->window[index] = 0.5f - 0.5f * cosf((2.0f * (float)M_PI * (float)index) / (float)frontend->stft_size);
  }

  return 1;
}

int
wd_frontend_push(WireDeckInferenceFrontend* frontend, float mono_sample)
{
  size_t feature_stride;
  size_t spectrum_stride;
  int frame_slot;
  int k;

  if (!frontend || !frontend->ring_buffer || frontend->stft_size <= 0) {
    return 0;
  }

  frontend->ring_buffer[frontend->write_index] = mono_sample;
  frontend->write_index = (frontend->write_index + 1) % frontend->stft_size;
  frontend->hop_accumulator += 1;
  if (frontend->hop_accumulator < frontend->hop_size) {
    return 0;
  }

  frontend->hop_accumulator = 0;
  wd_frontend_compute_spectrum(frontend);
  feature_stride = (size_t)frontend->bands;
  spectrum_stride = (size_t)frontend->fft_bins;
  if (frontend->temporal_frame_count >= frontend->temporal_frames) {
    memmove(
        frontend->feature_history,
        frontend->feature_history + feature_stride,
        (size_t)(frontend->temporal_frames - 1) * feature_stride * sizeof(float));
    memmove(
        frontend->spectrum_real_history,
        frontend->spectrum_real_history + spectrum_stride,
        (size_t)(frontend->temporal_frames - 1) * spectrum_stride * sizeof(float));
    memmove(
        frontend->spectrum_imag_history,
        frontend->spectrum_imag_history + spectrum_stride,
        (size_t)(frontend->temporal_frames - 1) * spectrum_stride * sizeof(float));
    frontend->temporal_frame_count = frontend->temporal_frames - 1;
  }
  frame_slot = frontend->temporal_frame_count;
  for (k = 0; k < frontend->fft_bins; ++k) {
    frontend->spectrum_real_history[(size_t)frame_slot * spectrum_stride + (size_t)k] = frontend->fft_real[k];
    frontend->spectrum_imag_history[(size_t)frame_slot * spectrum_stride + (size_t)k] = frontend->fft_imag[k];
  }
  frontend->temporal_frame_count += 1;
  wd_frontend_compress_bands(frontend);
  return frontend->temporal_frame_count >= frontend->temporal_frames;
}

const float*
wd_frontend_latest_features(WireDeckInferenceFrontend* frontend)
{
  if (!frontend) {
    return NULL;
  }
  return frontend->feature_history;
}

void
wd_frontend_apply_mask_and_synthesize(WireDeckInferenceFrontend* frontend, const float* band_mask, float reduction_strength)
{
  int fft_bins;
  int k;
  int n;
  int ola_size;
  int target_frame;
  const float* source_real;
  const float* source_imag;

  if (!frontend || !band_mask || !frontend->fft_real || !frontend->fft_imag || !frontend->synthesis_frame || !frontend->ola_buffer || !frontend->shaped_mask || !frontend->expanded_mask || frontend->temporal_frame_count <= frontend->lookahead_frames) {
    return;
  }
  if (reduction_strength < 0.0f) reduction_strength = 0.0f;
  if (reduction_strength > 1.0f) reduction_strength = 1.0f;

  for (n = 0; n < frontend->bands; ++n) {
    float model_mask = band_mask[n];
    if (model_mask < 0.0f) model_mask = 0.0f;
    if (model_mask > 1.0f) model_mask = 1.0f;
    frontend->shaped_mask[n] = 1.0f - reduction_strength * (1.0f - model_mask);
  }

  wd_resample_linear(frontend->shaped_mask, frontend->bands, frontend->expanded_mask, frontend->fft_bins);
  target_frame = frontend->temporal_frame_count - 1 - frontend->lookahead_frames;
  if (target_frame < 0) {
    target_frame = 0;
  }
  source_real = frontend->spectrum_real_history + (size_t)target_frame * (size_t)frontend->fft_bins;
  source_imag = frontend->spectrum_imag_history + (size_t)target_frame * (size_t)frontend->fft_bins;

  memset(frontend->fft_real, 0, (size_t)frontend->stft_size * sizeof(float));
  memset(frontend->fft_imag, 0, (size_t)frontend->stft_size * sizeof(float));
  fft_bins = frontend->fft_bins;
  for (k = 0; k < fft_bins; ++k) {
    float mask = frontend->expanded_mask[k];
    frontend->fft_real[k] = source_real[k] * mask;
    frontend->fft_imag[k] = source_imag[k] * mask;
  }
  for (k = fft_bins; k < frontend->stft_size; ++k) {
    int mirror = frontend->stft_size - k;
    frontend->fft_real[k] = frontend->fft_real[mirror];
    frontend->fft_imag[k] = -frontend->fft_imag[mirror];
  }

  wd_fft_inplace(frontend->fft_real, frontend->fft_imag, frontend->stft_size, 1);

  for (n = 0; n < frontend->stft_size; ++n) {
    frontend->synthesis_frame[n] = frontend->fft_real[n] * frontend->window[n];
  }

  ola_size = frontend->stft_size * 4;
  {
    int write_base = frontend->ola_read_index;
  for (n = 0; n < frontend->stft_size; ++n) {
    int dst = (write_base + n) % ola_size;
    frontend->ola_buffer[dst] += frontend->synthesis_frame[n];
  }
  frontend->ola_write_index = (write_base + frontend->hop_size) % ola_size;
  }

  if (frontend->temporal_frame_count > 0) {
    memmove(
        frontend->feature_history,
        frontend->feature_history + frontend->bands,
        (size_t)(frontend->temporal_frame_count - 1) * (size_t)frontend->bands * sizeof(float));
    memmove(
        frontend->spectrum_real_history,
        frontend->spectrum_real_history + frontend->fft_bins,
        (size_t)(frontend->temporal_frame_count - 1) * (size_t)frontend->fft_bins * sizeof(float));
    memmove(
        frontend->spectrum_imag_history,
        frontend->spectrum_imag_history + frontend->fft_bins,
        (size_t)(frontend->temporal_frame_count - 1) * (size_t)frontend->fft_bins * sizeof(float));
    frontend->temporal_frame_count -= 1;
  }
}

float
wd_frontend_take_output_sample(WireDeckInferenceFrontend* frontend)
{
  float sample;
  int ola_size;
  if (!frontend || !frontend->ola_buffer || frontend->stft_size <= 0) {
    return 0.0f;
  }
  ola_size = frontend->stft_size * 4;
  sample = frontend->ola_buffer[frontend->ola_read_index];
  frontend->ola_buffer[frontend->ola_read_index] = 0.0f;
  frontend->ola_read_index = (frontend->ola_read_index + 1) % ola_size;
  return sample;
}
