const c = @import("../c.zig").c;
const WindowConfig = @import("window.zig").WindowConfig;

pub const SdlPlatform = struct {
    window: *c.SDL_Window,
    frame_count: u32 = 0,

    pub fn init(config: WindowConfig) !SdlPlatform {
        _ = c.SDL_SetAppMetadata("WireDeck", "0.2.0", "dev.wiredeck.app");
        _ = c.SDL_SetHint(c.SDL_HINT_APP_ID, "dev.wiredeck.app");
        _ = c.SDL_SetHint(c.SDL_HINT_APP_NAME, "WireDeck");
        _ = c.SDL_SetHint(c.SDL_HINT_QUIT_ON_LAST_WINDOW_CLOSE, "0");

        if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_GAMEPAD)) {
            return error.SdlInitFailed;
        }
        errdefer c.SDL_Quit();

        if (!c.SDL_Vulkan_LoadLibrary(null)) {
            return error.SdlVulkanLoadFailed;
        }
        errdefer c.SDL_Vulkan_UnloadLibrary();

        const properties = c.SDL_CreateProperties();
        if (properties == 0) return error.WindowCreationFailed;
        defer c.SDL_DestroyProperties(properties);

        _ = c.SDL_SetStringProperty(properties, c.SDL_PROP_WINDOW_CREATE_TITLE_STRING, config.title.ptr);
        _ = c.SDL_SetNumberProperty(properties, c.SDL_PROP_WINDOW_CREATE_WIDTH_NUMBER, config.width);
        _ = c.SDL_SetNumberProperty(properties, c.SDL_PROP_WINDOW_CREATE_HEIGHT_NUMBER, config.height);
        _ = c.SDL_SetBooleanProperty(properties, c.SDL_PROP_WINDOW_CREATE_VULKAN_BOOLEAN, true);
        _ = c.SDL_SetBooleanProperty(properties, c.SDL_PROP_WINDOW_CREATE_RESIZABLE_BOOLEAN, true);
        _ = c.SDL_SetBooleanProperty(properties, c.SDL_PROP_WINDOW_CREATE_HIGH_PIXEL_DENSITY_BOOLEAN, true);
        _ = c.SDL_SetBooleanProperty(properties, c.SDL_PROP_WINDOW_CREATE_HIDDEN_BOOLEAN, config.start_hidden);
        _ = c.SDL_SetBooleanProperty(properties, c.SDL_PROP_WINDOW_CREATE_FOCUSABLE_BOOLEAN, true);

        const window = c.SDL_CreateWindowWithProperties(properties) orelse return error.WindowCreationFailed;
        if (!config.start_hidden) {
            _ = c.SDL_ShowWindow(window);
            _ = c.SDL_RaiseWindow(window);
        }

        return .{ .window = window };
    }

    pub fn deinit(self: *SdlPlatform) void {
        c.SDL_DestroyWindow(self.window);
        c.SDL_Vulkan_UnloadLibrary();
        c.SDL_Quit();
    }

    pub fn nextFrame(self: *SdlPlatform) void {
        self.frame_count += 1;
    }
};
