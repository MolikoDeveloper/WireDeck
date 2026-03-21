#ifndef WIREDECK_SPA_HELPERS_H
#define WIREDECK_SPA_HELPERS_H

#include <stdint.h>

#include <spa/param/audio/format-utils.h>

#ifdef __cplusplus
extern "C" {
#endif

const struct spa_pod* wiredeck_spa_build_f32_capture_format(struct spa_pod_builder* builder);
uint32_t wiredeck_spa_parse_audio_channels(const struct spa_pod* param);

#ifdef __cplusplus
}
#endif

#endif
