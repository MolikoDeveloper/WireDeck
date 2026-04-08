#ifndef WIREDECK_OBS_OUTPUT_PROTOCOL_H
#define WIREDECK_OBS_OUTPUT_PROTOCOL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define WD_OBS_PROTOCOL_MAGIC 0x57444F42u
#define WD_OBS_PROTOCOL_VERSION 1u
#define WD_OBS_CONTROL_PORT 45931u

#define WD_OBS_MAX_OUTPUTS 32u
#define WD_OBS_MAX_ID_LEN 64u
#define WD_OBS_MAX_LABEL_LEN 96u
#define WD_OBS_MAX_CLIENT_NAME_LEN 64u
#define WD_OBS_MAX_MESSAGE_LEN 128u

#define WD_OBS_DEFAULT_CHANNELS 2u
#define WD_OBS_DEFAULT_SAMPLE_RATE 48000u
#define WD_OBS_DEFAULT_FRAMES_PER_PACKET 128u

enum wd_obs_packet_kind {
	WD_OBS_PACKET_DISCOVER_REQUEST = 1,
	WD_OBS_PACKET_DISCOVER_RESPONSE = 2,
	WD_OBS_PACKET_SUBSCRIBE_REQUEST = 3,
	WD_OBS_PACKET_SUBSCRIBE_RESPONSE = 4,
	WD_OBS_PACKET_KEEPALIVE = 5,
	WD_OBS_PACKET_GOODBYE = 6,
	WD_OBS_PACKET_AUDIO = 16,
};

enum wd_obs_audio_codec {
	WD_OBS_AUDIO_CODEC_PCM_S16LE = 1,
};

#pragma pack(push, 1)

typedef struct wd_obs_packet_header {
	uint32_t magic;
	uint8_t version;
	uint8_t kind;
	uint16_t reserved0;
	uint32_t request_id;
	uint32_t stream_id;
} wd_obs_packet_header;

typedef struct wd_obs_output_entry {
	char id[WD_OBS_MAX_ID_LEN];
	char label[WD_OBS_MAX_LABEL_LEN];
} wd_obs_output_entry;

typedef struct wd_obs_discover_request {
	wd_obs_packet_header header;
} wd_obs_discover_request;

typedef struct wd_obs_discover_response {
	wd_obs_packet_header header;
	uint16_t output_count;
	uint16_t reserved1;
	wd_obs_output_entry outputs[WD_OBS_MAX_OUTPUTS];
} wd_obs_discover_response;

typedef struct wd_obs_subscribe_request {
	wd_obs_packet_header header;
	char client_name[WD_OBS_MAX_CLIENT_NAME_LEN];
	char bus_id[WD_OBS_MAX_ID_LEN];
} wd_obs_subscribe_request;

typedef struct wd_obs_subscribe_response {
	wd_obs_packet_header header;
	uint8_t accepted;
	uint8_t channels;
	uint16_t frames_per_packet;
	uint32_t sample_rate_hz;
	char bus_id[WD_OBS_MAX_ID_LEN];
	char bus_label[WD_OBS_MAX_LABEL_LEN];
	char message[WD_OBS_MAX_MESSAGE_LEN];
} wd_obs_subscribe_response;

typedef struct wd_obs_keepalive {
	wd_obs_packet_header header;
} wd_obs_keepalive;

typedef struct wd_obs_goodbye {
	wd_obs_packet_header header;
} wd_obs_goodbye;

typedef struct wd_obs_audio_packet_header {
	wd_obs_packet_header header;
	uint8_t codec;
	uint8_t channels;
	uint16_t frames;
	uint32_t sample_rate_hz;
	uint32_t sequence;
	uint64_t sender_time_ns;
} wd_obs_audio_packet_header;

#pragma pack(pop)

#ifdef __cplusplus
}
#endif

#endif
