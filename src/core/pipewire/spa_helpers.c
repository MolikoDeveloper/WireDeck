#include "spa_helpers.h"

const struct spa_pod* wiredeck_spa_build_f32_capture_format(struct spa_pod_builder* builder) {
    struct spa_audio_info_raw info = SPA_AUDIO_INFO_RAW_INIT(
        .format = SPA_AUDIO_FORMAT_F32
    );
    return spa_format_audio_raw_build(builder, SPA_PARAM_EnumFormat, &info);
}

uint32_t wiredeck_spa_parse_audio_channels(const struct spa_pod* param) {
    uint32_t media_type = 0;
    uint32_t media_subtype = 0;
    struct spa_audio_info_raw info = SPA_AUDIO_INFO_RAW_INIT();

    if (param == NULL) {
        return 0;
    }
    if (spa_format_parse(param, &media_type, &media_subtype) < 0) {
        return 0;
    }
    if (media_type != SPA_MEDIA_TYPE_audio || media_subtype != SPA_MEDIA_SUBTYPE_raw) {
        return 0;
    }
    if (spa_format_audio_raw_parse(param, &info) < 0) {
        return 0;
    }
    return info.channels;
}
