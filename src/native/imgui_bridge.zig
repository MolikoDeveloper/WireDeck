const c = @import("../c.zig").c;

pub const UiChannel = extern struct {
    id: [*:0]const u8,
    label: [*:0]const u8,
    subtitle: [*:0]const u8,
    bound_source_id: [*:0]const u8,
    source_kind: c_int,
    icon_name: [*:0]const u8,
    icon_path: [*:0]const u8,
    input_bus_id: [*:0]const u8,
    meter_stage: c_int,
    level_left: f32,
    level_right: f32,
    level: f32,
    volume: f32,
    muted: c_int,
};

pub const UiBus = extern struct {
    id: [*:0]const u8,
    label: [*:0]const u8,
    role: c_int,
    hidden: c_int,
    level_left: f32,
    level_right: f32,
    level: f32,
    volume: f32,
    muted: c_int,
    system_volume: f32,
    system_muted: c_int,
    expose_as_microphone: c_int,
    share_on_network: c_int,
    dirty_flags: c_uint,
};

pub const UiSend = extern struct {
    channel_id: [*:0]const u8,
    bus_id: [*:0]const u8,
    gain: f32,
    enabled: c_int,
    pre_fader: c_int,
};

pub const UiSource = extern struct {
    id: [*:0]const u8,
    label: [*:0]const u8,
    subtitle: [*:0]const u8,
    icon_name: [*:0]const u8,
    icon_path: [*:0]const u8,
    kind: c_int,
    level_left: f32,
    level_right: f32,
    level: f32,
    muted: c_int,
};

pub const UiChannelSource = extern struct {
    channel_id: [*:0]const u8,
    source_id: [*:0]const u8,
    enabled: c_int,
};

pub const UiDestination = extern struct {
    id: [*:0]const u8,
    label: [*:0]const u8,
    subtitle: [*:0]const u8,
    kind: c_int,
    level_left: f32,
    level_right: f32,
    level: f32,
    muted: c_int,
    volume: f32,
};

pub const UiBusDestination = extern struct {
    bus_id: [*:0]const u8,
    destination_id: [*:0]const u8,
    enabled: c_int,
};

pub const UiChannelPlugin = extern struct {
    id: [*:0]const u8,
    channel_id: [*:0]const u8,
    descriptor_id: [*:0]const u8,
    label: [*:0]const u8,
    backend: c_int,
    enabled: c_int,
    slot: c_int,
};

pub const UiPluginDescriptor = extern struct {
    id: [*:0]const u8,
    label: [*:0]const u8,
    backend: c_int,
    category: [*:0]const u8,
    bundle_name: [*:0]const u8,
    has_custom_ui: c_int,
    primary_ui_uri: [*:0]const u8,
};

pub const UiChannelPluginParam = extern struct {
    plugin_id: [*:0]const u8,
    symbol: [*:0]const u8,
    label: [*:0]const u8,
    value: f32,
    min_value: f32,
    max_value: f32,
    toggled: c_int,
    integer: c_int,
};

pub const UiNoiseModel = extern struct {
    label: [*:0]const u8,
    path: [*:0]const u8,
    active: c_int,
};

pub const UiEvent = extern struct {
    label: [*:0]const u8,
};

pub const UiSnapshot = extern struct {
    active_profile: [*:0]const u8,
    channels: [*]UiChannel,
    channel_count: c_int,
    channel_feed_kind: c_int,
    buses: [*]UiBus,
    bus_count: c_int,
    sends: [*]UiSend,
    send_count: c_int,
    sources: [*]UiSource,
    source_count: c_int,
    channel_sources: [*]UiChannelSource,
    channel_source_count: c_int,
    destinations: [*]UiDestination,
    destination_count: c_int,
    destination_feed_kind: c_int,
    bus_destinations: [*]UiBusDestination,
    bus_destination_count: c_int,
    channel_plugins: [*]UiChannelPlugin,
    channel_plugin_count: c_int,
    channel_plugin_params: [*]UiChannelPluginParam,
    channel_plugin_param_count: c_int,
    noise_models: [*]UiNoiseModel,
    noise_model_count: c_int,
    plugin_descriptors: [*]UiPluginDescriptor,
    plugin_descriptor_count: c_int,
    recent_events: [*]UiEvent,
    recent_event_count: c_int,
    event_count: c_int,
    request_add_input: c_int,
    request_add_output: c_int,
    request_select_source_id: [256]u8,
    request_rename_input_id: [256]u8,
    request_rename_input_label: [256]u8,
    request_rename_output_id: [256]u8,
    request_rename_output_label: [256]u8,
    request_pick_input_icon_id: [256]u8,
    request_clear_input_icon_id: [256]u8,
    request_delete_input_id: [256]u8,
    request_delete_output_id: [256]u8,
    request_add_plugin_channel_id: [256]u8,
    request_add_plugin_descriptor_id: [256]u8,
    request_remove_plugin_id: [256]u8,
    request_move_plugin_id: [256]u8,
    request_move_plugin_delta: c_int,
    request_open_plugin_ui_id: [256]u8,
    request_select_noise_model_path: [512]u8,
};

pub const Bridge = opaque {};

pub extern fn wiredeck_imgui_create(window: *c.SDL_Window) ?*Bridge;
pub extern fn wiredeck_imgui_pump_events(bridge: *Bridge) c_int;
pub extern fn wiredeck_imgui_render_frame(bridge: *Bridge, snapshot: *UiSnapshot) c_int;
pub extern fn wiredeck_imgui_set_tray_autostart_enabled(bridge: *Bridge, enabled: c_int) void;
pub extern fn wiredeck_imgui_take_tray_autostart_request(bridge: *Bridge, enabled: *c_int) c_int;
pub extern fn wiredeck_imgui_convert_icon_path(source_path: [*:0]const u8, out_path: [*]u8, out_path_len: usize) c_int;
pub extern fn wiredeck_imgui_destroy(bridge: *Bridge) void;
pub extern fn wiredeck_imgui_last_error() ?[*:0]const u8;
