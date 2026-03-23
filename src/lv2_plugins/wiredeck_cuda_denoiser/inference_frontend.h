#ifndef WIREDECK_CUDA_DENOISER_INFERENCE_FRONTEND_H
#define WIREDECK_CUDA_DENOISER_INFERENCE_FRONTEND_H

#include "wdgp_runtime.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WireDeckInferenceFrontend {
  int stft_size;
  int hop_size;
  int bands;
  int fft_bins;
  int lookahead_frames;
  int temporal_frames;
  int target_frame_index;
  int temporal_frame_count;
  int write_index;
  int hop_accumulator;
  int ola_read_index;
  int ola_write_index;
  float* window;
  float* ring_buffer;
  float* fft_magnitude;
  float* fft_real;
  float* fft_imag;
  float* feature_history;
  float* spectrum_real_history;
  float* spectrum_imag_history;
  float* synthesis_frame;
  float* ola_buffer;
  float* ola_norm_buffer;
  float* shaped_mask;
  float* expanded_mask;
} WireDeckInferenceFrontend;

void wd_frontend_init(WireDeckInferenceFrontend* frontend);
void wd_frontend_deinit(WireDeckInferenceFrontend* frontend);
int wd_frontend_prepare(WireDeckInferenceFrontend* frontend, const WireDeckWdgpMetadata* metadata);
void wd_frontend_reset_state(WireDeckInferenceFrontend* frontend);
int wd_frontend_push(WireDeckInferenceFrontend* frontend, float mono_sample);
const float* wd_frontend_latest_features(WireDeckInferenceFrontend* frontend);
void wd_frontend_apply_mask_and_synthesize(WireDeckInferenceFrontend* frontend, const float* band_mask, float reduction_strength);
float wd_frontend_take_output_sample(WireDeckInferenceFrontend* frontend);

#ifdef __cplusplus
}
#endif

#endif
