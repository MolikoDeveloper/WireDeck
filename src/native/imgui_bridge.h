#ifndef WIREDECK_IMGUI_BRIDGE_H
#define WIREDECK_IMGUI_BRIDGE_H

#include <SDL3/SDL.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WireDeckUiChannel {
    const char* id;
    const char* label;
    const char* subtitle;
    const char* bound_source_id;
    int source_kind;
    const char* icon_name;
    const char* icon_path;
    const char* input_bus_id;
    int meter_stage;
    float level_left;
    float level_right;
    float level;
    float volume;
    int muted;
} WireDeckUiChannel;

typedef struct WireDeckUiBus {
    const char* id;
    const char* label;
    int role;
    int hidden;
    float level_left;
    float level_right;
    float level;
    float volume;
    int muted;
    int expose_as_microphone;
    int expose_on_web;
} WireDeckUiBus;

typedef struct WireDeckUiSend {
    const char* channel_id;
    const char* bus_id;
    float gain;
    int enabled;
    int pre_fader;
} WireDeckUiSend;

typedef struct WireDeckUiSource {
    const char* id;
    const char* label;
    const char* subtitle;
    const char* icon_name;
    const char* icon_path;
    int kind;
    float level_left;
    float level_right;
    float level;
    int muted;
} WireDeckUiSource;

typedef struct WireDeckUiChannelSource {
    const char* channel_id;
    const char* source_id;
    int enabled;
} WireDeckUiChannelSource;

typedef struct WireDeckUiDestination {
    const char* id;
    const char* label;
    const char* subtitle;
    int kind;
    float level_left;
    float level_right;
    float level;
} WireDeckUiDestination;

typedef struct WireDeckUiBusDestination {
    const char* bus_id;
    const char* destination_id;
    int enabled;
} WireDeckUiBusDestination;

typedef struct WireDeckUiChannelPlugin {
    const char* id;
    const char* channel_id;
    const char* descriptor_id;
    const char* label;
    int backend;
    int enabled;
    int slot;
} WireDeckUiChannelPlugin;

typedef struct WireDeckUiPluginDescriptor {
    const char* id;
    const char* label;
    int backend;
    const char* category;
    const char* bundle_name;
    int has_custom_ui;
    const char* primary_ui_uri;
} WireDeckUiPluginDescriptor;

typedef struct WireDeckUiChannelPluginParam {
    const char* plugin_id;
    const char* symbol;
    const char* label;
    float value;
    float min_value;
    float max_value;
    int toggled;
    int integer;
} WireDeckUiChannelPluginParam;

typedef struct WireDeckUiNoiseModel {
    const char* label;
    const char* path;
    int active;
} WireDeckUiNoiseModel;

typedef struct WireDeckUiEvent {
    const char* label;
} WireDeckUiEvent;

typedef struct WireDeckUiSnapshot {
    const char* active_profile;
    WireDeckUiChannel* channels;
    int channel_count;
    int channel_feed_kind;
    WireDeckUiBus* buses;
    int bus_count;
    WireDeckUiSend* sends;
    int send_count;
    WireDeckUiSource* sources;
    int source_count;
    WireDeckUiChannelSource* channel_sources;
    int channel_source_count;
    WireDeckUiDestination* destinations;
    int destination_count;
    int destination_feed_kind;
    WireDeckUiBusDestination* bus_destinations;
    int bus_destination_count;
    WireDeckUiChannelPlugin* channel_plugins;
    int channel_plugin_count;
    WireDeckUiChannelPluginParam* channel_plugin_params;
    int channel_plugin_param_count;
    WireDeckUiNoiseModel* noise_models;
    int noise_model_count;
    WireDeckUiPluginDescriptor* plugin_descriptors;
    int plugin_descriptor_count;
    WireDeckUiEvent* recent_events;
    int recent_event_count;
    int event_count;
    int request_add_input;
    int request_add_output;
    char request_select_source_id[64];
    char request_rename_input_id[64];
    char request_rename_input_label[64];
    char request_rename_output_id[64];
    char request_rename_output_label[64];
    char request_pick_input_icon_id[64];
    char request_clear_input_icon_id[64];
    char request_delete_input_id[64];
    char request_delete_output_id[64];
    char request_add_plugin_channel_id[64];
    char request_add_plugin_descriptor_id[64];
    char request_remove_plugin_id[64];
    char request_move_plugin_id[64];
    int request_move_plugin_delta;
    char request_open_plugin_ui_id[64];
    char request_select_noise_model_path[512];
} WireDeckUiSnapshot;

typedef struct WireDeckImGuiBridge WireDeckImGuiBridge;

WireDeckImGuiBridge* wiredeck_imgui_create(SDL_Window* window);
int wiredeck_imgui_render_frame(WireDeckImGuiBridge* bridge, WireDeckUiSnapshot* snapshot);
int wiredeck_imgui_pump_events(WireDeckImGuiBridge* bridge);
void wiredeck_imgui_set_tray_autostart_enabled(WireDeckImGuiBridge* bridge, int enabled);
int wiredeck_imgui_take_tray_autostart_request(WireDeckImGuiBridge* bridge, int* enabled);
int wiredeck_imgui_convert_icon_path(const char* source_path, char* out_path, size_t out_path_len);
void wiredeck_imgui_destroy(WireDeckImGuiBridge* bridge);
const char* wiredeck_imgui_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
