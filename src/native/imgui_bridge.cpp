#include "imgui_bridge.h"

#include <SDL3/SDL_tray.h>
#include <SDL3/SDL_vulkan.h>
#if __has_include(<MagickWand/MagickWand.h>)
#include <MagickWand/MagickWand.h>
#elif __has_include(<wand/MagickWand.h>)
#include <wand/MagickWand.h>
#else
#error "MagickWand header not found"
#endif
#include <png.h>
#include <vulkan/vulkan.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cctype>
#include <cstdlib>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <functional>
#include <string>
#include <unordered_map>
#include <vector>

#include "imgui.h"
#include "imgui_impl_sdl3.h"
#include "imgui_impl_vulkan.h"

std::string g_last_error;

constexpr unsigned int kUiBusDirtyVolume = 1u << 0;
constexpr unsigned int kUiBusDirtyMuted = 1u << 1;
constexpr unsigned int kUiBusDirtyExposeAsMicrophone = 1u << 2;
constexpr unsigned int kUiBusDirtyShareOnNetwork = 1u << 3;

bool safe_streq(const char *a, const char *b)
{
    if (a == nullptr || b == nullptr)
    {
        return false;
    }
    return std::strcmp(a, b) == 0;
}

struct WireDeckIconTexture
{
    VkImage image = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkImageView image_view = VK_NULL_HANDLE;
    VkSampler sampler = VK_NULL_HANDLE;
    VkDescriptorSet descriptor_set = VK_NULL_HANDLE;
    int width = 0;
    int height = 0;
};

struct LoadedPng
{
    std::vector<unsigned char> pixels{};
    int width = 0;
    int height = 0;
};

struct WireDeckCachedIcon
{
    std::string cache_key{};
    WireDeckIconTexture texture{};
};

struct WireDeckMeterVisualState
{
    float current_left = 0.0f;
    float current_right = 0.0f;
    float peak_left = 0.0f;
    float peak_right = 0.0f;
    int peak_hold_left = 0;
    int peak_hold_right = 0;
};

struct WireDeckImGuiBridge
{
    SDL_Window *window = nullptr;
    SDL_Tray *tray = nullptr;
    SDL_TrayMenu *tray_menu = nullptr;
    SDL_TrayEntry *tray_toggle_entry = nullptr;
    SDL_TrayEntry *tray_autostart_entry = nullptr;
    SDL_TrayEntry *tray_quit_entry = nullptr;
    SDL_Surface *tray_icon_surface = nullptr;
    VkAllocationCallbacks *allocator = nullptr;
    VkInstance instance = VK_NULL_HANDLE;
    VkPhysicalDevice physical_device = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    uint32_t queue_family = UINT32_MAX;
    VkQueue queue = VK_NULL_HANDLE;
    VkDescriptorPool descriptor_pool = VK_NULL_HANDLE;
    VkPipelineCache pipeline_cache = VK_NULL_HANDLE;
    ImGui_ImplVulkanH_Window main_window_data{};
    uint32_t min_image_count = 2;
    bool swapchain_rebuild = false;
    int frame_index = 0;
    std::array<float, 180> activity_history{};
    std::array<char, 64> rename_buffer{};
    std::array<char, 256> fx_plugin_filter{};
    bool focus_rename_input = false;
    bool tray_autostart_enabled = false;
    bool pending_autostart_change = false;
    bool pending_quit = false;
    WireDeckIconTexture volume_icon{};
    WireDeckIconTexture volume_off_icon{};
    WireDeckIconTexture fx_icon{};
    WireDeckIconTexture mic_icon{};
    WireDeckIconTexture mic_off_icon{};
    WireDeckIconTexture world_icon{};
    WireDeckIconTexture world_off_icon{};
    WireDeckIconTexture trash_icon{};
    WireDeckIconTexture toggle_left_icon{};
    WireDeckIconTexture toggle_right_icon{};
    WireDeckIconTexture config_icon{};
    WireDeckIconTexture headset_icon{};
    WireDeckIconTexture generic_app_icon{};
    std::vector<WireDeckCachedIcon> source_icons{};
    std::unordered_map<std::string, WireDeckMeterVisualState> source_meter_states{};
    std::unordered_map<std::string, bool> fx_group_open{};
};

namespace
{

    SDL_Surface *load_png_surface(const char *path);
    std::string find_wiredeck_icon_path();

    void set_error(const char *message)
    {
        g_last_error = message ? message : "unknown error";
    }

    void set_error(const std::string &message)
    {
        g_last_error = message;
    }

    bool is_window_hidden(SDL_Window *window)
    {
        return (SDL_GetWindowFlags(window) & SDL_WINDOW_HIDDEN) != 0;
    }

    void sync_tray_toggle_label(WireDeckImGuiBridge *bridge)
    {
        if (bridge == nullptr || bridge->tray_toggle_entry == nullptr || bridge->window == nullptr)
        {
            return;
        }
        SDL_SetTrayEntryLabel(bridge->tray_toggle_entry, is_window_hidden(bridge->window) ? "Show WireDeck" : "Hide WireDeck");
    }

    void set_window_visible(WireDeckImGuiBridge *bridge, bool visible)
    {
        if (bridge == nullptr || bridge->window == nullptr)
        {
            return;
        }

        if (visible)
        {
            SDL_ShowWindow(bridge->window);
            SDL_RaiseWindow(bridge->window);
        }
        else
        {
            SDL_HideWindow(bridge->window);
        }

        sync_tray_toggle_label(bridge);
    }

    void SDLCALL handle_tray_toggle(void *userdata, SDL_TrayEntry *)
    {
        auto *bridge = static_cast<WireDeckImGuiBridge *>(userdata);
        if (bridge == nullptr)
        {
            return;
        }
        set_window_visible(bridge, is_window_hidden(bridge->window));
    }

    void SDLCALL handle_tray_autostart(void *userdata, SDL_TrayEntry *entry)
    {
        auto *bridge = static_cast<WireDeckImGuiBridge *>(userdata);
        if (bridge == nullptr)
        {
            return;
        }
        bridge->tray_autostart_enabled = !bridge->tray_autostart_enabled;
        if (entry != nullptr)
        {
            SDL_SetTrayEntryChecked(entry, bridge->tray_autostart_enabled);
        }
        bridge->pending_autostart_change = true;
    }

    void SDLCALL handle_tray_quit(void *userdata, SDL_TrayEntry *)
    {
        auto *bridge = static_cast<WireDeckImGuiBridge *>(userdata);
        if (bridge == nullptr)
        {
            return;
        }
        bridge->pending_quit = true;
    }

    SDL_Surface *create_tray_icon_surface()
    {
        const auto icon_path = find_wiredeck_icon_path();
        if (!icon_path.empty())
        {
            if (SDL_Surface *custom_surface = load_png_surface(icon_path.c_str()))
            {
                if (custom_surface->w != 32 || custom_surface->h != 32)
                {
                    SDL_Surface *scaled = SDL_ScaleSurface(custom_surface, 32, 32, SDL_SCALEMODE_LINEAR);
                    if (scaled != nullptr)
                    {
                        SDL_DestroySurface(custom_surface);
                        return scaled;
                    }
                }
                return custom_surface;
            }
        }

        SDL_Surface *fallback = SDL_CreateSurface(32, 32, SDL_PIXELFORMAT_RGBA8888);
        if (fallback == nullptr)
        {
            return nullptr;
        }

        const Uint32 transparent = SDL_MapSurfaceRGBA(fallback, 0, 0, 0, 0);
        const Uint32 panel = SDL_MapSurfaceRGBA(fallback, 22, 24, 30, 255);
        const Uint32 accent = SDL_MapSurfaceRGBA(fallback, 231, 208, 86, 255);
        const Uint32 detail = SDL_MapSurfaceRGBA(fallback, 245, 245, 245, 255);

        SDL_FillSurfaceRect(fallback, nullptr, transparent);
        const SDL_Rect background{4, 4, 24, 24};
        const SDL_Rect bar_left{9, 18, 4, 6};
        const SDL_Rect bar_mid{14, 13, 4, 11};
        const SDL_Rect bar_right{19, 9, 4, 15};
        const SDL_Rect top_line{8, 8, 15, 2};
        SDL_FillSurfaceRect(fallback, &background, panel);
        SDL_FillSurfaceRect(fallback, &bar_left, accent);
        SDL_FillSurfaceRect(fallback, &bar_mid, accent);
        SDL_FillSurfaceRect(fallback, &bar_right, accent);
        SDL_FillSurfaceRect(fallback, &top_line, detail);
        return fallback;
    }

    bool setup_tray(WireDeckImGuiBridge *bridge)
    {
        bridge->tray_icon_surface = create_tray_icon_surface();
        bridge->tray = SDL_CreateTray(bridge->tray_icon_surface, "WireDeck");
        if (bridge->tray == nullptr)
        {
            if (bridge->tray_icon_surface != nullptr)
            {
                SDL_DestroySurface(bridge->tray_icon_surface);
                bridge->tray_icon_surface = nullptr;
            }
            return false;
        }

        bridge->tray_menu = SDL_CreateTrayMenu(bridge->tray);
        if (bridge->tray_menu == nullptr)
        {
            return false;
        }

        bridge->tray_toggle_entry = SDL_InsertTrayEntryAt(bridge->tray_menu, -1, "Hide WireDeck", SDL_TRAYENTRY_BUTTON);
        bridge->tray_autostart_entry = SDL_InsertTrayEntryAt(bridge->tray_menu, -1, "Start automatically", SDL_TRAYENTRY_CHECKBOX);
        SDL_InsertTrayEntryAt(bridge->tray_menu, -1, nullptr, SDL_TRAYENTRY_BUTTON);
        bridge->tray_quit_entry = SDL_InsertTrayEntryAt(bridge->tray_menu, -1, "Quit", SDL_TRAYENTRY_BUTTON);

        if (bridge->tray_toggle_entry == nullptr || bridge->tray_autostart_entry == nullptr || bridge->tray_quit_entry == nullptr)
        {
            return false;
        }

        SDL_SetTrayEntryCallback(bridge->tray_toggle_entry, handle_tray_toggle, bridge);
        SDL_SetTrayEntryCallback(bridge->tray_autostart_entry, handle_tray_autostart, bridge);
        SDL_SetTrayEntryCallback(bridge->tray_quit_entry, handle_tray_quit, bridge);
        SDL_SetTrayEntryChecked(bridge->tray_autostart_entry, false);
        sync_tray_toggle_label(bridge);
        return true;
    }

    bool is_extension_available(const std::vector<VkExtensionProperties> &properties, const char *extension)
    {
        for (const auto &property : properties)
        {
            if (std::strcmp(property.extensionName, extension) == 0)
            {
                return true;
            }
        }
        return false;
    }

    bool check_vk_result(VkResult err, const char *step)
    {
        if (err == VK_SUCCESS)
        {
            return true;
        }
        set_error(std::string(step) + " failed with VkResult=" + std::to_string(static_cast<int>(err)));
        return false;
    }

    void ensure_magickwand_initialized()
    {
        static bool initialized = false;
        if (!initialized)
        {
            MagickWandGenesis();
            initialized = true;
        }
    }

    uint64_t fnv1a_hash(const std::string &value)
    {
        uint64_t hash = 1469598103934665603ull;
        for (unsigned char ch : value)
        {
            hash ^= static_cast<uint64_t>(ch);
            hash *= 1099511628211ull;
        }
        return hash;
    }

    std::filesystem::path executable_dir()
    {
        std::error_code ec{};
        const auto exe_path = std::filesystem::read_symlink("/proc/self/exe", ec);
        if (ec)
        {
            return {};
        }
        return exe_path.parent_path();
    }

    std::string find_wiredeck_asset_path(const std::filesystem::path &relative_path)
    {
        const auto exe_dir = executable_dir();
        const std::array<std::filesystem::path, 4> candidates = {
            exe_dir.empty() ? std::filesystem::path{} : (exe_dir / "../share/wiredeck" / relative_path),
            exe_dir.empty() ? std::filesystem::path{} : (exe_dir / "../share" / relative_path),
            relative_path,
            std::filesystem::path("src") / relative_path,
        };

        for (const auto &candidate : candidates)
        {
            if (candidate.empty())
                continue;

            std::error_code ec{};
            if (std::filesystem::is_regular_file(candidate, ec) && !ec)
            {
                return candidate.string();
            }
        }

        return {};
    }

    std::string find_wiredeck_icon_path()
    {
        if (const auto asset_icon = find_wiredeck_asset_path("assets/icons/wiredeck.png"); !asset_icon.empty())
        {
            return asset_icon;
        }

        const auto exe_dir = executable_dir();
        const std::array<std::filesystem::path, 4> candidates = {
            exe_dir.empty() ? std::filesystem::path{} : (exe_dir / "../share/pixmaps/wiredeck.png"),
            exe_dir.empty() ? std::filesystem::path{} : (exe_dir / "../share/icons/hicolor/256x256/apps/wiredeck.png"),
            "/usr/local/share/pixmaps/wiredeck.png",
            "/usr/share/pixmaps/wiredeck.png",
        };

        for (const auto &candidate : candidates)
        {
            if (candidate.empty())
                continue;

            std::error_code ec{};
            if (std::filesystem::is_regular_file(candidate, ec) && !ec)
            {
                return candidate.string();
            }
        }

        return {};
    }

    std::filesystem::path wiredeck_icon_cache_dir()
    {
        const char *xdg_config_home = std::getenv("XDG_CONFIG_HOME");
        if (xdg_config_home != nullptr && xdg_config_home[0] != '\0')
        {
            return std::filesystem::path(xdg_config_home) / "wiredeck" / "icons";
        }

        const char *home = std::getenv("HOME");
        if (home != nullptr && home[0] != '\0')
        {
            return std::filesystem::path(home) / ".config" / "wiredeck" / "icons";
        }

        return std::filesystem::temp_directory_path() / "wiredeck-icons";
    }

    std::string magick_exception_message(MagickWand *wand)
    {
        if (wand == nullptr)
        {
            return "unknown";
        }

        ExceptionType severity = UndefinedException;
        char *exception = MagickGetException(wand, &severity);
        std::string message = exception != nullptr ? exception : "unknown";
        if (exception != nullptr)
        {
            MagickRelinquishMemory(exception);
        }
        (void)severity;
        return message;
    }

    bool rasterize_icon_to_cache(const std::filesystem::path &source_path, std::filesystem::path *out_png_path)
    {
        std::error_code ec{};
        const auto cache_dir = wiredeck_icon_cache_dir();
        std::filesystem::create_directories(cache_dir, ec);
        if (ec)
        {
            set_error(std::string("failed to create icon cache dir: ") + cache_dir.string());
            return false;
        }

        const auto cache_hash = fnv1a_hash(std::string("v3:") + source_path.string());
        *out_png_path = cache_dir / (std::to_string(cache_hash) + ".png");
        if (std::filesystem::exists(*out_png_path))
        {
            return true;
        }

        ensure_magickwand_initialized();
        MagickWand *wand = NewMagickWand();
        if (wand == nullptr)
        {
            set_error("NewMagickWand failed");
            return false;
        }

        PixelWand *background = NewPixelWand();
        if (background != nullptr)
        {
            (void)PixelSetColor(background, "none");
            (void)MagickSetBackgroundColor(wand, background);
        }
        (void)MagickSetOption(wand, "background", "none");
        (void)MagickSetOption(wand, "svg:background-color", "none");

        const std::string source_text = source_path.string();
        const MagickBooleanType read_ok = MagickReadImage(wand, source_text.c_str());
        if (read_ok == MagickFalse)
        {
            set_error(std::string("MagickReadImage failed for ") + source_text + ": " + magick_exception_message(wand));
            if (background != nullptr)
            {
                DestroyPixelWand(background);
            }
            DestroyMagickWand(wand);
            return false;
        }

        if (background != nullptr)
        {
            (void)MagickSetImageBackgroundColor(wand, background);
            DestroyPixelWand(background);
        }
        (void)MagickSetImageAlphaChannel(wand, ActivateAlphaChannel);
        (void)MagickSetImageFormat(wand, "PNG32");

        const size_t width = MagickGetImageWidth(wand);
        const size_t height = MagickGetImageHeight(wand);
        const size_t max_dimension = 96;
        if (width > 0 && height > 0)
        {
            const double scale = static_cast<double>(max_dimension) / static_cast<double>(std::max(width, height));
            const size_t target_width = std::max<size_t>(1, static_cast<size_t>(std::round(static_cast<double>(width) * std::min(1.0, scale))));
            const size_t target_height = std::max<size_t>(1, static_cast<size_t>(std::round(static_cast<double>(height) * std::min(1.0, scale))));
            if (target_width != width || target_height != height)
            {
                (void)MagickResizeImage(wand, target_width, target_height, LanczosFilter, 1.0);
            }
        }

        const std::string output_text = out_png_path->string();
        const MagickBooleanType write_ok = MagickWriteImage(wand, output_text.c_str());
        if (write_ok == MagickFalse)
        {
            set_error(std::string("MagickWriteImage failed for ") + output_text + ": " + magick_exception_message(wand));
            DestroyMagickWand(wand);
            return false;
        }

        DestroyMagickWand(wand);
        return true;
    }

    bool resolve_renderable_icon_path(const char *source_path, std::string *out_path)
    {
        if (source_path == nullptr || source_path[0] == '\0')
        {
            return false;
        }

        const std::filesystem::path input(source_path);
        const std::string extension = input.extension().string();
        if (extension == ".png" || extension == ".PNG")
        {
            *out_path = input.string();
            return true;
        }

        std::filesystem::path cached_png{};
        if (rasterize_icon_to_cache(input, &cached_png))
        {
            *out_path = cached_png.string();
            return true;
        }

        return false;
    }

    bool load_png_rgba(const char *path, LoadedPng *out)
    {
        FILE *file = std::fopen(path, "rb");
        if (file == nullptr)
        {
            set_error(std::string("failed to open icon: ") + path);
            return false;
        }

        png_byte header[8]{};
        if (std::fread(header, 1, sizeof(header), file) != sizeof(header) || png_sig_cmp(header, 0, sizeof(header)) != 0)
        {
            std::fclose(file);
            set_error(std::string("invalid png icon: ") + path);
            return false;
        }

        png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, nullptr);
        if (png == nullptr)
        {
            std::fclose(file);
            set_error("png_create_read_struct failed");
            return false;
        }

        png_infop info = png_create_info_struct(png);
        if (info == nullptr)
        {
            png_destroy_read_struct(&png, nullptr, nullptr);
            std::fclose(file);
            set_error("png_create_info_struct failed");
            return false;
        }

        if (setjmp(png_jmpbuf(png)) != 0)
        {
            png_destroy_read_struct(&png, &info, nullptr);
            std::fclose(file);
            set_error(std::string("failed to decode png icon: ") + path);
            return false;
        }

        png_init_io(png, file);
        png_set_sig_bytes(png, sizeof(header));
        png_read_info(png, info);

        png_uint_32 width = 0;
        png_uint_32 height = 0;
        int bit_depth = 0;
        int color_type = 0;
        png_get_IHDR(png, info, &width, &height, &bit_depth, &color_type, nullptr, nullptr, nullptr);

        if (bit_depth == 16)
        {
            png_set_strip_16(png);
        }
        if (color_type == PNG_COLOR_TYPE_PALETTE)
        {
            png_set_palette_to_rgb(png);
        }
        if (color_type == PNG_COLOR_TYPE_GRAY && bit_depth < 8)
        {
            png_set_expand_gray_1_2_4_to_8(png);
        }
        if (png_get_valid(png, info, PNG_INFO_tRNS) != 0)
        {
            png_set_tRNS_to_alpha(png);
        }
        if (color_type == PNG_COLOR_TYPE_RGB || color_type == PNG_COLOR_TYPE_GRAY || color_type == PNG_COLOR_TYPE_PALETTE)
        {
            png_set_filler(png, 0xFF, PNG_FILLER_AFTER);
        }
        if (color_type == PNG_COLOR_TYPE_GRAY || color_type == PNG_COLOR_TYPE_GRAY_ALPHA)
        {
            png_set_gray_to_rgb(png);
        }

        png_read_update_info(png, info);

        const png_size_t row_bytes = png_get_rowbytes(png, info);
        out->pixels.resize(static_cast<size_t>(row_bytes) * static_cast<size_t>(height));
        std::vector<png_bytep> rows(static_cast<size_t>(height));
        for (png_uint_32 row = 0; row < height; ++row)
        {
            rows[static_cast<size_t>(row)] = out->pixels.data() + static_cast<size_t>(row) * row_bytes;
        }

        png_read_image(png, rows.data());
        png_read_end(png, nullptr);
        png_destroy_read_struct(&png, &info, nullptr);
        std::fclose(file);

        out->width = static_cast<int>(width);
        out->height = static_cast<int>(height);
        return true;
    }

    SDL_Surface *load_png_surface(const char *path)
    {
        LoadedPng loaded{};
        if (!load_png_rgba(path, &loaded))
        {
            return nullptr;
        }

        SDL_Surface *surface = SDL_CreateSurface(loaded.width, loaded.height, SDL_PIXELFORMAT_RGBA8888);
        if (surface == nullptr)
        {
            set_error("SDL_CreateSurface failed for icon surface");
            return nullptr;
        }

        const auto src_pitch = static_cast<size_t>(loaded.width) * 4;
        const auto dst_pitch = static_cast<size_t>(surface->pitch);
        auto *dst_pixels = static_cast<unsigned char *>(surface->pixels);
        for (int row = 0; row < loaded.height; ++row)
        {
            std::memcpy(
                dst_pixels + static_cast<size_t>(row) * dst_pitch,
                loaded.pixels.data() + static_cast<size_t>(row) * src_pitch,
                std::min(src_pitch, dst_pitch));
        }

        return surface;
    }

    uint32_t find_memory_type(WireDeckImGuiBridge *bridge, uint32_t type_filter, VkMemoryPropertyFlags properties)
    {
        VkPhysicalDeviceMemoryProperties mem_properties{};
        vkGetPhysicalDeviceMemoryProperties(bridge->physical_device, &mem_properties);
        for (uint32_t i = 0; i < mem_properties.memoryTypeCount; ++i)
        {
            if ((type_filter & (1u << i)) && (mem_properties.memoryTypes[i].propertyFlags & properties) == properties)
            {
                return i;
            }
        }
        return UINT32_MAX;
    }

    bool execute_immediate_commands(WireDeckImGuiBridge *bridge, const std::function<void(VkCommandBuffer)> &recorder)
    {
        VkCommandPool command_pool = VK_NULL_HANDLE;
        VkCommandBuffer command_buffer = VK_NULL_HANDLE;

        VkCommandPoolCreateInfo pool_info{};
        pool_info.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        pool_info.flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT;
        pool_info.queueFamilyIndex = bridge->queue_family;
        if (!check_vk_result(vkCreateCommandPool(bridge->device, &pool_info, bridge->allocator, &command_pool), "vkCreateCommandPool(icon upload)"))
        {
            return false;
        }

        VkCommandBufferAllocateInfo alloc_info{};
        alloc_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        alloc_info.commandPool = command_pool;
        alloc_info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        alloc_info.commandBufferCount = 1;
        if (!check_vk_result(vkAllocateCommandBuffers(bridge->device, &alloc_info, &command_buffer), "vkAllocateCommandBuffers(icon upload)"))
        {
            vkDestroyCommandPool(bridge->device, command_pool, bridge->allocator);
            return false;
        }

        VkCommandBufferBeginInfo begin_info{};
        begin_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin_info.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        if (!check_vk_result(vkBeginCommandBuffer(command_buffer, &begin_info), "vkBeginCommandBuffer(icon upload)"))
        {
            vkDestroyCommandPool(bridge->device, command_pool, bridge->allocator);
            return false;
        }

        recorder(command_buffer);

        if (!check_vk_result(vkEndCommandBuffer(command_buffer), "vkEndCommandBuffer(icon upload)"))
        {
            vkDestroyCommandPool(bridge->device, command_pool, bridge->allocator);
            return false;
        }

        VkSubmitInfo submit_info{};
        submit_info.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit_info.commandBufferCount = 1;
        submit_info.pCommandBuffers = &command_buffer;
        const bool ok = check_vk_result(vkQueueSubmit(bridge->queue, 1, &submit_info, VK_NULL_HANDLE), "vkQueueSubmit(icon upload)") &&
                        check_vk_result(vkQueueWaitIdle(bridge->queue), "vkQueueWaitIdle(icon upload)");
        vkDestroyCommandPool(bridge->device, command_pool, bridge->allocator);
        return ok;
    }

    void destroy_icon_texture(WireDeckImGuiBridge *bridge, WireDeckIconTexture *texture)
    {
        if (texture->descriptor_set != VK_NULL_HANDLE)
        {
            ImGui_ImplVulkan_RemoveTexture(texture->descriptor_set);
            texture->descriptor_set = VK_NULL_HANDLE;
        }
        if (texture->sampler != VK_NULL_HANDLE)
        {
            vkDestroySampler(bridge->device, texture->sampler, bridge->allocator);
            texture->sampler = VK_NULL_HANDLE;
        }
        if (texture->image_view != VK_NULL_HANDLE)
        {
            vkDestroyImageView(bridge->device, texture->image_view, bridge->allocator);
            texture->image_view = VK_NULL_HANDLE;
        }
        if (texture->image != VK_NULL_HANDLE)
        {
            vkDestroyImage(bridge->device, texture->image, bridge->allocator);
            texture->image = VK_NULL_HANDLE;
        }
        if (texture->memory != VK_NULL_HANDLE)
        {
            vkFreeMemory(bridge->device, texture->memory, bridge->allocator);
            texture->memory = VK_NULL_HANDLE;
        }
        texture->width = 0;
        texture->height = 0;
    }

    bool load_icon_texture(WireDeckImGuiBridge *bridge, const char *path, WireDeckIconTexture *texture)
    {
        LoadedPng loaded{};
        if (!load_png_rgba(path, &loaded))
        {
            return false;
        }

        const int width = loaded.width;
        const int height = loaded.height;
        const VkDeviceSize upload_size = static_cast<VkDeviceSize>(width) * static_cast<VkDeviceSize>(height) * 4;

        VkBuffer staging_buffer = VK_NULL_HANDLE;
        VkDeviceMemory staging_memory = VK_NULL_HANDLE;

        VkBufferCreateInfo buffer_info{};
        buffer_info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        buffer_info.size = upload_size;
        buffer_info.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
        buffer_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        if (!check_vk_result(vkCreateBuffer(bridge->device, &buffer_info, bridge->allocator, &staging_buffer), "vkCreateBuffer(icon staging)"))
        {
            return false;
        }

        VkMemoryRequirements staging_requirements{};
        vkGetBufferMemoryRequirements(bridge->device, staging_buffer, &staging_requirements);
        VkMemoryAllocateInfo staging_alloc{};
        staging_alloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        staging_alloc.allocationSize = staging_requirements.size;
        staging_alloc.memoryTypeIndex = find_memory_type(bridge, staging_requirements.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        if (staging_alloc.memoryTypeIndex == UINT32_MAX ||
            !check_vk_result(vkAllocateMemory(bridge->device, &staging_alloc, bridge->allocator, &staging_memory), "vkAllocateMemory(icon staging)"))
        {
            vkDestroyBuffer(bridge->device, staging_buffer, bridge->allocator);
            return false;
        }
        vkBindBufferMemory(bridge->device, staging_buffer, staging_memory, 0);

        void *mapped = nullptr;
        if (!check_vk_result(vkMapMemory(bridge->device, staging_memory, 0, upload_size, 0, &mapped), "vkMapMemory(icon staging)"))
        {
            vkDestroyBuffer(bridge->device, staging_buffer, bridge->allocator);
            vkFreeMemory(bridge->device, staging_memory, bridge->allocator);
            return false;
        }
        std::memcpy(mapped, loaded.pixels.data(), static_cast<size_t>(upload_size));
        vkUnmapMemory(bridge->device, staging_memory);

        VkImageCreateInfo image_info{};
        image_info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        image_info.imageType = VK_IMAGE_TYPE_2D;
        image_info.extent.width = static_cast<uint32_t>(width);
        image_info.extent.height = static_cast<uint32_t>(height);
        image_info.extent.depth = 1;
        image_info.mipLevels = 1;
        image_info.arrayLayers = 1;
        image_info.format = VK_FORMAT_R8G8B8A8_UNORM;
        image_info.tiling = VK_IMAGE_TILING_OPTIMAL;
        image_info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        image_info.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
        image_info.samples = VK_SAMPLE_COUNT_1_BIT;
        image_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        if (!check_vk_result(vkCreateImage(bridge->device, &image_info, bridge->allocator, &texture->image), "vkCreateImage(icon)"))
        {
            vkDestroyBuffer(bridge->device, staging_buffer, bridge->allocator);
            vkFreeMemory(bridge->device, staging_memory, bridge->allocator);
            return false;
        }

        VkMemoryRequirements image_requirements{};
        vkGetImageMemoryRequirements(bridge->device, texture->image, &image_requirements);
        VkMemoryAllocateInfo image_alloc{};
        image_alloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        image_alloc.allocationSize = image_requirements.size;
        image_alloc.memoryTypeIndex = find_memory_type(bridge, image_requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        if (image_alloc.memoryTypeIndex == UINT32_MAX ||
            !check_vk_result(vkAllocateMemory(bridge->device, &image_alloc, bridge->allocator, &texture->memory), "vkAllocateMemory(icon image)"))
        {
            destroy_icon_texture(bridge, texture);
            vkDestroyBuffer(bridge->device, staging_buffer, bridge->allocator);
            vkFreeMemory(bridge->device, staging_memory, bridge->allocator);
            return false;
        }
        vkBindImageMemory(bridge->device, texture->image, texture->memory, 0);

        if (!execute_immediate_commands(bridge, [&](VkCommandBuffer command_buffer)
                                        {
        VkImageMemoryBarrier to_transfer{};
        to_transfer.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        to_transfer.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        to_transfer.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        to_transfer.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        to_transfer.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        to_transfer.image = texture->image;
        to_transfer.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        to_transfer.subresourceRange.levelCount = 1;
        to_transfer.subresourceRange.layerCount = 1;
        to_transfer.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        vkCmdPipelineBarrier(command_buffer, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &to_transfer);

        VkBufferImageCopy region{};
        region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.layerCount = 1;
        region.imageExtent.width = static_cast<uint32_t>(width);
        region.imageExtent.height = static_cast<uint32_t>(height);
        region.imageExtent.depth = 1;
        vkCmdCopyBufferToImage(command_buffer, staging_buffer, texture->image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

        VkImageMemoryBarrier to_shader{};
        to_shader.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        to_shader.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        to_shader.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        to_shader.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        to_shader.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        to_shader.image = texture->image;
        to_shader.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        to_shader.subresourceRange.levelCount = 1;
        to_shader.subresourceRange.layerCount = 1;
        to_shader.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        to_shader.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
        vkCmdPipelineBarrier(command_buffer, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, nullptr, 0, nullptr, 1, &to_shader); }))
        {
            destroy_icon_texture(bridge, texture);
            vkDestroyBuffer(bridge->device, staging_buffer, bridge->allocator);
            vkFreeMemory(bridge->device, staging_memory, bridge->allocator);
            return false;
        }

        vkDestroyBuffer(bridge->device, staging_buffer, bridge->allocator);
        vkFreeMemory(bridge->device, staging_memory, bridge->allocator);

        VkImageViewCreateInfo view_info{};
        view_info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = texture->image;
        view_info.viewType = VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = VK_FORMAT_R8G8B8A8_UNORM;
        view_info.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        view_info.subresourceRange.levelCount = 1;
        view_info.subresourceRange.layerCount = 1;
        if (!check_vk_result(vkCreateImageView(bridge->device, &view_info, bridge->allocator, &texture->image_view), "vkCreateImageView(icon)"))
        {
            destroy_icon_texture(bridge, texture);
            return false;
        }

        VkSamplerCreateInfo sampler_info{};
        sampler_info.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        sampler_info.magFilter = VK_FILTER_LINEAR;
        sampler_info.minFilter = VK_FILTER_LINEAR;
        sampler_info.mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR;
        sampler_info.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.maxAnisotropy = 1.0f;
        sampler_info.minLod = 0.0f;
        sampler_info.maxLod = 1.0f;
        if (!check_vk_result(vkCreateSampler(bridge->device, &sampler_info, bridge->allocator, &texture->sampler), "vkCreateSampler(icon)"))
        {
            destroy_icon_texture(bridge, texture);
            return false;
        }

        texture->descriptor_set = ImGui_ImplVulkan_AddTexture(texture->sampler, texture->image_view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
        texture->width = width;
        texture->height = height;
        return true;
    }

    bool load_icon_textures(WireDeckImGuiBridge *bridge)
    {
        const auto volume_path = find_wiredeck_asset_path("assets/icons/volume.png");
        const auto volume_off_path = find_wiredeck_asset_path("assets/icons/volume-off.png");
        const auto fx_path = find_wiredeck_asset_path("assets/icons/wave-saw-tool.png");
        const auto mic_path = find_wiredeck_asset_path("assets/icons/mic.png");
        const auto mic_off_path = find_wiredeck_asset_path("assets/icons/mic-off.png");
        const auto world_path = find_wiredeck_asset_path("assets/icons/world.png");
        const auto world_off_path = find_wiredeck_asset_path("assets/icons/world-off.png");
        const auto trash_path = find_wiredeck_asset_path("assets/icons/trash.png");
        const auto toggle_left_path = find_wiredeck_asset_path("assets/icons/toggle-left.png");
        const auto toggle_right_path = find_wiredeck_asset_path("assets/icons/toggle-right.png");
        const auto config_path = find_wiredeck_asset_path("assets/icons/config.png");
        const auto headset_path = find_wiredeck_asset_path("assets/icons/headset.png");
        const auto generic_app_path = find_wiredeck_asset_path("assets/icons/generic-app.png");

        const bool loaded_volume = !volume_path.empty() && load_icon_texture(bridge, volume_path.c_str(), &bridge->volume_icon);
        const bool loaded_volume_off = !volume_off_path.empty() && load_icon_texture(bridge, volume_off_path.c_str(), &bridge->volume_off_icon);
        const bool loaded_fx = !fx_path.empty() && load_icon_texture(bridge, fx_path.c_str(), &bridge->fx_icon);
        const bool loaded_mic = !mic_path.empty() && load_icon_texture(bridge, mic_path.c_str(), &bridge->mic_icon);
        const bool loaded_mic_off = !mic_off_path.empty() && load_icon_texture(bridge, mic_off_path.c_str(), &bridge->mic_off_icon);
        const bool loaded_world = !world_path.empty() && load_icon_texture(bridge, world_path.c_str(), &bridge->world_icon);
        const bool loaded_world_off = !world_off_path.empty() && load_icon_texture(bridge, world_off_path.c_str(), &bridge->world_off_icon);
        const bool loaded_trash = !trash_path.empty() && load_icon_texture(bridge, trash_path.c_str(), &bridge->trash_icon);
        const bool loaded_toggle_left = !toggle_left_path.empty() && load_icon_texture(bridge, toggle_left_path.c_str(), &bridge->toggle_left_icon);
        const bool loaded_toggle_right = !toggle_right_path.empty() && load_icon_texture(bridge, toggle_right_path.c_str(), &bridge->toggle_right_icon);
        const bool loaded_config = !config_path.empty() && load_icon_texture(bridge, config_path.c_str(), &bridge->config_icon);
        const bool loaded_headset = !headset_path.empty() && load_icon_texture(bridge, headset_path.c_str(), &bridge->headset_icon);
        const bool loaded_generic_app = !generic_app_path.empty() && load_icon_texture(bridge, generic_app_path.c_str(), &bridge->generic_app_icon);
        return loaded_volume && loaded_volume_off && loaded_fx && loaded_mic && loaded_mic_off &&
               loaded_world && loaded_world_off && loaded_trash && loaded_toggle_left &&
               loaded_toggle_right && loaded_config && loaded_headset && loaded_generic_app;
    }

    WireDeckIconTexture *find_cached_source_icon(WireDeckImGuiBridge *bridge, const std::string &cache_key)
    {
        for (auto &icon : bridge->source_icons)
        {
            if (icon.cache_key == cache_key)
            {
                return &icon.texture;
            }
        }
        return nullptr;
    }

    WireDeckIconTexture *default_source_icon(WireDeckImGuiBridge *bridge, const WireDeckUiSource &source)
    {
        switch (source.kind)
        {
        case 0:
            return &bridge->mic_icon;
        case 1:
            return &bridge->headset_icon;
        case 2:
        default:
            return &bridge->generic_app_icon;
        }
    }

    WireDeckIconTexture *default_channel_icon(WireDeckImGuiBridge *bridge, const WireDeckUiChannel &channel)
    {
        switch (channel.source_kind)
        {
        case 0:
            return &bridge->mic_icon;
        case 1:
            return &bridge->headset_icon;
        case 2:
        default:
            return &bridge->generic_app_icon;
        }
    }

    WireDeckIconTexture *resolve_source_icon_texture(WireDeckImGuiBridge *bridge, const WireDeckUiSource *source)
    {
        if (bridge == nullptr || source == nullptr)
        {
            return nullptr;
        }

        std::string renderable_path{};
        if (resolve_renderable_icon_path(source->icon_path, &renderable_path))
        {
            if (WireDeckIconTexture *cached = find_cached_source_icon(bridge, renderable_path))
            {
                return cached;
            }

            WireDeckCachedIcon cached_icon{};
            cached_icon.cache_key = renderable_path;
            if (load_icon_texture(bridge, renderable_path.c_str(), &cached_icon.texture))
            {
                bridge->source_icons.push_back(std::move(cached_icon));
                return &bridge->source_icons.back().texture;
            }
        }

        return default_source_icon(bridge, *source);
    }

    WireDeckIconTexture *resolve_channel_icon_texture(WireDeckImGuiBridge *bridge, const WireDeckUiChannel &channel)
    {
        if (bridge == nullptr)
        {
            return nullptr;
        }

        std::string renderable_path{};
        if (channel.icon_path != nullptr && resolve_renderable_icon_path(channel.icon_path, &renderable_path))
        {
            if (WireDeckIconTexture *cached = find_cached_source_icon(bridge, renderable_path))
            {
                return cached;
            }

            WireDeckCachedIcon cached_icon{};
            cached_icon.cache_key = renderable_path;
            if (load_icon_texture(bridge, renderable_path.c_str(), &cached_icon.texture))
            {
                bridge->source_icons.push_back(std::move(cached_icon));
                return &bridge->source_icons.back().texture;
            }
        }

        return default_channel_icon(bridge, channel);
    }

    bool setup_vulkan(WireDeckImGuiBridge *bridge)
    {
        uint32_t extension_count = 0;
        const char *const *sdl_extensions = SDL_Vulkan_GetInstanceExtensions(&extension_count);
        if (sdl_extensions == nullptr)
        {
            set_error(SDL_GetError());
            return false;
        }

        std::vector<const char *> instance_extensions(sdl_extensions, sdl_extensions + extension_count);

        uint32_t property_count = 0;
        if (!check_vk_result(vkEnumerateInstanceExtensionProperties(nullptr, &property_count, nullptr), "vkEnumerateInstanceExtensionProperties(count)"))
        {
            return false;
        }
        std::vector<VkExtensionProperties> properties(property_count);
        if (!check_vk_result(vkEnumerateInstanceExtensionProperties(nullptr, &property_count, properties.data()), "vkEnumerateInstanceExtensionProperties(list)"))
        {
            return false;
        }

#ifdef VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME
        VkInstanceCreateFlags instance_flags = 0;
        if (is_extension_available(properties, VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME))
        {
            instance_extensions.push_back(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
            instance_flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
        }
#else
        VkInstanceCreateFlags instance_flags = 0;
#endif

        VkApplicationInfo app_info{};
        app_info.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
        app_info.pApplicationName = "WireDeck";
        app_info.applicationVersion = VK_MAKE_API_VERSION(0, 0, 1, 0);
        app_info.pEngineName = "WireDeck";
        app_info.engineVersion = VK_MAKE_API_VERSION(0, 0, 1, 0);
        app_info.apiVersion = VK_API_VERSION_1_0;

        VkInstanceCreateInfo create_info{};
        create_info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        create_info.flags = instance_flags;
        create_info.pApplicationInfo = &app_info;
        create_info.enabledExtensionCount = static_cast<uint32_t>(instance_extensions.size());
        create_info.ppEnabledExtensionNames = instance_extensions.data();

        if (!check_vk_result(vkCreateInstance(&create_info, bridge->allocator, &bridge->instance), "vkCreateInstance"))
        {
            return false;
        }

        bridge->physical_device = ImGui_ImplVulkanH_SelectPhysicalDevice(bridge->instance);
        if (bridge->physical_device == VK_NULL_HANDLE)
        {
            set_error("ImGui_ImplVulkanH_SelectPhysicalDevice failed");
            return false;
        }

        bridge->queue_family = ImGui_ImplVulkanH_SelectQueueFamilyIndex(bridge->physical_device);
        if (bridge->queue_family == UINT32_MAX)
        {
            set_error("ImGui_ImplVulkanH_SelectQueueFamilyIndex failed");
            return false;
        }

        std::vector<const char *> device_extensions = {VK_KHR_SWAPCHAIN_EXTENSION_NAME};

        property_count = 0;
        if (!check_vk_result(vkEnumerateDeviceExtensionProperties(bridge->physical_device, nullptr, &property_count, nullptr), "vkEnumerateDeviceExtensionProperties(count)"))
        {
            return false;
        }
        properties.resize(property_count);
        if (!check_vk_result(vkEnumerateDeviceExtensionProperties(bridge->physical_device, nullptr, &property_count, properties.data()), "vkEnumerateDeviceExtensionProperties(list)"))
        {
            return false;
        }
#ifdef VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME
        if (is_extension_available(properties, VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME))
        {
            device_extensions.push_back(VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME);
        }
#endif

        const float queue_priority = 1.0f;
        VkDeviceQueueCreateInfo queue_info{};
        queue_info.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        queue_info.queueFamilyIndex = bridge->queue_family;
        queue_info.queueCount = 1;
        queue_info.pQueuePriorities = &queue_priority;

        VkDeviceCreateInfo device_info{};
        device_info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        device_info.queueCreateInfoCount = 1;
        device_info.pQueueCreateInfos = &queue_info;
        device_info.enabledExtensionCount = static_cast<uint32_t>(device_extensions.size());
        device_info.ppEnabledExtensionNames = device_extensions.data();

        if (!check_vk_result(vkCreateDevice(bridge->physical_device, &device_info, bridge->allocator, &bridge->device), "vkCreateDevice"))
        {
            return false;
        }

        vkGetDeviceQueue(bridge->device, bridge->queue_family, 0, &bridge->queue);

        std::array<VkDescriptorPoolSize, 11> pool_sizes = {{
            {VK_DESCRIPTOR_TYPE_SAMPLER, 1000},
            {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1000},
            {VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 1000},
            {VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1000},
            {VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 1000},
            {VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, 1000},
            {VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1000},
            {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1000},
            {VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, 1000},
            {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, 1000},
            {VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT, 1000},
        }};

        VkDescriptorPoolCreateInfo pool_info{};
        pool_info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        pool_info.flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
        pool_info.maxSets = static_cast<uint32_t>(pool_sizes.size() * 1000);
        pool_info.poolSizeCount = static_cast<uint32_t>(pool_sizes.size());
        pool_info.pPoolSizes = pool_sizes.data();

        if (!check_vk_result(vkCreateDescriptorPool(bridge->device, &pool_info, bridge->allocator, &bridge->descriptor_pool), "vkCreateDescriptorPool"))
        {
            return false;
        }

        return true;
    }

    bool setup_window(WireDeckImGuiBridge *bridge)
    {
        VkSurfaceKHR surface = VK_NULL_HANDLE;
        if (!SDL_Vulkan_CreateSurface(bridge->window, bridge->instance, bridge->allocator, &surface))
        {
            set_error(SDL_GetError());
            return false;
        }

        bridge->main_window_data.Surface = surface;

        VkBool32 present_supported = VK_FALSE;
        if (!check_vk_result(vkGetPhysicalDeviceSurfaceSupportKHR(bridge->physical_device, bridge->queue_family, surface, &present_supported), "vkGetPhysicalDeviceSurfaceSupportKHR"))
        {
            return false;
        }
        if (present_supported != VK_TRUE)
        {
            set_error("Selected Vulkan queue has no presentation support");
            return false;
        }

        const VkFormat request_formats[] = {
            VK_FORMAT_B8G8R8A8_UNORM,
            VK_FORMAT_R8G8B8A8_UNORM,
            VK_FORMAT_B8G8R8_UNORM,
            VK_FORMAT_R8G8B8_UNORM,
        };
        bridge->main_window_data.SurfaceFormat = ImGui_ImplVulkanH_SelectSurfaceFormat(
            bridge->physical_device,
            bridge->main_window_data.Surface,
            request_formats,
            4,
            VK_COLORSPACE_SRGB_NONLINEAR_KHR);

        const VkPresentModeKHR present_modes[] = {VK_PRESENT_MODE_FIFO_KHR};
        bridge->main_window_data.PresentMode = ImGui_ImplVulkanH_SelectPresentMode(
            bridge->physical_device,
            bridge->main_window_data.Surface,
            present_modes,
            1);

        int width = 0;
        int height = 0;
        SDL_GetWindowSize(bridge->window, &width, &height);
        ImGui_ImplVulkanH_CreateOrResizeWindow(
            bridge->instance,
            bridge->physical_device,
            bridge->device,
            &bridge->main_window_data,
            bridge->queue_family,
            bridge->allocator,
            width,
            height,
            bridge->min_image_count,
            0);

        return true;
    }

    void cleanup_vulkan(WireDeckImGuiBridge *bridge)
    {
        if (bridge->device != VK_NULL_HANDLE)
        {
            vkDeviceWaitIdle(bridge->device);
        }
        if (bridge->device != VK_NULL_HANDLE)
        {
            destroy_icon_texture(bridge, &bridge->volume_icon);
            destroy_icon_texture(bridge, &bridge->volume_off_icon);
            destroy_icon_texture(bridge, &bridge->fx_icon);
            destroy_icon_texture(bridge, &bridge->mic_icon);
            destroy_icon_texture(bridge, &bridge->mic_off_icon);
            destroy_icon_texture(bridge, &bridge->world_icon);
            destroy_icon_texture(bridge, &bridge->world_off_icon);
            destroy_icon_texture(bridge, &bridge->trash_icon);
            destroy_icon_texture(bridge, &bridge->toggle_left_icon);
            destroy_icon_texture(bridge, &bridge->toggle_right_icon);
            destroy_icon_texture(bridge, &bridge->config_icon);
            destroy_icon_texture(bridge, &bridge->headset_icon);
            destroy_icon_texture(bridge, &bridge->generic_app_icon);
            for (auto &icon : bridge->source_icons)
            {
                destroy_icon_texture(bridge, &icon.texture);
            }
            bridge->source_icons.clear();
        }
        if (bridge->main_window_data.Surface != VK_NULL_HANDLE)
        {
            ImGui_ImplVulkanH_DestroyWindow(bridge->instance, bridge->device, &bridge->main_window_data, bridge->allocator);
            vkDestroySurfaceKHR(bridge->instance, bridge->main_window_data.Surface, bridge->allocator);
            bridge->main_window_data.Surface = VK_NULL_HANDLE;
        }
        if (bridge->descriptor_pool != VK_NULL_HANDLE)
        {
            vkDestroyDescriptorPool(bridge->device, bridge->descriptor_pool, bridge->allocator);
            bridge->descriptor_pool = VK_NULL_HANDLE;
        }
        if (bridge->device != VK_NULL_HANDLE)
        {
            vkDestroyDevice(bridge->device, bridge->allocator);
            bridge->device = VK_NULL_HANDLE;
        }
        if (bridge->instance != VK_NULL_HANDLE)
        {
            vkDestroyInstance(bridge->instance, bridge->allocator);
            bridge->instance = VK_NULL_HANDLE;
        }
    }

    void frame_render(WireDeckImGuiBridge *bridge, ImDrawData *draw_data)
    {
        constexpr uint64_t kFrameWaitTimeoutNs = 100000000ULL;
        ImGui_ImplVulkanH_Window *wd = &bridge->main_window_data;
        VkSemaphore image_acquired_semaphore = wd->FrameSemaphores.Data[wd->SemaphoreIndex].ImageAcquiredSemaphore;
        VkSemaphore render_complete_semaphore = wd->FrameSemaphores.Data[wd->SemaphoreIndex].RenderCompleteSemaphore;

        VkResult err = vkAcquireNextImageKHR(bridge->device, wd->Swapchain, kFrameWaitTimeoutNs, image_acquired_semaphore, VK_NULL_HANDLE, &wd->FrameIndex);
        if (err == VK_ERROR_OUT_OF_DATE_KHR || err == VK_SUBOPTIMAL_KHR)
        {
            bridge->swapchain_rebuild = true;
        }
        if (err == VK_ERROR_OUT_OF_DATE_KHR || err == VK_TIMEOUT || err == VK_NOT_READY)
        {
            return;
        }
        check_vk_result(err, "vkAcquireNextImageKHR");

        ImGui_ImplVulkanH_Frame *fd = &wd->Frames.Data[wd->FrameIndex];
        err = vkWaitForFences(bridge->device, 1, &fd->Fence, VK_TRUE, kFrameWaitTimeoutNs);
        if (err == VK_TIMEOUT)
        {
            return;
        }
        check_vk_result(err, "vkWaitForFences");
        vkResetFences(bridge->device, 1, &fd->Fence);

        vkResetCommandPool(bridge->device, fd->CommandPool, 0);
        VkCommandBufferBeginInfo begin_info{};
        begin_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin_info.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        vkBeginCommandBuffer(fd->CommandBuffer, &begin_info);

        VkRenderPassBeginInfo render_pass_info{};
        render_pass_info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        render_pass_info.renderPass = wd->RenderPass;
        render_pass_info.framebuffer = fd->Framebuffer;
        render_pass_info.renderArea.extent.width = wd->Width;
        render_pass_info.renderArea.extent.height = wd->Height;
        render_pass_info.clearValueCount = 1;
        render_pass_info.pClearValues = &wd->ClearValue;
        vkCmdBeginRenderPass(fd->CommandBuffer, &render_pass_info, VK_SUBPASS_CONTENTS_INLINE);

        ImGui_ImplVulkan_RenderDrawData(draw_data, fd->CommandBuffer);

        vkCmdEndRenderPass(fd->CommandBuffer);
        vkEndCommandBuffer(fd->CommandBuffer);

        VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        VkSubmitInfo submit_info{};
        submit_info.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit_info.waitSemaphoreCount = 1;
        submit_info.pWaitSemaphores = &image_acquired_semaphore;
        submit_info.pWaitDstStageMask = &wait_stage;
        submit_info.commandBufferCount = 1;
        submit_info.pCommandBuffers = &fd->CommandBuffer;
        submit_info.signalSemaphoreCount = 1;
        submit_info.pSignalSemaphores = &render_complete_semaphore;
        vkQueueSubmit(bridge->queue, 1, &submit_info, fd->Fence);
    }

    void frame_present(WireDeckImGuiBridge *bridge)
    {
        if (bridge->swapchain_rebuild)
        {
            return;
        }

        ImGui_ImplVulkanH_Window *wd = &bridge->main_window_data;
        VkSemaphore render_complete_semaphore = wd->FrameSemaphores.Data[wd->SemaphoreIndex].RenderCompleteSemaphore;

        VkPresentInfoKHR present_info{};
        present_info.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        present_info.waitSemaphoreCount = 1;
        present_info.pWaitSemaphores = &render_complete_semaphore;
        present_info.swapchainCount = 1;
        present_info.pSwapchains = &wd->Swapchain;
        present_info.pImageIndices = &wd->FrameIndex;
        const VkResult err = vkQueuePresentKHR(bridge->queue, &present_info);
        if (err == VK_ERROR_OUT_OF_DATE_KHR || err == VK_SUBOPTIMAL_KHR)
        {
            bridge->swapchain_rebuild = true;
        }
        wd->SemaphoreIndex = (wd->SemaphoreIndex + 1) % wd->SemaphoreCount;
    }

    float bus_gain_for_channel(WireDeckUiSnapshot *snapshot, const char *channel_id, const char *bus_id)
    {
        for (int i = 0; i < snapshot->send_count; ++i)
        {
            const WireDeckUiSend &send = snapshot->sends[i];
            if (send.enabled && std::strcmp(send.channel_id, channel_id) == 0 && std::strcmp(send.bus_id, bus_id) == 0)
            {
                return send.gain;
            }
        }
        return -1.0f;
    }

    void push_wiredeck_style()
    {
        ImGui::StyleColorsDark();
        ImGuiStyle &style = ImGui::GetStyle();
        style.WindowRounding = 18.0f;
        style.ChildRounding = 18.0f;
        style.FrameRounding = 12.0f;
        style.GrabRounding = 999.0f;
        style.PopupRounding = 14.0f;
        style.ScrollbarRounding = 999.0f;
        style.WindowBorderSize = 1.0f;
        style.ChildBorderSize = 1.0f;
        style.FrameBorderSize = 0.0f;
        style.TabRounding = 10.0f;
        style.ScrollbarSize = 8.0f;
        style.ItemSpacing = ImVec2(10.0f, 10.0f);
        style.ItemInnerSpacing = ImVec2(6.0f, 5.0f);
        style.WindowPadding = ImVec2(18.0f, 16.0f);
        style.FramePadding = ImVec2(10.0f, 8.0f);
        style.CellPadding = ImVec2(8.0f, 8.0f);
        style.SeparatorTextBorderSize = 0.0f;
        style.SeparatorTextAlign = ImVec2(0.0f, 0.5f);
        style.SeparatorTextPadding = ImVec2(0.0f, 6.0f);

        ImVec4 *colors = style.Colors;
        colors[ImGuiCol_WindowBg] = ImVec4(0.05f, 0.07f, 0.09f, 1.0f);
        colors[ImGuiCol_ChildBg] = ImVec4(0.10f, 0.12f, 0.15f, 0.98f);
        colors[ImGuiCol_Border] = ImVec4(0.20f, 0.24f, 0.29f, 0.85f);
        colors[ImGuiCol_FrameBg] = ImVec4(0.13f, 0.15f, 0.18f, 1.0f);
        colors[ImGuiCol_FrameBgHovered] = ImVec4(0.17f, 0.20f, 0.24f, 1.0f);
        colors[ImGuiCol_FrameBgActive] = ImVec4(0.21f, 0.24f, 0.29f, 1.0f);
        colors[ImGuiCol_Button] = ImVec4(0.18f, 0.21f, 0.25f, 1.0f);
        colors[ImGuiCol_ButtonHovered] = ImVec4(0.24f, 0.28f, 0.34f, 1.0f);
        colors[ImGuiCol_ButtonActive] = ImVec4(0.81f, 0.53f, 0.17f, 1.0f);
        colors[ImGuiCol_Header] = ImVec4(0.16f, 0.19f, 0.23f, 1.0f);
        colors[ImGuiCol_HeaderHovered] = ImVec4(0.21f, 0.25f, 0.30f, 1.0f);
        colors[ImGuiCol_HeaderActive] = ImVec4(0.81f, 0.53f, 0.17f, 1.0f);
        colors[ImGuiCol_TitleBg] = ImVec4(0.08f, 0.09f, 0.11f, 1.0f);
        colors[ImGuiCol_TitleBgActive] = ImVec4(0.08f, 0.09f, 0.11f, 1.0f);
        colors[ImGuiCol_SliderGrab] = ImVec4(0.96f, 0.85f, 0.56f, 1.0f);
        colors[ImGuiCol_SliderGrabActive] = ImVec4(0.96f, 0.67f, 0.24f, 1.0f);
        colors[ImGuiCol_CheckMark] = ImVec4(0.97f, 0.82f, 0.32f, 1.0f);
        colors[ImGuiCol_PlotHistogram] = ImVec4(0.97f, 0.82f, 0.32f, 1.0f);
        colors[ImGuiCol_Text] = ImVec4(0.95f, 0.96f, 0.98f, 1.0f);
        colors[ImGuiCol_TextDisabled] = ImVec4(0.56f, 0.62f, 0.68f, 1.0f);
        colors[ImGuiCol_Separator] = ImVec4(0.18f, 0.21f, 0.25f, 1.0f);
        colors[ImGuiCol_TableHeaderBg] = ImVec4(0.13f, 0.15f, 0.18f, 1.0f);
        colors[ImGuiCol_TableBorderStrong] = ImVec4(0.18f, 0.22f, 0.26f, 1.0f);
        colors[ImGuiCol_TableBorderLight] = ImVec4(0.14f, 0.17f, 0.20f, 1.0f);
        colors[ImGuiCol_TableRowBgAlt] = ImVec4(0.11f, 0.13f, 0.16f, 0.85f);
    }

    WireDeckUiSend *find_send(WireDeckUiSnapshot *snapshot, const char *channel_id, const char *bus_id)
    {
        for (int i = 0; i < snapshot->send_count; ++i)
        {
            WireDeckUiSend &send = snapshot->sends[i];
            if (std::strcmp(send.channel_id, channel_id) == 0 && std::strcmp(send.bus_id, bus_id) == 0)
            {
                return &send;
            }
        }
        return nullptr;
    }

    float animated_level(float base, int frame_index, float phase_offset)
    {
        const float t = static_cast<float>(frame_index) * 0.055f + phase_offset;
        const float pulse = (std::sin(t) + 1.0f) * 0.5f;
        return std::clamp(base * (0.55f + pulse * 0.65f), 0.0f, 1.0f);
    }

    void draw_meter_bar(float value, const ImVec2 &size)
    {
        ImGui::PushStyleColor(ImGuiCol_FrameBg, ImVec4(0.02f, 0.02f, 0.03f, 1.0f));
        ImGui::PushStyleColor(ImGuiCol_PlotHistogram, ImVec4(0.24f, 0.84f, 0.42f, 1.0f));
        ImGui::ProgressBar(value, size, nullptr);
        ImGui::PopStyleColor(2);
    }

    ImVec4 meter_color(float value)
    {
        if (value >= 0.92f)
            return ImVec4(0.90f, 0.22f, 0.18f, 1.0f);
        if (value >= 0.78f)
            return ImVec4(0.97f, 0.56f, 0.14f, 1.0f);
        if (value >= 0.58f)
            return ImVec4(0.84f, 0.78f, 0.17f, 1.0f);
        return ImVec4(0.24f, 0.84f, 0.42f, 1.0f);
    }

    void draw_volume_icon(ImDrawList *draw_list, const ImVec2 &min, const ImVec2 &max, bool muted, ImU32 color)
    {
        const float w = max.x - min.x;
        const float h = max.y - min.y;
        const float center_y = min.y + h * 0.5f;
        const float speaker_left = min.x + w * 0.14f;
        const float speaker_mid = min.x + w * 0.36f;
        const float cone_tip = min.x + w * 0.62f;
        const float cone_top = min.y + h * 0.22f;
        const float cone_bottom = min.y + h * 0.78f;
        const float stroke = std::max(1.8f, w * 0.065f);

        draw_list->AddLine(ImVec2(speaker_left, center_y), ImVec2(speaker_mid, cone_top), color, stroke);
        draw_list->AddLine(ImVec2(speaker_left, center_y), ImVec2(speaker_mid, cone_bottom), color, stroke);
        draw_list->AddLine(ImVec2(speaker_mid, cone_top), ImVec2(cone_tip, cone_top), color, stroke);
        draw_list->AddLine(ImVec2(speaker_mid, cone_bottom), ImVec2(cone_tip, cone_bottom), color, stroke);
        draw_list->AddLine(ImVec2(cone_tip, cone_top), ImVec2(cone_tip, cone_bottom), color, stroke);

        if (muted)
        {
            draw_list->AddLine(
                ImVec2(min.x + w * 0.14f, min.y + h * 0.18f),
                ImVec2(max.x - w * 0.14f, max.y - h * 0.18f),
                color,
                stroke);
        }
        else
        {
            const ImVec2 wave_center(min.x + w * 0.60f, center_y);
            draw_list->AddBezierCubic(
                ImVec2(wave_center.x + w * 0.06f, wave_center.y - h * 0.18f),
                ImVec2(wave_center.x + w * 0.14f, wave_center.y - h * 0.11f),
                ImVec2(wave_center.x + w * 0.14f, wave_center.y + h * 0.11f),
                ImVec2(wave_center.x + w * 0.06f, wave_center.y + h * 0.18f),
                color,
                stroke);
            draw_list->AddBezierCubic(
                ImVec2(wave_center.x + w * 0.19f, wave_center.y - h * 0.28f),
                ImVec2(wave_center.x + w * 0.31f, wave_center.y - h * 0.16f),
                ImVec2(wave_center.x + w * 0.31f, wave_center.y + h * 0.16f),
                ImVec2(wave_center.x + w * 0.19f, wave_center.y + h * 0.28f),
                color,
                stroke);
        }
    }

    bool render_mute_icon_button(WireDeckImGuiBridge *bridge, const char *id, bool muted, const ImVec2 &size, float inset)
    {
        const bool pressed = ImGui::InvisibleButton(id, size);
        const ImVec2 min = ImGui::GetItemRectMin();
        const ImVec2 max = ImGui::GetItemRectMax();
        const bool hovered = ImGui::IsItemHovered();
        const bool active = ImGui::IsItemActive();
        ImDrawList *draw_list = ImGui::GetWindowDrawList();

        const ImVec4 icon_color = muted
                                      ? ImVec4(0.97f, 0.36f, 0.30f, 1.0f)
                                  : active  ? ImVec4(1.0f, 1.0f, 1.0f, 1.0f)
                                  : hovered ? ImVec4(0.96f, 0.96f, 0.98f, 1.0f)
                                            : ImVec4(0.82f, 0.84f, 0.88f, 1.0f);

        const WireDeckIconTexture &texture = muted ? bridge->volume_off_icon : bridge->volume_icon;
        if (texture.descriptor_set != VK_NULL_HANDLE)
        {
            draw_list->AddImage(
                texture.descriptor_set,
                ImVec2(min.x + inset, min.y + inset),
                ImVec2(max.x - inset, max.y - inset),
                ImVec2(0.0f, 0.0f),
                ImVec2(1.0f, 1.0f),
                ImGui::GetColorU32(icon_color));
        }
        else
        {
            draw_volume_icon(draw_list, min, max, muted, ImGui::GetColorU32(icon_color));
        }
        return pressed;
    }

    void draw_fx_icon(ImDrawList *draw_list, const ImVec2 &min, const ImVec2 &max, ImU32 color)
    {
        const float w = max.x - min.x;
        const float h = max.y - min.y;
        const float center_y = (min.y + max.y) * 0.5f;
        const float stroke = 2.0f;
        draw_list->AddBezierCubic(
            ImVec2(min.x + w * 0.12f, center_y + h * 0.16f),
            ImVec2(min.x + w * 0.28f, center_y - h * 0.28f),
            ImVec2(min.x + w * 0.42f, center_y + h * 0.30f),
            ImVec2(min.x + w * 0.56f, center_y - h * 0.10f),
            color,
            stroke);
        draw_list->AddLine(
            ImVec2(min.x + w * 0.64f, center_y + h * 0.18f),
            ImVec2(min.x + w * 0.64f, center_y - h * 0.24f),
            color,
            stroke);
        draw_list->AddLine(
            ImVec2(min.x + w * 0.72f, center_y + h * 0.18f),
            ImVec2(min.x + w * 0.72f, center_y - h * 0.04f),
            color,
            stroke);
        draw_list->AddLine(
            ImVec2(min.x + w * 0.80f, center_y + h * 0.18f),
            ImVec2(min.x + w * 0.80f, center_y - h * 0.34f),
            color,
            stroke);
    }

    bool render_fx_icon_button(WireDeckImGuiBridge *bridge, const char *id, bool enabled, const ImVec2 &size, float inset)
    {
        const bool pressed = ImGui::InvisibleButton(id, size);
        const ImVec2 min = ImGui::GetItemRectMin();
        const ImVec2 max = ImGui::GetItemRectMax();
        const bool hovered = ImGui::IsItemHovered();
        const bool active = ImGui::IsItemActive();
        ImDrawList *draw_list = ImGui::GetWindowDrawList();

        const ImVec4 icon_color = enabled
                                      ? ImVec4(0.88f, 0.80f, 0.18f, 1.0f)
                                  : active  ? ImVec4(1.0f, 1.0f, 1.0f, 1.0f)
                                  : hovered ? ImVec4(0.96f, 0.96f, 0.98f, 1.0f)
                                            : ImVec4(0.82f, 0.84f, 0.88f, 1.0f);
        const WireDeckIconTexture &texture = bridge->fx_icon;
        if (texture.descriptor_set != VK_NULL_HANDLE)
        {
            draw_list->AddImage(
                texture.descriptor_set,
                ImVec2(min.x + inset, min.y + inset),
                ImVec2(max.x - inset, max.y - inset),
                ImVec2(0.0f, 0.0f),
                ImVec2(1.0f, 1.0f),
                ImGui::GetColorU32(icon_color));
        }
        else
        {
            draw_fx_icon(draw_list, min, max, ImGui::GetColorU32(icon_color));
        }
        return pressed;
    }

    bool render_texture_toggle_button(
        const WireDeckIconTexture &active_texture,
        const WireDeckIconTexture &inactive_texture,
        const char *id,
        bool enabled,
        const ImVec4 &active_color,
        const ImVec2 &size = ImVec2(30.0f, 30.0f),
        float inset = 2.0f)
    {
        const bool pressed = ImGui::InvisibleButton(id, size);
        const ImVec2 min = ImGui::GetItemRectMin();
        const ImVec2 max = ImGui::GetItemRectMax();
        const bool hovered = ImGui::IsItemHovered();
        const bool active = ImGui::IsItemActive();
        ImDrawList *draw_list = ImGui::GetWindowDrawList();

        const ImVec4 icon_color = enabled
                                      ? active_color
                                  : active  ? ImVec4(1.0f, 1.0f, 1.0f, 1.0f)
                                  : hovered ? ImVec4(0.96f, 0.96f, 0.98f, 1.0f)
                                            : ImVec4(0.82f, 0.84f, 0.88f, 1.0f);
        const WireDeckIconTexture &texture = enabled ? active_texture : inactive_texture;
        if (texture.descriptor_set != VK_NULL_HANDLE)
        {
            const float inset = 2.0f;
            draw_list->AddImage(
                texture.descriptor_set,
                ImVec2(min.x + inset, min.y + inset),
                ImVec2(max.x - inset, max.y - inset),
                ImVec2(0.0f, 0.0f),
                ImVec2(1.0f, 1.0f),
                ImGui::GetColorU32(icon_color));
        }
        return pressed;
    }

    bool render_fixed_icon_toggle_button(
        const WireDeckIconTexture &active_texture,
        const WireDeckIconTexture &inactive_texture,
        const char *id,
        bool enabled,
        const ImVec4 &active_color,
        const ImVec2 &size,
        float icon_extent)
    {
        const bool pressed = ImGui::InvisibleButton(id, size);
        const ImVec2 min = ImGui::GetItemRectMin();
        const ImVec2 max = ImGui::GetItemRectMax();
        const bool hovered = ImGui::IsItemHovered();
        const bool active = ImGui::IsItemActive();
        ImDrawList *draw_list = ImGui::GetWindowDrawList();

        const ImVec4 icon_color = enabled
                                      ? active_color
                                  : active  ? ImVec4(1.0f, 1.0f, 1.0f, 1.0f)
                                  : hovered ? ImVec4(0.96f, 0.96f, 0.98f, 1.0f)
                                            : ImVec4(0.82f, 0.84f, 0.88f, 1.0f);
        const WireDeckIconTexture &texture = enabled ? active_texture : inactive_texture;
        if (texture.descriptor_set != VK_NULL_HANDLE)
        {
            const float draw_w = std::min(icon_extent, size.x);
            const float draw_h = std::min(icon_extent, size.y);
            const float x0 = min.x + (size.x - draw_w) * 0.5f;
            const float y0 = min.y + (size.y - draw_h) * 0.5f;
            draw_list->AddImage(
                texture.descriptor_set,
                ImVec2(x0, y0),
                ImVec2(x0 + draw_w, y0 + draw_h),
                ImVec2(0.0f, 0.0f),
                ImVec2(1.0f, 1.0f),
                ImGui::GetColorU32(icon_color));
        }
        return pressed;
    }

    bool render_fixed_icon_button(
        const WireDeckIconTexture &texture,
        const char *id,
        const ImVec2 &size,
        float icon_extent,
        const ImVec4 &base_color)
    {
        const bool pressed = ImGui::InvisibleButton(id, size);
        const ImVec2 min = ImGui::GetItemRectMin();
        const ImVec2 max = ImGui::GetItemRectMax();
        const bool hovered = ImGui::IsItemHovered();
        const bool active = ImGui::IsItemActive();
        ImDrawList *draw_list = ImGui::GetWindowDrawList();

        const ImVec4 icon_color = active    ? ImVec4(std::min(base_color.x + 0.08f, 1.0f), std::min(base_color.y + 0.08f, 1.0f), std::min(base_color.z + 0.08f, 1.0f), base_color.w)
                                  : hovered ? ImVec4(std::min(base_color.x + 0.04f, 1.0f), std::min(base_color.y + 0.04f, 1.0f), std::min(base_color.z + 0.04f, 1.0f), base_color.w)
                                            : base_color;
        if (texture.descriptor_set != VK_NULL_HANDLE)
        {
            const float draw_w = std::min(icon_extent, size.x);
            const float draw_h = std::min(icon_extent, size.y);
            const float x0 = min.x + (size.x - draw_w) * 0.5f;
            const float y0 = min.y + (size.y - draw_h) * 0.5f;
            draw_list->AddImage(
                texture.descriptor_set,
                ImVec2(x0, y0),
                ImVec2(x0 + draw_w, y0 + draw_h),
                ImVec2(0.0f, 0.0f),
                ImVec2(1.0f, 1.0f),
                ImGui::GetColorU32(icon_color));
        }
        return pressed;
    }

    bool render_mic_exposure_button(WireDeckImGuiBridge *bridge, const char *id, bool enabled)
    {
        return render_texture_toggle_button(
            bridge->mic_icon,
            bridge->mic_off_icon,
            id,
            enabled,
            ImVec4(0.36f, 0.84f, 0.48f, 1.0f));
    }

    bool render_mic_exposure_button(WireDeckImGuiBridge *bridge, const char *id, bool enabled, const ImVec2 &size, float inset)
    {
        (void)inset;
        return render_fixed_icon_toggle_button(
            bridge->mic_icon,
            bridge->mic_off_icon,
            id,
            enabled,
            ImVec4(0.36f, 0.84f, 0.48f, 1.0f),
            size,
            13.0f);
    }

    bool render_web_exposure_button(WireDeckImGuiBridge *bridge, const char *id, bool enabled)
    {
        return render_texture_toggle_button(
            bridge->world_icon,
            bridge->world_off_icon,
            id,
            enabled,
            ImVec4(0.25f, 0.78f, 0.96f, 1.0f));
    }

    bool render_web_exposure_button(WireDeckImGuiBridge *bridge, const char *id, bool enabled, const ImVec2 &size, float inset)
    {
        (void)inset;
        return render_fixed_icon_toggle_button(
            bridge->world_icon,
            bridge->world_off_icon,
            id,
            enabled,
            ImVec4(0.25f, 0.78f, 0.96f, 1.0f),
            size,
            13.0f);
    }

    void draw_trash_icon(ImDrawList *draw_list, const ImVec2 &min, const ImVec2 &max, ImU32 color)
    {
        const float w = max.x - min.x;
        const float h = max.y - min.y;
        const float stroke = std::max(1.4f, std::min(w, h) * 0.08f);
        const float lid_y = min.y + h * 0.28f;
        const float body_top = min.y + h * 0.36f;
        const float body_bottom = min.y + h * 0.78f;
        const float body_left = min.x + w * 0.28f;
        const float body_right = min.x + w * 0.72f;
        draw_list->AddLine(ImVec2(min.x + w * 0.24f, lid_y), ImVec2(max.x - w * 0.24f, lid_y), color, stroke);
        draw_list->AddLine(ImVec2(min.x + w * 0.40f, min.y + h * 0.20f), ImVec2(max.x - w * 0.40f, min.y + h * 0.20f), color, stroke);
        draw_list->AddLine(ImVec2(body_left, body_top), ImVec2(body_left, body_bottom), color, stroke);
        draw_list->AddLine(ImVec2(body_right, body_top), ImVec2(body_right, body_bottom), color, stroke);
        draw_list->AddLine(ImVec2(body_left, body_bottom), ImVec2(body_right, body_bottom), color, stroke);
        draw_list->AddLine(ImVec2(min.x + w * 0.42f, body_top + h * 0.08f), ImVec2(min.x + w * 0.42f, body_bottom - h * 0.06f), color, stroke);
        draw_list->AddLine(ImVec2(min.x + w * 0.58f, body_top + h * 0.08f), ImVec2(min.x + w * 0.58f, body_bottom - h * 0.06f), color, stroke);
    }

    bool render_delete_icon_button(WireDeckImGuiBridge *bridge, const char *id, const ImVec2 &size, float inset)
    {
        const bool pressed = ImGui::InvisibleButton(id, size);
        const ImVec2 min = ImGui::GetItemRectMin();
        const ImVec2 max = ImGui::GetItemRectMax();
        const bool hovered = ImGui::IsItemHovered();
        const bool active = ImGui::IsItemActive();
        ImDrawList *draw_list = ImGui::GetWindowDrawList();
        const ImVec4 icon_color = active ? ImVec4(1.0f, 0.44f, 0.40f, 1.0f) : hovered ? ImVec4(0.96f, 0.40f, 0.36f, 1.0f)
                                                                                      : ImVec4(0.90f, 0.28f, 0.24f, 1.0f);
        if (bridge->trash_icon.descriptor_set != VK_NULL_HANDLE)
        {
            const float draw_w = std::min(13.0f, size.x);
            const float draw_h = std::min(13.0f, size.y);
            const float x0 = min.x + (size.x - draw_w) * 0.5f;
            const float y0 = min.y + (size.y - draw_h) * 0.5f;
            draw_list->AddImage(
                bridge->trash_icon.descriptor_set,
                ImVec2(x0, y0),
                ImVec2(x0 + draw_w, y0 + draw_h),
                ImVec2(0.0f, 0.0f),
                ImVec2(1.0f, 1.0f),
                ImGui::GetColorU32(icon_color));
        }
        else
        {
            const float draw_w = std::min(13.0f, size.x);
            const float draw_h = std::min(13.0f, size.y);
            const float x0 = min.x + (size.x - draw_w) * 0.5f;
            const float y0 = min.y + (size.y - draw_h) * 0.5f;
            draw_trash_icon(
                draw_list,
                ImVec2(x0, y0),
                ImVec2(x0 + draw_w, y0 + draw_h),
                ImGui::GetColorU32(icon_color));
        }
        return pressed;
    }

    float stereo_channel_level(float base, int frame_index, float phase_offset)
    {
        const float t = static_cast<float>(frame_index) * 0.065f + phase_offset;
        const float drift = (std::sin(t) + 1.0f) * 0.5f;
        return std::clamp(base * (0.72f + drift * 0.42f), 0.0f, 1.0f);
    }

    bool render_thin_volume_slider(const char *id, float *percent, float height);

    bool render_stereo_meter_with_volume(const char *meter_id, const char *slider_id, float left, float right, float *percent)
    {
        const float width = ImGui::GetContentRegionAvail().x;
        const float row_height = 9.0f;
        const float gap = 2.0f;
        const ImVec2 size(width, row_height * 2.0f + gap);
        const ImVec2 origin = ImGui::GetCursorScreenPos();
        ImDrawList *draw_list = ImGui::GetWindowDrawList();
        const ImU32 bg = ImGui::GetColorU32(ImVec4(0.02f, 0.02f, 0.03f, 1.0f));

        ImGui::Dummy(size);

        const ImVec2 left_min(origin.x, origin.y);
        const ImVec2 left_max(origin.x + width, origin.y + row_height);
        const ImVec2 right_min(origin.x, origin.y + row_height + gap);
        const ImVec2 right_max(origin.x + width, origin.y + row_height + gap + row_height);

        draw_list->AddRectFilled(left_min, left_max, bg, 0.0f);
        draw_list->AddRectFilled(right_min, right_max, bg, 0.0f);
        draw_list->AddRectFilled(left_min, ImVec2(origin.x + width * left, left_max.y), ImGui::GetColorU32(meter_color(left)), 0.0f);
        draw_list->AddRectFilled(right_min, ImVec2(origin.x + width * right, right_max.y), ImGui::GetColorU32(meter_color(right)), 0.0f);

        if (percent == nullptr)
        {
            return false;
        }

        ImGui::SetCursorScreenPos(origin);
        ImGui::PushID(meter_id);
        const bool changed = render_thin_volume_slider(slider_id, percent, size.y);
        ImGui::PopID();
        return changed;
    }

    void set_request_text(char *dst, size_t dst_len, const char *value)
    {
        if (dst_len == 0)
        {
            return;
        }
        if (value != nullptr && std::strlen(value) >= dst_len)
        {
            std::fprintf(stderr, "wiredeck imgui request truncated: len=%zu capacity=%zu value=%s\n", std::strlen(value), dst_len, value);
        }
        std::snprintf(dst, dst_len, "%s", value ? value : "");
    }

    void queue_input_rename(WireDeckUiSnapshot *snapshot, const char *id, const char *label)
    {
        set_request_text(snapshot->request_rename_input_id, sizeof(snapshot->request_rename_input_id), id);
        set_request_text(snapshot->request_rename_input_label, sizeof(snapshot->request_rename_input_label), label);
    }

    void queue_input_icon_pick(WireDeckUiSnapshot *snapshot, const char *id)
    {
        set_request_text(snapshot->request_pick_input_icon_id, sizeof(snapshot->request_pick_input_icon_id), id);
    }

    void queue_input_icon_clear(WireDeckUiSnapshot *snapshot, const char *id)
    {
        set_request_text(snapshot->request_clear_input_icon_id, sizeof(snapshot->request_clear_input_icon_id), id);
    }

    void queue_output_rename(WireDeckUiSnapshot *snapshot, const char *id, const char *label)
    {
        set_request_text(snapshot->request_rename_output_id, sizeof(snapshot->request_rename_output_id), id);
        set_request_text(snapshot->request_rename_output_label, sizeof(snapshot->request_rename_output_label), label);
    }

    void queue_input_delete(WireDeckUiSnapshot *snapshot, const char *id)
    {
        set_request_text(snapshot->request_delete_input_id, sizeof(snapshot->request_delete_input_id), id);
    }

    void queue_output_delete(WireDeckUiSnapshot *snapshot, const char *id)
    {
        set_request_text(snapshot->request_delete_output_id, sizeof(snapshot->request_delete_output_id), id);
    }

    void queue_add_plugin(WireDeckUiSnapshot *snapshot, const char *channel_id, const char *descriptor_id)
    {
        set_request_text(snapshot->request_add_plugin_channel_id, sizeof(snapshot->request_add_plugin_channel_id), channel_id);
        set_request_text(snapshot->request_add_plugin_descriptor_id, sizeof(snapshot->request_add_plugin_descriptor_id), descriptor_id);
    }

    void queue_select_source(WireDeckUiSnapshot *snapshot, const char *source_id)
    {
        set_request_text(snapshot->request_select_source_id, sizeof(snapshot->request_select_source_id), source_id);
    }

    void queue_remove_plugin(WireDeckUiSnapshot *snapshot, const char *plugin_id)
    {
        set_request_text(snapshot->request_remove_plugin_id, sizeof(snapshot->request_remove_plugin_id), plugin_id);
    }

    void queue_move_plugin(WireDeckUiSnapshot *snapshot, const char *plugin_id, int delta)
    {
        set_request_text(snapshot->request_move_plugin_id, sizeof(snapshot->request_move_plugin_id), plugin_id);
        snapshot->request_move_plugin_delta = delta;
    }

    void queue_open_plugin_ui(WireDeckUiSnapshot *snapshot, const char *plugin_id)
    {
        set_request_text(snapshot->request_open_plugin_ui_id, sizeof(snapshot->request_open_plugin_ui_id), plugin_id);
    }

    void queue_select_noise_model(WireDeckUiSnapshot *snapshot, const char *path)
    {
        set_request_text(snapshot->request_select_noise_model_path, sizeof(snapshot->request_select_noise_model_path), path);
    }

    const WireDeckUiPluginDescriptor *find_plugin_descriptor(WireDeckUiSnapshot *snapshot, const char *descriptor_id)
    {
        for (int i = 0; i < snapshot->plugin_descriptor_count; ++i)
        {
            const WireDeckUiPluginDescriptor &descriptor = snapshot->plugin_descriptors[i];
            if (std::strcmp(descriptor.id, descriptor_id) == 0)
            {
                return &descriptor;
            }
        }
        return nullptr;
    }

    WireDeckUiChannelPluginParam *find_plugin_param(WireDeckUiSnapshot *snapshot, const char *plugin_id, const char *symbol)
    {
        for (int i = 0; i < snapshot->channel_plugin_param_count; ++i)
        {
            WireDeckUiChannelPluginParam &param = snapshot->channel_plugin_params[i];
            if (std::strcmp(param.plugin_id, plugin_id) == 0 && std::strcmp(param.symbol, symbol) == 0)
            {
                return &param;
            }
        }
        return nullptr;
    }

    const WireDeckUiNoiseModel *active_noise_model(WireDeckUiSnapshot *snapshot)
    {
        for (int i = 0; i < snapshot->noise_model_count; ++i)
        {
            const WireDeckUiNoiseModel &model = snapshot->noise_models[i];
            if (model.active != 0)
            {
                return &model;
            }
        }
        return nullptr;
    }

    WireDeckUiSource *find_source(WireDeckUiSnapshot *snapshot, const char *source_id)
    {
        if (snapshot == nullptr || source_id == nullptr)
        {
            return nullptr;
        }
        for (int i = 0; i < snapshot->source_count; ++i)
        {
            WireDeckUiSource &source = snapshot->sources[i];
            if (safe_streq(source.id, source_id))
            {
                return &source;
            }
        }
        return nullptr;
    }

    WireDeckUiChannel *find_channel(WireDeckUiSnapshot *snapshot, const char *channel_id)
    {
        if (snapshot == nullptr || channel_id == nullptr)
        {
            return nullptr;
        }
        for (int i = 0; i < snapshot->channel_count; ++i)
        {
            WireDeckUiChannel &channel = snapshot->channels[i];
            if (safe_streq(channel.id, channel_id))
            {
                return &channel;
            }
        }
        return nullptr;
    }

    WireDeckUiSource *find_bound_source_for_channel(WireDeckUiSnapshot *snapshot, const WireDeckUiChannel &channel)
    {
        if (snapshot == nullptr || channel.id == nullptr)
        {
            return nullptr;
        }
        if (channel.bound_source_id != nullptr && channel.bound_source_id[0] != '\0')
        {
            if (WireDeckUiSource *direct = find_source(snapshot, channel.bound_source_id))
            {
                return direct;
            }
        }

        for (int i = 0; i < snapshot->channel_source_count; ++i)
        {
            const WireDeckUiChannelSource &channel_source = snapshot->channel_sources[i];
            if (channel_source.enabled == 0 || !safe_streq(channel_source.channel_id, channel.id))
            {
                continue;
            }
            if (WireDeckUiSource *source = find_source(snapshot, channel_source.source_id))
            {
                return source;
            }
        }

        return nullptr;
    }

    const char *preferred_source_label_for_channel(
        WireDeckUiSnapshot *snapshot,
        const char *channel_id,
        const WireDeckUiSource &source)
    {
        WireDeckUiChannel *channel = find_channel(snapshot, channel_id);
        if (channel == nullptr)
            return source.label;
        if (channel->label != nullptr && channel->label[0] != '\0' &&
            channel->bound_source_id != nullptr && channel->bound_source_id[0] != '\0' &&
            safe_streq(channel->bound_source_id, source.id))
        {
            return channel->label;
        }
        return source.label;
    }

    bool source_is_already_added(WireDeckUiSnapshot *snapshot, const char *source_id)
    {
        for (int i = 0; i < snapshot->channel_count; ++i)
        {
            const WireDeckUiChannel &channel = snapshot->channels[i];
            if (channel.bound_source_id != nullptr && std::strcmp(channel.bound_source_id, source_id) == 0)
            {
                return true;
            }
        }
        return false;
    }

    WireDeckMeterVisualState &meter_visual_state(WireDeckImGuiBridge *bridge, const char *key)
    {
        return bridge->source_meter_states[std::string(key ? key : "")];
    }

    void update_meter_visual_state(WireDeckMeterVisualState &state, float left, float right)
    {
        state.current_left = std::clamp(left, 0.0f, 1.0f);
        state.current_right = std::clamp(right, 0.0f, 1.0f);
        state.peak_left = state.current_left;
        state.peak_right = state.current_right;
        state.peak_hold_left = 0;
        state.peak_hold_right = 0;
    }

    WireDeckMeterVisualState &render_source_stereo_meter(WireDeckImGuiBridge *bridge, const char *meter_key, float left, float right, const ImVec2 &size)
    {
        const float label_width = 14.0f;
        const float gap = 6.0f;
        const float row_height = 10.0f;
        const ImVec2 origin = ImGui::GetCursorScreenPos();
        const float bar_width = std::max(0.0f, size.x - label_width - gap);
        ImDrawList *draw_list = ImGui::GetWindowDrawList();
        WireDeckMeterVisualState &state = meter_visual_state(bridge, meter_key);
        update_meter_visual_state(state, left, right);

        ImGui::Dummy(ImVec2(size.x, row_height * 2.0f + gap));

        auto draw_row = [&](float y, const char *label, float current_value, float peak_value)
        {
            draw_list->AddText(
                ImVec2(origin.x, y - 1.0f),
                ImGui::GetColorU32(ImVec4(0.74f, 0.74f, 0.78f, 1.0f)),
                label);

            const ImVec2 bar_min(origin.x + label_width + gap, y);
            const ImVec2 bar_max(bar_min.x + bar_width, y + row_height);
            draw_list->AddRectFilled(bar_min, bar_max, ImGui::GetColorU32(ImVec4(0.08f, 0.08f, 0.11f, 1.0f)), 3.0f);

            const float clamped = std::clamp(current_value, 0.0f, 1.0f);
            if (clamped > 0.0f)
            {
                draw_list->AddRectFilled(
                    bar_min,
                    ImVec2(bar_min.x + bar_width * clamped, bar_max.y),
                    ImGui::GetColorU32(meter_color(clamped)),
                    3.0f);
            }

            const float peak = std::clamp(peak_value, 0.0f, 1.0f);
            if (peak > 0.0f)
            {
                const float x = bar_min.x + std::max(0.0f, bar_width * peak - 1.0f);
                draw_list->AddRectFilled(
                    ImVec2(x, bar_min.y - 1.0f),
                    ImVec2(x + 2.0f, bar_max.y + 1.0f),
                    ImGui::GetColorU32(ImVec4(0.96f, 0.96f, 0.98f, 0.95f)),
                    1.0f);
            }
        };

        draw_row(origin.y, "L", state.current_left, state.peak_left);
        draw_row(origin.y + row_height + gap, "R", state.current_right, state.peak_right);
        return state;
    }

    void render_source_meter_bar(const char *id, float value, const ImVec2 &size)
    {
        ImGui::PushID(id);
        const ImVec2 origin = ImGui::GetCursorScreenPos();
        ImDrawList *draw_list = ImGui::GetWindowDrawList();
        const int segments = 20;
        const float gap = 2.0f;
        const float segment_width = (size.x - gap * static_cast<float>(segments - 1)) / static_cast<float>(segments);
        const float clamped = std::clamp(value, 0.0f, 1.0f);
        const int active_segments = std::clamp(static_cast<int>(std::round(clamped * static_cast<float>(segments))), 0, segments);

        ImGui::Dummy(size);

        const ImVec2 bar_min(origin.x, origin.y);
        const ImVec2 bar_max(origin.x + size.x, origin.y + size.y);
        draw_list->AddRectFilled(bar_min, bar_max, ImGui::GetColorU32(ImVec4(0.10f, 0.10f, 0.14f, 1.0f)), 4.0f);
        if (clamped > 0.0f)
        {
            draw_list->AddRectFilled(
                bar_min,
                ImVec2(origin.x + size.x * clamped, bar_max.y),
                ImGui::GetColorU32(meter_color(clamped)),
                4.0f);
        }

        for (int segment = 0; segment < segments; ++segment)
        {
            const float x0 = origin.x + static_cast<float>(segment) * (segment_width + gap);
            const float x1 = x0 + segment_width;
            const ImVec2 min(x0, origin.y + 1.0f);
            const ImVec2 max(x1, origin.y + size.y - 1.0f);
            const float normalized = static_cast<float>(segment + 1) / static_cast<float>(segments);
            const ImU32 divider = ImGui::GetColorU32(ImVec4(0.17f, 0.17f, 0.22f, 0.95f));
            const ImU32 overlay = ImGui::GetColorU32(segment < active_segments ? ImVec4(1.0f, 1.0f, 1.0f, 0.10f) : ImVec4(0.0f, 0.0f, 0.0f, 0.18f));
            draw_list->AddRect(min, max, divider, 2.0f);
            draw_list->AddRectFilled(min, max, overlay, 2.0f);
            if (segment == active_segments - 1 && clamped > 0.0f)
            {
                draw_list->AddRectFilled(min, max, ImGui::GetColorU32(ImVec4(1.0f, 1.0f, 1.0f, 0.16f)), 2.0f);
            }
        }

        ImGui::PopID();
    }

    int count_channel_plugins(WireDeckUiSnapshot *snapshot, const char *channel_id)
    {
        int count = 0;
        for (int i = 0; i < snapshot->channel_plugin_count; ++i)
        {
            if (std::strcmp(snapshot->channel_plugins[i].channel_id, channel_id) == 0)
            {
                count += 1;
            }
        }
        return count;
    }

    const char *plugin_backend_label(int backend)
    {
        switch (backend)
        {
        case 0:
            return "legacy";
        case 1:
            return "native";
        case 2:
            return "lv2";
        default:
            return "fx";
        }
    }

    std::string lower_copy(const char *text)
    {
        if (text == nullptr)
        {
            return {};
        }
        std::string result(text);
        std::transform(result.begin(), result.end(), result.begin(), [](unsigned char c)
                       { return static_cast<char>(std::tolower(c)); });
        return result;
    }

    bool plugin_matches_filter(const WireDeckUiPluginDescriptor &descriptor, const std::string &filter)
    {
        if (filter.empty())
        {
            return true;
        }
        return lower_copy(descriptor.label).find(filter) != std::string::npos ||
               lower_copy(descriptor.bundle_name).find(filter) != std::string::npos;
    }

    bool render_plugin_descriptor_button(WireDeckUiSnapshot *snapshot, const char *channel_id, const WireDeckUiPluginDescriptor &descriptor)
    {
        ImGui::PushID(descriptor.id);
        const bool pressed = ImGui::Selectable(descriptor.label, false, ImGuiSelectableFlags_None, ImVec2(0.0f, 0.0f));
        if (pressed)
        {
            queue_add_plugin(snapshot, channel_id, descriptor.id);
        }
        if (descriptor.has_custom_ui != 0)
        {
            ImGui::SameLine();
            ImGui::TextDisabled("[UI]");
        }
        ImGui::PopID();
        return pressed;
    }

    bool render_plugin_bundle_group(WireDeckUiSnapshot *snapshot, const char *channel_id, int backend, const char *bundle_name)
    {
        bool drew_any = false;
        if (!ImGui::TreeNode(bundle_name))
        {
            return false;
        }

        for (int i = 0; i < snapshot->plugin_descriptor_count; ++i)
        {
            const WireDeckUiPluginDescriptor &descriptor = snapshot->plugin_descriptors[i];
            if (descriptor.backend != backend)
            {
                continue;
            }
            if (std::strcmp(descriptor.bundle_name, bundle_name) != 0)
            {
                continue;
            }
            drew_any = true;
            render_plugin_descriptor_button(snapshot, channel_id, descriptor);
        }

        ImGui::TreePop();
        return drew_any;
    }

    void render_plugin_param_controls(WireDeckUiSnapshot *snapshot, const WireDeckUiChannelPlugin &channel_plugin, const WireDeckUiPluginDescriptor *descriptor)
    {
        (void)snapshot;
        if (descriptor == nullptr)
        {
            return;
        }
        if (descriptor->backend == 2 && descriptor->has_custom_ui != 0)
        {
            return;
        }

        bool drew_any = false;
        for (int i = 0; i < snapshot->channel_plugin_param_count; ++i)
        {
            WireDeckUiChannelPluginParam &param = snapshot->channel_plugin_params[i];
            if (std::strcmp(param.plugin_id, channel_plugin.id) != 0)
            {
                continue;
            }
            if (!drew_any)
            {
                ImGui::Spacing();
                drew_any = true;
            }

            ImGui::PushID(param.symbol);
            if (param.toggled != 0)
            {
                bool enabled = param.value >= 0.5f;
                if (ImGui::Checkbox(param.label, &enabled))
                {
                    param.value = enabled ? 1.0f : 0.0f;
                }
            }
            else if (param.integer != 0)
            {
                int value = static_cast<int>(std::round(param.value));
                const int min_value = static_cast<int>(std::round(param.min_value));
                const int max_value = static_cast<int>(std::round(param.max_value));
                if (ImGui::SliderInt(param.label, &value, min_value, max_value))
                {
                    param.value = static_cast<float>(value);
                }
            }
            else
            {
                float value = param.value;
                if (ImGui::SliderFloat(param.label, &value, param.min_value, param.max_value, "%.2f"))
                {
                    param.value = value;
                }
            }
            ImGui::PopID();
        }
    }

    void render_input_fx_popup(WireDeckImGuiBridge *bridge, WireDeckUiSnapshot *snapshot, const char *channel_id)
    {
        const std::string popup_id = std::string("input_fx_popup##") + channel_id;
        ImGui::SetNextWindowSize(ImVec2(420.0f, 520.0f), ImGuiCond_FirstUseEver);
        if (!ImGui::BeginPopup(popup_id.c_str()))
        {
            return;
        }

        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(14.0f, 12.0f));
        ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(8.0f, 8.0f));
        ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(8.0f, 6.0f));

        ImDrawList *draw_list = ImGui::GetWindowDrawList();
        const ImVec2 win_pos = ImGui::GetWindowPos();
        const ImVec2 win_size = ImGui::GetWindowSize();
        draw_list->AddRectFilled(
            win_pos,
            ImVec2(win_pos.x + win_size.x, win_pos.y + win_size.y),
            ImGui::GetColorU32(ImVec4(0.08f, 0.09f, 0.14f, 0.98f)),
            14.0f);
        draw_list->AddRect(
            win_pos,
            ImVec2(win_pos.x + win_size.x, win_pos.y + win_size.y),
            ImGui::GetColorU32(ImVec4(0.60f, 0.66f, 0.86f, 0.10f)),
            14.0f,
            0,
            1.0f);

        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.93f, 0.94f, 0.98f, 0.98f));
        ImGui::TextUnformatted("Input FX");
        ImGui::PopStyleColor();

        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.66f, 0.68f, 0.77f, 0.72f));
        ImGui::TextWrapped("Chain for this input group.");
        ImGui::PopStyleColor();

        {
            const float y = ImGui::GetCursorScreenPos().y + 4.0f;
            draw_list->AddLine(
                ImVec2(win_pos.x + 12.0f, y),
                ImVec2(win_pos.x + win_size.x - 12.0f, y),
                ImGui::GetColorU32(ImVec4(1.0f, 1.0f, 1.0f, 0.06f)),
                1.0f);
        }

        ImGui::Dummy(ImVec2(0.0f, 8.0f));

        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.93f, 0.94f, 0.98f, 0.98f));
        ImGui::TextUnformatted("Active plugins");
        ImGui::PopStyleColor();

        ImGui::Dummy(ImVec2(0.0f, 2.0f));

        bool has_plugins = false;
        for (int i = 0; i < snapshot->channel_plugin_count; ++i)
        {
            WireDeckUiChannelPlugin &channel_plugin = snapshot->channel_plugins[i];
            if (std::strcmp(channel_plugin.channel_id, channel_id) != 0)
            {
                continue;
            }

            has_plugins = true;
            ImGui::PushID(channel_plugin.id);
            const WireDeckUiPluginDescriptor *descriptor = find_plugin_descriptor(snapshot, channel_plugin.descriptor_id);
            const bool has_custom_ui = descriptor != nullptr && descriptor->has_custom_ui != 0;
            const bool enabled = channel_plugin.enabled != 0;
            const float row_h = 46.0f;
            const float row_w = ImGui::GetContentRegionAvail().x;
            const ImVec2 row_pos = ImGui::GetCursorScreenPos();
            const ImVec2 row_min(row_pos.x, row_pos.y);
            const ImVec2 row_max(row_pos.x + row_w, row_pos.y + row_h);

            draw_list->AddRectFilled(
                row_min,
                row_max,
                ImGui::GetColorU32(ImVec4(0.12f, 0.14f, 0.20f, 0.94f)),
                10.0f);
            draw_list->AddRect(
                row_min,
                row_max,
                ImGui::GetColorU32(ImVec4(1.0f, 1.0f, 1.0f, 0.05f)),
                10.0f,
                0,
                1.0f);

            draw_list->AddText(
                ImVec2(row_min.x + 12.0f, row_min.y + 8.0f),
                ImGui::GetColorU32(ImVec4(0.93f, 0.94f, 0.98f, 0.96f)),
                channel_plugin.label);
            draw_list->AddText(
                ImVec2(row_min.x + 12.0f, row_min.y + 25.0f),
                ImGui::GetColorU32(ImVec4(0.66f, 0.68f, 0.77f, 0.72f)),
                plugin_backend_label(channel_plugin.backend));

            const float btn_y = row_min.y + 8.0f;
            const float btn_h = 28.0f;
            const float btn_w = 28.0f;
            const float remove_w = 28.0f;
            const float remove_x = row_max.x - 10.0f - remove_w;
            const float ui_x = remove_x - btn_w;
            const float bypass_x = ui_x - btn_w;
            const ImU32 flat_button_col = ImGui::GetColorU32(ImVec4(0.18f, 0.20f, 0.29f, 0.96f));

            draw_list->AddRectFilled(
                ImVec2(bypass_x, btn_y),
                ImVec2(remove_x + remove_w, btn_y + btn_h),
                flat_button_col,
                8.0f);
            draw_list->AddLine(
                ImVec2(ui_x, btn_y + 4.0f),
                ImVec2(ui_x, btn_y + btn_h - 4.0f),
                ImGui::GetColorU32(ImVec4(1.0f, 1.0f, 1.0f, 0.10f)),
                1.0f);
            draw_list->AddLine(
                ImVec2(remove_x, btn_y + 4.0f),
                ImVec2(remove_x, btn_y + btn_h - 4.0f),
                ImGui::GetColorU32(ImVec4(1.0f, 1.0f, 1.0f, 0.10f)),
                1.0f);
            ImGui::SetCursorScreenPos(ImVec2(bypass_x, btn_y));
            const bool toggle_clicked = render_fixed_icon_button(
                enabled ? bridge->toggle_right_icon : bridge->toggle_left_icon,
                "##toggle",
                ImVec2(btn_w, btn_h),
                13.0f,
                enabled ? ImVec4(0.88f, 0.80f, 0.18f, 1.0f) : ImVec4(0.92f, 0.45f, 0.72f, 1.0f));
            if (toggle_clicked)
            {
                channel_plugin.enabled = enabled ? 0 : 1;
            }
            ImGui::SetCursorScreenPos(ImVec2(ui_x, btn_y));
            const bool ui_clicked = render_fixed_icon_button(
                bridge->config_icon,
                "##ui",
                ImVec2(btn_w, btn_h),
                13.0f,
                has_custom_ui ? ImVec4(0.95f, 0.96f, 0.98f, 0.95f) : ImVec4(0.56f, 0.60f, 0.68f, 0.78f));
            const bool ui_hovered = ImGui::IsItemHovered();
            if (ui_clicked && has_custom_ui)
            {
                queue_open_plugin_ui(snapshot, channel_plugin.id);
            }
            if (ui_hovered && has_custom_ui && descriptor != nullptr && descriptor->primary_ui_uri != nullptr && descriptor->primary_ui_uri[0] != '\0')
            {
                ImGui::SetTooltip("%s", descriptor->primary_ui_uri);
            }

            ImGui::SetCursorScreenPos(ImVec2(remove_x, btn_y));
            if (render_delete_icon_button(bridge, "##remove", ImVec2(remove_w, btn_h), 0.0f))
            {
                queue_remove_plugin(snapshot, channel_plugin.id);
            }

            ImGui::SetCursorScreenPos(row_pos);
            ImGui::Dummy(ImVec2(row_w, row_h));
            ImGui::PopID();
        }

        if (!has_plugins)
        {
            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.66f, 0.68f, 0.77f, 0.72f));
            ImGui::TextUnformatted("No FX in this input.");
            ImGui::PopStyleColor();
        }

        ImGui::Dummy(ImVec2(0.0f, 6.0f));
        {
            const float y = ImGui::GetCursorScreenPos().y + 2.0f;
            draw_list->AddLine(
                ImVec2(win_pos.x + 12.0f, y),
                ImVec2(win_pos.x + win_size.x - 12.0f, y),
                ImGui::GetColorU32(ImVec4(1.0f, 1.0f, 1.0f, 0.06f)),
                1.0f);
        }
        ImGui::Dummy(ImVec2(0.0f, 8.0f));

        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.93f, 0.94f, 0.98f, 0.98f));
        ImGui::TextUnformatted("Add plugin");
        ImGui::PopStyleColor();

        const float filter_w = 170.0f;
        const float filter_x = ImGui::GetCursorPosX() + ImGui::GetContentRegionAvail().x - filter_w;
        ImGui::SameLine();
        if (filter_x > ImGui::GetCursorPosX())
        {
            ImGui::SetCursorPosX(filter_x);
        }
        ImGui::SetNextItemWidth(filter_w);
        ImGui::InputTextWithHint("##fx_plugin_filter", "Search plugins...", bridge->fx_plugin_filter.data(), bridge->fx_plugin_filter.size());

        const std::string filter = lower_copy(bridge->fx_plugin_filter.data());
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.66f, 0.68f, 0.77f, 0.72f));
        ImGui::TextUnformatted(filter.empty() ? "Available plugins" : "Filtered results");
        ImGui::PopStyleColor();

        ImGui::Dummy(ImVec2(0.0f, 4.0f));

        ImGui::PushStyleVar(ImGuiStyleVar_ChildRounding, 0.0f);
        ImGui::BeginChild("available_plugins_list", ImVec2(0.0f, 230.0f), ImGuiChildFlags_Borders, ImGuiWindowFlags_None);
        ImDrawList *list_draw = ImGui::GetWindowDrawList();

        bool drew_any = false;
        if (!filter.empty())
        {
            int filtered_index = 0;
            for (int i = 0; i < snapshot->plugin_descriptor_count; ++i)
            {
                const WireDeckUiPluginDescriptor &descriptor = snapshot->plugin_descriptors[i];
                if (!plugin_matches_filter(descriptor, filter))
                {
                    continue;
                }

                drew_any = true;
                const float row_h = 34.0f;
                const float row_w = ImGui::GetContentRegionAvail().x;
                const ImVec2 row_pos = ImGui::GetCursorScreenPos();
                const ImVec2 row_min(row_pos.x, row_pos.y);
                const ImVec2 row_max(row_pos.x + row_w, row_pos.y + row_h);

                ImGui::SetCursorScreenPos(row_pos);
                ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 0.0f);
                ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0, 0, 0, 0));
                ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(1, 1, 1, 0.03f));
                ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(1, 1, 1, 0.05f));
                const bool clicked = ImGui::Button(("##filtered_plugin_" + std::to_string(filtered_index)).c_str(), ImVec2(row_w, row_h));
                const bool hovered = ImGui::IsItemHovered();
                ImGui::PopStyleColor(3);
                ImGui::PopStyleVar();

                list_draw->AddText(
                    ImVec2(row_min.x + 10.0f, row_min.y + 5.0f),
                    ImGui::GetColorU32(hovered ? ImVec4(0.97f, 0.98f, 1.0f, 1.0f) : ImVec4(0.90f, 0.91f, 0.96f, 0.92f)),
                    descriptor.label);
                const char *subtitle = (descriptor.bundle_name != nullptr && descriptor.bundle_name[0] != '\0') ? descriptor.bundle_name : plugin_backend_label(descriptor.backend);
                list_draw->AddText(
                    ImVec2(row_min.x + 10.0f, row_min.y + 18.0f),
                    ImGui::GetColorU32(hovered ? ImVec4(0.78f, 0.80f, 0.88f, 0.82f) : ImVec4(0.66f, 0.68f, 0.77f, 0.70f)),
                    subtitle);

                list_draw->AddLine(
                    ImVec2(row_min.x, row_max.y),
                    ImVec2(row_max.x, row_max.y),
                    ImGui::GetColorU32(ImVec4(1, 1, 1, 0.06f)),
                    1.0f);

                ImGui::SetCursorScreenPos(ImVec2(row_pos.x, row_pos.y + row_h));
                if (clicked)
                {
                    queue_add_plugin(snapshot, channel_id, descriptor.id);
                }
                filtered_index += 1;
            }
        }
        else
        {
            std::vector<std::string> groups{};
            groups.reserve(snapshot->plugin_descriptor_count);
            for (int i = 0; i < snapshot->plugin_descriptor_count; ++i)
            {
                const WireDeckUiPluginDescriptor &descriptor = snapshot->plugin_descriptors[i];
                const char *bundle_name = (descriptor.bundle_name != nullptr && descriptor.bundle_name[0] != '\0') ? descriptor.bundle_name : plugin_backend_label(descriptor.backend);
                const std::string key(bundle_name);
                if (std::find(groups.begin(), groups.end(), key) == groups.end())
                {
                    groups.push_back(key);
                }
            }

            for (std::size_t group_index = 0; group_index < groups.size(); ++group_index)
            {
                const std::string &group = groups[group_index];
                bool &is_open = bridge->fx_group_open[group];

                const float header_h = 30.0f;
                const float header_w = ImGui::GetContentRegionAvail().x;
                const ImVec2 header_pos = ImGui::GetCursorScreenPos();
                const ImVec2 header_min(header_pos.x, header_pos.y);
                const ImVec2 header_max(header_pos.x + header_w, header_pos.y + header_h);

                ImGui::SetCursorScreenPos(header_pos);
                ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 0.0f);
                ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0, 0, 0, 0));
                ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(1, 1, 1, 0.03f));
                ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(1, 1, 1, 0.05f));
                const bool clicked_header = ImGui::Button(("##group_" + std::to_string(group_index)).c_str(), ImVec2(header_w, header_h));
                const bool hovered_header = ImGui::IsItemHovered();
                ImGui::PopStyleColor(3);
                ImGui::PopStyleVar();

                if (clicked_header)
                {
                    is_open = !is_open;
                }

                list_draw->AddText(
                    ImVec2(header_min.x + 8.0f, header_min.y + 7.0f),
                    ImGui::GetColorU32(hovered_header ? ImVec4(0.92f, 0.93f, 0.98f, 0.92f) : ImVec4(0.74f, 0.76f, 0.84f, 0.78f)),
                    is_open ? "v" : ">");
                list_draw->AddText(
                    ImVec2(header_min.x + 24.0f, header_min.y + 7.0f),
                    ImGui::GetColorU32(hovered_header ? ImVec4(0.92f, 0.93f, 0.98f, 0.95f) : ImVec4(0.72f, 0.74f, 0.82f, 0.78f)),
                    group.c_str());
                list_draw->AddLine(
                    ImVec2(header_min.x, header_max.y),
                    ImVec2(header_max.x, header_max.y),
                    ImGui::GetColorU32(ImVec4(1, 1, 1, 0.05f)),
                    1.0f);

                ImGui::SetCursorScreenPos(ImVec2(header_pos.x, header_pos.y + header_h));

                if (is_open)
                {
                    for (int i = 0; i < snapshot->plugin_descriptor_count; ++i)
                    {
                        const WireDeckUiPluginDescriptor &descriptor = snapshot->plugin_descriptors[i];
                        const char *bundle_name = (descriptor.bundle_name != nullptr && descriptor.bundle_name[0] != '\0') ? descriptor.bundle_name : plugin_backend_label(descriptor.backend);
                        if (group != bundle_name)
                        {
                            continue;
                        }

                        drew_any = true;
                        const float row_h = 30.0f;
                        const float row_w = ImGui::GetContentRegionAvail().x;
                        const ImVec2 row_pos = ImGui::GetCursorScreenPos();
                        const ImVec2 row_min(row_pos.x, row_pos.y);
                        const ImVec2 row_max(row_pos.x + row_w, row_pos.y + row_h);

                        ImGui::SetCursorScreenPos(row_pos);
                        ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 0.0f);
                        ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0, 0, 0, 0));
                        ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(1, 1, 1, 0.03f));
                        ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(1, 1, 1, 0.05f));
                        const bool clicked = ImGui::Button(("##plugin_" + std::string(descriptor.id)).c_str(), ImVec2(row_w, row_h));
                        const bool hovered = ImGui::IsItemHovered();
                        ImGui::PopStyleColor(3);
                        ImGui::PopStyleVar();

                        list_draw->AddText(
                            ImVec2(row_min.x + 28.0f, row_min.y + 7.0f),
                            ImGui::GetColorU32(hovered ? ImVec4(0.97f, 0.98f, 1.0f, 1.0f) : ImVec4(0.90f, 0.91f, 0.96f, 0.92f)),
                            descriptor.label);

                        list_draw->AddLine(
                            ImVec2(row_min.x + 24.0f, row_max.y),
                            ImVec2(row_max.x, row_max.y),
                            ImGui::GetColorU32(ImVec4(1, 1, 1, 0.05f)),
                            1.0f);

                        ImGui::SetCursorScreenPos(ImVec2(row_pos.x, row_pos.y + row_h));
                        if (clicked)
                        {
                            queue_add_plugin(snapshot, channel_id, descriptor.id);
                        }
                    }
                }

                if (group_index + 1 < groups.size())
                {
                    list_draw->AddLine(
                        ImVec2(header_min.x, ImGui::GetCursorScreenPos().y + 2.0f),
                        ImVec2(header_max.x, ImGui::GetCursorScreenPos().y + 2.0f),
                        ImGui::GetColorU32(ImVec4(1, 1, 1, 0.04f)),
                        1.0f);
                    ImGui::Dummy(ImVec2(0.0f, 6.0f));
                }
            }
        }

        if (!drew_any)
        {
            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.66f, 0.68f, 0.77f, 0.72f));
            ImGui::TextUnformatted(filter.empty() ? "No plugins found." : "No plugins match your search.");
            ImGui::PopStyleColor();
        }

        ImGui::EndChild();
        ImGui::PopStyleVar();
        ImGui::PopStyleVar(3);
        ImGui::EndPopup();
    }

    float source_activity(const WireDeckUiSource &source, int frame_index, float phase_offset)
    {
        (void)frame_index;
        (void)phase_offset;
        if (source.muted != 0)
        {
            return 0.0f;
        }
        return std::clamp(source.level, 0.0f, 1.0f);
    }

    float linear_to_db(float value)
    {
        if (value <= 0.000001f)
        {
            return -std::numeric_limits<float>::infinity();
        }
        return 20.0f * std::log10(value);
    }

    float source_activity_left(const WireDeckUiSource &source)
    {
        if (source.muted != 0)
            return 0.0f;
        return std::clamp(source.level_left, 0.0f, 1.0f);
    }

    float source_activity_right(const WireDeckUiSource &source)
    {
        if (source.muted != 0)
            return 0.0f;
        return std::clamp(source.level_right, 0.0f, 1.0f);
    }

    float input_card_activity(WireDeckUiSnapshot *snapshot, const WireDeckUiChannel &channel, int frame_index, float phase_offset)
    {
        if (snapshot == nullptr || channel.id == nullptr)
        {
            return 0.0f;
        }
        float energy = 0.0f;
        int enabled_sources = 0;
        for (int i = 0; i < snapshot->channel_source_count; ++i)
        {
            const WireDeckUiChannelSource &channel_source = snapshot->channel_sources[i];
            if (channel_source.enabled == 0 || !safe_streq(channel_source.channel_id, channel.id))
            {
                continue;
            }

            WireDeckUiSource *source = find_source(snapshot, channel_source.source_id);
            if (source == nullptr)
            {
                continue;
            }

            const float source_level = source_activity(*source, frame_index, phase_offset + static_cast<float>(enabled_sources) * 0.73f);
            energy += source_level * source_level;
            enabled_sources += 1;
        }

        if (enabled_sources == 0)
        {
            return 0.0f;
        }

        return std::clamp(std::sqrt(energy / static_cast<float>(enabled_sources)), 0.0f, 1.0f);
    }

    WireDeckUiChannelSource *find_channel_source(WireDeckUiSnapshot *snapshot, const char *channel_id, const char *source_id)
    {
        if (snapshot == nullptr || channel_id == nullptr || source_id == nullptr)
        {
            return nullptr;
        }
        for (int i = 0; i < snapshot->channel_source_count; ++i)
        {
            WireDeckUiChannelSource &channel_source = snapshot->channel_sources[i];
            if (safe_streq(channel_source.channel_id, channel_id) && safe_streq(channel_source.source_id, source_id))
            {
                return &channel_source;
            }
        }
        return nullptr;
    }

    std::string input_source_preview(WireDeckUiSnapshot *snapshot, const char *channel_id)
    {
        if (snapshot == nullptr || channel_id == nullptr)
        {
            return "No sources";
        }
        int enabled_count = 0;
        const char *single_label = nullptr;
        for (int i = 0; i < snapshot->channel_source_count; ++i)
        {
            WireDeckUiChannelSource &channel_source = snapshot->channel_sources[i];
            if (!safe_streq(channel_source.channel_id, channel_id) || channel_source.enabled == 0)
            {
                continue;
            }
            enabled_count += 1;
            if (enabled_count == 1)
            {
                if (WireDeckUiSource *source = find_source(snapshot, channel_source.source_id))
                {
                    single_label = preferred_source_label_for_channel(snapshot, channel_id, *source);
                }
            }
        }
        if (enabled_count == 0)
        {
            return "No sources";
        }
        if (enabled_count == 1 && single_label != nullptr)
        {
            return single_label;
        }
        return std::to_string(enabled_count) + " sources";
    }

    void render_input_sources_popup(WireDeckUiSnapshot *snapshot, const char *channel_id)
    {
        if (snapshot == nullptr || channel_id == nullptr)
        {
            return;
        }
        const std::string popup_id = std::string("input_sources_popup##") + channel_id;
        if (ImGui::BeginPopupModal(popup_id.c_str(), nullptr, ImGuiWindowFlags_AlwaysAutoResize))
        {
            ImGui::TextUnformatted("Edit sources");
            ImGui::TextDisabled("Choose which physical and app sources belong to this input.");
            ImGui::Separator();

            for (int i = 0; i < snapshot->source_count; ++i)
            {
                WireDeckUiSource &source = snapshot->sources[i];
                WireDeckUiChannelSource *channel_source = find_channel_source(snapshot, channel_id, source.id);
                if (channel_source == nullptr)
                {
                    continue;
                }
                const char *subtitle = (source.subtitle != nullptr && source.subtitle[0] != 0) ? source.subtitle : "Other";
                bool enabled = channel_source->enabled != 0;
                ImGui::PushID(source.id);
                if (ImGui::Checkbox("##source_enabled", &enabled))
                {
                    channel_source->enabled = enabled ? 1 : 0;
                }
                ImGui::SameLine();
                ImGui::BeginGroup();
                ImGui::TextUnformatted(preferred_source_label_for_channel(snapshot, channel_id, source));
                ImGui::TextDisabled("%s", subtitle);
                ImGui::EndGroup();
                ImGui::PopID();
            }

            ImGui::Dummy(ImVec2(0.0f, 8.0f));
            if (ImGui::Button("Done", ImVec2(160.0f, 0.0f)))
            {
                ImGui::CloseCurrentPopup();
            }
            ImGui::EndPopup();
        }
    }

    void render_rename_popup(
        WireDeckImGuiBridge *bridge,
        const char *popup_id,
        WireDeckUiSnapshot *snapshot,
        const char *entity_id,
        const char *current_label,
        bool rename_input)
    {
        if (ImGui::IsItemHovered() && ImGui::IsMouseDoubleClicked(ImGuiMouseButton_Left))
        {
            std::snprintf(bridge->rename_buffer.data(), bridge->rename_buffer.size(), "%s", current_label ? current_label : "");
            bridge->focus_rename_input = true;
            ImGui::OpenPopup(popup_id);
        }

        if (ImGui::BeginPopup(popup_id))
        {
            ImGui::TextUnformatted("Rename");
            ImGui::SetNextItemWidth(180.0f);
            if (bridge->focus_rename_input)
            {
                ImGui::SetKeyboardFocusHere();
                bridge->focus_rename_input = false;
            }
            const bool save_from_enter = ImGui::InputText(
                "##rename_value",
                bridge->rename_buffer.data(),
                bridge->rename_buffer.size(),
                ImGuiInputTextFlags_EnterReturnsTrue | ImGuiInputTextFlags_AutoSelectAll);
            const bool cancel_from_escape = ImGui::IsKeyPressed(ImGuiKey_Escape);

            if (save_from_enter || ImGui::Button("Save"))
            {
                if (rename_input)
                {
                    queue_input_rename(snapshot, entity_id, bridge->rename_buffer.data());
                }
                else
                {
                    queue_output_rename(snapshot, entity_id, bridge->rename_buffer.data());
                }
                ImGui::CloseCurrentPopup();
            }
            ImGui::SameLine();
            if (cancel_from_escape || ImGui::Button("Cancel"))
            {
                ImGui::CloseCurrentPopup();
            }
            ImGui::EndPopup();
        }
    }

    bool render_thin_volume_slider(const char *id, float *percent, float height)
    {
        const float vertical_padding = std::max(0.0f, (height - ImGui::GetFontSize()) * 0.5f);
        ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(0.0f, vertical_padding));
        ImGui::PushStyleVar(ImGuiStyleVar_GrabMinSize, 6.0f);
        ImGui::PushStyleColor(ImGuiCol_FrameBg, ImVec4(0.0f, 0.0f, 0.0f, 0.0f));
        ImGui::PushStyleColor(ImGuiCol_FrameBgHovered, ImVec4(0.10f, 0.10f, 0.12f, 0.18f));
        ImGui::PushStyleColor(ImGuiCol_FrameBgActive, ImVec4(0.14f, 0.14f, 0.16f, 0.24f));
        ImGui::PushStyleColor(ImGuiCol_SliderGrab, ImVec4(0.82f, 0.84f, 0.88f, 0.95f));
        ImGui::PushStyleColor(ImGuiCol_SliderGrabActive, ImVec4(1.0f, 0.62f, 0.22f, 1.0f));
        ImGui::SetNextItemWidth(-1.0f);
        const bool changed = ImGui::SliderFloat(id, percent, 0.0f, 100.0f, "", ImGuiSliderFlags_NoInput);
        ImGui::PopStyleColor(5);
        ImGui::PopStyleVar(2);
        return changed;
    }

    std::string routing_summary(WireDeckUiSnapshot *snapshot, const char *channel_id)
    {
        int enabled_count = 0;
        const char *first_enabled = nullptr;

        for (int bus_index = 0; bus_index < snapshot->bus_count; ++bus_index)
        {
            const WireDeckUiBus &bus = snapshot->buses[bus_index];
            WireDeckUiSend *send = find_send(snapshot, channel_id, bus.id);
            if (send != nullptr && send->enabled != 0)
            {
                enabled_count += 1;
                if (first_enabled == nullptr)
                {
                    first_enabled = bus.label ? bus.label : bus.id;
                }
            }
        }

        if (enabled_count == 0)
        {
            return "No outputs";
        }
        if (enabled_count == 1 && first_enabled != nullptr)
        {
            return first_enabled;
        }
        return std::to_string(enabled_count) + " outputs";
    }

    void render_routing_dropdown(WireDeckUiSnapshot *snapshot, const char *channel_id)
    {
        const std::string preview = routing_summary(snapshot, channel_id);
        ImGui::SetNextItemWidth(-1.0f);
        if (ImGui::BeginCombo("##to_outputs_combo", preview.c_str()))
        {
            for (int bus_index = 0; bus_index < snapshot->bus_count; ++bus_index)
            {
                WireDeckUiBus &bus = snapshot->buses[bus_index];
                WireDeckUiSend *send = find_send(snapshot, channel_id, bus.id);
                if (send == nullptr)
                {
                    continue;
                }

                ImGui::PushID(bus.id);
                bool enabled = send->enabled != 0;
                if (ImGui::Checkbox(bus.label, &enabled))
                {
                    send->enabled = enabled ? 1 : 0;
                }

                ImGui::SameLine();
                ImGui::SetNextItemWidth(92.0f);
                float gain_percent = send->gain * 100.0f;
                if (!enabled)
                {
                    ImGui::BeginDisabled();
                }
                if (ImGui::SliderFloat("##route_gain_slider", &gain_percent, 0.0f, 100.0f, "%.0f%%", 0))
                {
                    send->gain = gain_percent / 100.0f;
                }
                if (!enabled)
                {
                    ImGui::EndDisabled();
                }
                ImGui::PopID();
            }
            ImGui::EndCombo();
        }
    }

    WireDeckUiBusDestination *find_bus_destination(WireDeckUiSnapshot *snapshot, const char *bus_id, const char *destination_id)
    {
        for (int i = 0; i < snapshot->bus_destination_count; ++i)
        {
            WireDeckUiBusDestination &bus_destination = snapshot->bus_destinations[i];
            if (safe_streq(bus_destination.bus_id, bus_id) and safe_streq(bus_destination.destination_id, destination_id))
            {
                return &bus_destination;
            }
        }
        return nullptr;
    }

    int count_selected_destinations(WireDeckUiSnapshot *snapshot, const char *bus_id)
    {
        int count = 0;
        for (int i = 0; i < snapshot->bus_destination_count; ++i)
        {
            const WireDeckUiBusDestination &bus_destination = snapshot->bus_destinations[i];
            if (safe_streq(bus_destination.bus_id, bus_id) && bus_destination.enabled != 0)
            {
                count += 1;
            }
        }
        return count;
    }

    std::string output_destination_preview(WireDeckUiSnapshot *snapshot, const char *bus_id)
    {
        const int selected_count = count_selected_destinations(snapshot, bus_id);
        if (selected_count == 0)
        {
            return "No destinations";
        }
        if (selected_count == 1)
        {
            for (int i = 0; i < snapshot->destination_count; ++i)
            {
                const WireDeckUiDestination &destination = snapshot->destinations[i];
                const WireDeckUiBusDestination *bus_destination = find_bus_destination(snapshot, bus_id, destination.id);
                if (bus_destination != nullptr && bus_destination->enabled != 0)
                {
                    std::string preview = destination.label ? destination.label : destination.id;
                    if (destination.muted != 0)
                    {
                        preview += " (Muted)";
                    }
                    else
                    {
                        if (preview.length() > 25)
                        {
                            preview = preview.substr(0, 20) + "...";
                        }
                        const int volume_percent = static_cast<int>(std::round(std::clamp(destination.volume, 0.0f, 4.0f) * 100.0f));
                        preview += " (" + std::to_string(volume_percent) + "%)";
                    }

                    return preview;
                }
            }
        }
        return std::to_string(selected_count) + " destinations";
    }

    std::string system_capture_status_label(const WireDeckUiBus &bus)
    {
        if (bus.system_muted != 0)
        {
            return "System capture muted";
        }
        const int volume_percent = static_cast<int>(std::round(std::clamp(bus.system_volume, 0.0f, 4.0f) * 100.0f));
        return "System capture " + std::to_string(volume_percent) + "%";
    }

    const char *destination_kind_label(int kind)
    {
        switch (kind)
        {
        case 0:
            return "PHYSICAL";
        case 1:
            return "VIRTUAL";
        case 2:
            return "DEVICE";
        default:
            return "DEST";
        }
    }

    ImVec4 destination_kind_color(int kind)
    {
        switch (kind)
        {
        case 0:
            return ImVec4(0.25f, 0.78f, 0.96f, 1.0f);
        case 1:
            return ImVec4(0.95f, 0.60f, 0.16f, 1.0f);
        case 2:
            return ImVec4(0.34f, 0.86f, 0.45f, 1.0f);
        default:
            return ImVec4(0.72f, 0.72f, 0.76f, 1.0f);
        }
    }

    void render_output_destination_dropdown(WireDeckUiSnapshot *snapshot, WireDeckUiBus &bus)
    {
        const std::string preview = output_destination_preview(snapshot, bus.id);
        ImGui::SetNextItemWidth(-1.0f);
        if (ImGui::BeginCombo("##destination_combo", preview.c_str()))
        {
            std::string current_group;
            for (int i = 0; i < snapshot->destination_count; ++i)
            {
                WireDeckUiDestination &destination = snapshot->destinations[i];
                WireDeckUiBusDestination *bus_destination = find_bus_destination(snapshot, bus.id, destination.id);
                if (bus_destination == nullptr)
                {
                    continue;
                }
                const char *subtitle = (destination.subtitle != nullptr and destination.subtitle[0] != 0) ? destination.subtitle : "Other";
                if (current_group != subtitle)
                {
                    if (!current_group.empty())
                    {
                        ImGui::Spacing();
                    }
                    current_group = subtitle;
                    ImGui::TextDisabled("%s", subtitle);
                }
                bool enabled = bus_destination->enabled != 0;
                ImGui::PushID(destination.id);
                if (ImGui::Checkbox("##destination_enabled", &enabled))
                {
                    bus_destination->enabled = enabled ? 1 : 0;
                }
                ImGui::SameLine();
                ImGui::BeginGroup();
                ImGui::TextUnformatted(destination.label);
                ImGui::PushStyleColor(ImGuiCol_Text, destination_kind_color(destination.kind));
                ImGui::TextUnformatted(destination_kind_label(destination.kind));
                ImGui::PopStyleColor();
                ImGui::EndGroup();
                ImGui::PopID();
            }
            ImGui::EndCombo();
        }
    }

    void render_input_card(WireDeckImGuiBridge *bridge, WireDeckUiSnapshot *snapshot, WireDeckUiChannel &channel, int index, float card_width, float card_height)
    {
        WireDeckUiSource *bound_source = find_bound_source_for_channel(snapshot, channel);
        const bool source_active = bound_source != nullptr;
        const float meter = channel.level > 0.0f ? channel.level : (bound_source != nullptr ? source_activity(*bound_source, bridge->frame_index, static_cast<float>(index) * 0.7f) : 0.0f);
        const float meter_left = channel.level_left > 0.0f ? channel.level_left : (bound_source != nullptr ? source_activity_left(*bound_source) : meter);
        const float meter_right = channel.level_right > 0.0f ? channel.level_right : (bound_source != nullptr ? source_activity_right(*bound_source) : meter);
        const float display_meter_left = std::clamp(meter_left, 0.0f, 1.0f);
        const float display_meter_right = std::clamp(meter_right, 0.0f, 1.0f);
        const int fx_count = count_channel_plugins(snapshot, channel.id);
        const char *title = channel.label;
        const char *subtitle = bound_source != nullptr ? bound_source->subtitle : channel.subtitle;
        const bool muted = channel.muted != 0 || (bound_source != nullptr && bound_source->muted != 0);

        ImGui::PushID(channel.id);
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(14.0f, 12.0f));
        ImGui::BeginChild(
            "input_card",
            ImVec2(card_width, card_height),
            ImGuiChildFlags_Borders,
            ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse);
        ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(8.0f, 6.0f));
        ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(8.0f, 6.0f));

        const ImVec2 win_pos = ImGui::GetWindowPos();
        const ImVec2 win_size = ImGui::GetWindowSize();
        const ImVec2 card_min = win_pos;
        const ImVec2 card_max(win_pos.x + win_size.x, win_pos.y + win_size.y);
        ImDrawList *draw_list = ImGui::GetWindowDrawList();

        draw_list->AddRectFilled(card_min, card_max, ImGui::GetColorU32(ImVec4(0.08f, 0.09f, 0.14f, 0.96f)), 18.0f);
        draw_list->AddRect(card_min, card_max, ImGui::GetColorU32(ImVec4(0.60f, 0.66f, 0.86f, 0.10f)), 18.0f);

        const float pad_x = 18.0f;
        const float header_y = 16.0f;
        const float icon_size = 28.0f;
        ImGui::SetCursorPos(ImVec2(pad_x, header_y));

        WireDeckIconTexture *icon_texture = resolve_channel_icon_texture(bridge, channel);
        if (icon_texture != nullptr && icon_texture->descriptor_set != VK_NULL_HANDLE)
        {
            ImGui::InvisibleButton("##icon", ImVec2(icon_size, icon_size));
            const ImVec2 icon_min = ImGui::GetItemRectMin();
            const ImVec2 icon_max = ImGui::GetItemRectMax();
            const float inset = 1.0f;
            const ImVec4 tint = source_active ? ImVec4(0.95f, 0.96f, 0.98f, 1.0f) : ImVec4(0.58f, 0.58f, 0.60f, 0.48f);
            draw_list->AddImage(
                icon_texture->descriptor_set,
                ImVec2(icon_min.x + inset, icon_min.y + inset),
                ImVec2(icon_max.x - inset, icon_max.y - inset),
                ImVec2(0.0f, 0.0f),
                ImVec2(1.0f, 1.0f),
                ImGui::GetColorU32(tint));
        }
        else
        {
            ImGui::InvisibleButton("##icon", ImVec2(icon_size, icon_size));
            const ImVec2 icon_min = ImGui::GetItemRectMin();
            const ImVec2 icon_max = ImGui::GetItemRectMax();
            const float cx = (icon_min.x + icon_max.x) * 0.5f;
            const float cy = (icon_min.y + icon_max.y) * 0.5f;
            const ImVec4 fallback_tint = source_active ? ImVec4(0.92f, 0.93f, 0.97f, 1.0f) : ImVec4(0.92f, 0.93f, 0.97f, 0.42f);
            draw_list->AddCircleFilled(ImVec2(cx, cy - 4.0f), 4.6f, ImGui::GetColorU32(fallback_tint), 20);
            draw_list->AddRectFilled(
                ImVec2(cx - 7.0f, cy + 1.0f),
                ImVec2(cx + 7.0f, cy + 11.0f),
                ImGui::GetColorU32(fallback_tint),
                4.0f);
        }

        ImGui::SameLine(0.0f, 12.0f);
        ImGui::BeginGroup();
        ImGui::SetCursorPosY(ImGui::GetCursorPosY() + 1.0f);
        ImGui::TextUnformatted(title);
        render_rename_popup(bridge, "rename_input_popup", snapshot, channel.id, title, true);

        const float detected_y_offset = 3.0f;
        const ImVec2 subtitle_pos = ImGui::GetCursorScreenPos();
        draw_list->AddCircleFilled(
            ImVec2(subtitle_pos.x + 6.0f, subtitle_pos.y + detected_y_offset + 3.0f),
            4.0f,
            ImGui::GetColorU32(source_active ? ImVec4(0.36f, 0.86f, 0.42f, 1.0f) : ImVec4(0.92f, 0.29f, 0.26f, 1.0f)),
            16);
        ImGui::Dummy(ImVec2(15.0f, 0.0f));
        ImGui::SetCursorPosY(ImGui::GetCursorPosY() + detected_y_offset);
        ImGui::SameLine(0.0f, 0.0f);
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.66f, 0.68f, 0.77f, 0.72f));
        ImGui::TextUnformatted((subtitle != nullptr && subtitle[0] != '\0') ? subtitle : "Detected Source");
        ImGui::PopStyleColor();
        ImGui::EndGroup();

        const float dots_center_y = win_pos.y + header_y;
        const float dots_base_x = win_pos.x + win_size.x - 31.0f;
        const float dot_gap = 6.0f;
        const float dot_radius = 1.7f;
        const ImU32 dot_color = ImGui::GetColorU32(ImVec4(0.68f, 0.70f, 0.80f, 0.55f));
        draw_list->AddCircleFilled(ImVec2(dots_base_x, dots_center_y), dot_radius, dot_color, 12);
        draw_list->AddCircleFilled(ImVec2(dots_base_x + dot_gap, dots_center_y), dot_radius, dot_color, 12);
        draw_list->AddCircleFilled(ImVec2(dots_base_x + dot_gap * 2.0f, dots_center_y), dot_radius, dot_color, 12);

        ImGui::SetCursorPos(ImVec2(card_width - 38.0f, 8.0f));
        ImGui::InvisibleButton("##card_menu", ImVec2(24.0f, 18.0f));
        if (ImGui::IsItemClicked())
        {
            const std::string popup_id = std::string("input_card_menu##") + channel.id;
            ImGui::OpenPopup(popup_id.c_str());
        }
        {
            const std::string popup_id = std::string("input_card_menu##") + channel.id;
            if (ImGui::BeginPopup(popup_id.c_str()))
            {
                if (ImGui::MenuItem("Change icon"))
                {
                    queue_input_icon_pick(snapshot, channel.id);
                    ImGui::CloseCurrentPopup();
                }
                if (ImGui::MenuItem("Delete input"))
                {
                    queue_input_delete(snapshot, channel.id);
                    ImGui::CloseCurrentPopup();
                }
                ImGui::EndPopup();
            }
        }

        const float sep_y = 60.0f;
        draw_list->AddLine(
            ImVec2(win_pos.x + 16.0f, win_pos.y + sep_y),
            ImVec2(win_pos.x + win_size.x - 16.0f, win_pos.y + sep_y),
            ImGui::GetColorU32(ImVec4(1.0f, 1.0f, 1.0f, 0.06f)),
            1.0f);

        const float body_y = 70.0f;
        const float btn_x = 18.0f;
        const float btn_h = 30.0f;
        const float fx_w = 35.0f;
        const float m_w = 35.0f;
        const float joined_w = fx_w + m_w;
        const ImVec2 group_min(win_pos.x + btn_x, win_pos.y + body_y);
        const ImVec2 group_max(group_min.x + joined_w, group_min.y + btn_h);
        draw_list->AddRectFilled(group_min, group_max, ImGui::GetColorU32(ImVec4(0.18f, 0.20f, 0.29f, 0.96f)), 8.0f);
        draw_list->AddLine(
            ImVec2(group_min.x + fx_w, group_min.y + 4.0f),
            ImVec2(group_min.x + fx_w, group_max.y - 4.0f),
            ImGui::GetColorU32(ImVec4(1.0f, 1.0f, 1.0f, 0.10f)),
            1.0f);

        ImGui::SetCursorPos(ImVec2(btn_x, body_y));
        ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 8.0f);
        ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.0f, 0.0f, 0.0f, 0.0f));
        ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(1.0f, 1.0f, 1.0f, 0.03f));
        ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(1.0f, 1.0f, 1.0f, 0.05f));
        if (render_fx_icon_button(bridge, "##fx_toggle", fx_count > 0, ImVec2(fx_w, btn_h), 7.0f))
        {
            const std::string popup_id = std::string("input_fx_popup##") + channel.id;
            ImGui::OpenPopup(popup_id.c_str());
        }
        if (ImGui::IsItemHovered())
        {
            ImGui::SetTooltip("FX chain (%d)", fx_count);
        }
        ImGui::SetCursorPos(ImVec2(btn_x + fx_w, body_y));
        if (render_mute_icon_button(bridge, "##mute_toggle", muted, ImVec2(m_w, btn_h), 7.0f))
        {
            channel.muted = muted ? 0 : 1;
        }
        ImGui::PopStyleColor(3);
        ImGui::PopStyleVar();
        render_input_fx_popup(bridge, snapshot, channel.id);

        const float meter_x = btn_x + joined_w + 18.0f;
        const float meter_y = body_y;
        const float meter_w = win_size.x - meter_x - 18.0f;
        const float label_w = 16.0f;
        const float track_h = 8.0f;
        const float row_gap = 8.0f;
        const float inner_pad_y = 4.0f;
        const float track_x0 = win_pos.x + meter_x + label_w + 10.0f;
        const float track_x1 = win_pos.x + meter_x + meter_w - 8.0f;
        const float track_w = std::max(0.0f, track_x1 - track_x0);
        const float row1_y = win_pos.y + meter_y + inner_pad_y;
        const float row2_y = row1_y + track_h + row_gap;
        WireDeckMeterVisualState &meter_state = meter_visual_state(bridge, channel.id);
        update_meter_visual_state(meter_state, display_meter_left, display_meter_right);
        const auto meter_fill_color = [](float value)
        {
            if (value >= 0.78f)
                return ImVec4(0.88f, 0.80f, 0.18f, 1.0f);
            return ImVec4(0.31f, 0.84f, 0.38f, 1.0f);
        };
        const auto draw_meter_row = [&](float y, const char *label, float value, float peak_value)
        {
            draw_list->AddText(
                ImVec2(win_pos.x + meter_x, y - 2.0f),
                ImGui::GetColorU32(ImVec4(0.72f, 0.74f, 0.82f, 0.75f)),
                label);
            draw_list->AddRectFilled(
                ImVec2(track_x0, y),
                ImVec2(track_x1, y + track_h),
                ImGui::GetColorU32(ImVec4(0.15f, 0.16f, 0.24f, 0.95f)),
                999.0f);
            const float clamped = std::clamp(value, 0.0f, 1.0f);
            draw_list->AddRectFilled(
                ImVec2(track_x0, y),
                ImVec2(track_x0 + track_w * clamped, y + track_h),
                ImGui::GetColorU32(meter_fill_color(clamped)),
                999.0f);
            const float peak = std::clamp(peak_value, 0.0f, 1.0f);
            if (peak > 0.0f)
            {
                const float marker_x = track_x0 + track_w * peak;
                draw_list->AddRectFilled(
                    ImVec2(marker_x - 1.25f, y - 1.5f),
                    ImVec2(marker_x + 1.25f, y + track_h + 1.5f),
                    ImGui::GetColorU32(ImVec4(0.96f, 0.97f, 0.99f, 0.98f)),
                    2.0f);
            }
        };
        draw_meter_row(row1_y, "L", meter_state.current_left, meter_state.peak_left);
        draw_meter_row(row2_y, "R", meter_state.current_right, meter_state.peak_right);

        ImGui::PopStyleVar(3);
        ImGui::EndChild();
        ImGui::PopID();
    }

    void render_add_input_card(WireDeckUiSnapshot *snapshot, float card_width, float card_height)
    {
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(14.0f, 12.0f));
        ImGui::BeginChild(
            "add_input_card",
            ImVec2(card_width, card_height),
            ImGuiChildFlags_Borders,
            ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse);

        ImDrawList *draw_list = ImGui::GetWindowDrawList();
        const ImVec2 win_pos = ImGui::GetWindowPos();
        const ImVec2 win_size = ImGui::GetWindowSize();
        const ImVec2 card_min = win_pos;
        const ImVec2 card_max(win_pos.x + win_size.x, win_pos.y + win_size.y);
        const char *label = "Add source";
        const ImVec2 text_size = ImGui::CalcTextSize(label);
        const float plus_box = 26.0f;
        const float gap = 10.0f;
        const float content_w = plus_box + gap + text_size.x;
        const float start_x = (win_size.x - content_w) * 0.5f;
        const float center_y = win_size.y * 0.5f;

        draw_list->AddRectFilled(card_min, card_max, ImGui::GetColorU32(ImVec4(0.08f, 0.09f, 0.14f, 0.96f)), 18.0f);
        draw_list->AddRect(card_min, card_max, ImGui::GetColorU32(ImVec4(0.60f, 0.66f, 0.86f, 0.10f)), 18.0f);

        ImGui::SetCursorPos(ImVec2(0.0f, 0.0f));
        ImGui::InvisibleButton("add_source_btn", ImVec2(win_size.x, win_size.y));
        const bool hovered = ImGui::IsItemHovered();
        const bool active = ImGui::IsItemActive();
        if (ImGui::IsItemClicked())
        {
            ImGui::OpenPopup("add_source_popup");
        }

        const ImVec2 plus_min(win_pos.x + start_x, win_pos.y + center_y - plus_box * 0.5f);
        const ImVec2 plus_max(plus_min.x + plus_box, plus_min.y + plus_box);
        const float plus_cx = (plus_min.x + plus_max.x) * 0.5f;
        const float plus_cy = (plus_min.y + plus_max.y) * 0.5f;
        ImVec4 plus_bg = ImVec4(0.18f, 0.20f, 0.29f, 0.96f);
        if (hovered)
            plus_bg = ImVec4(0.22f, 0.24f, 0.34f, 1.0f);
        if (active)
            plus_bg = ImVec4(0.25f, 0.28f, 0.38f, 1.0f);
        const ImU32 plus_fg = ImGui::GetColorU32(ImVec4(0.92f, 0.93f, 0.97f, 0.94f));
        const ImU32 text_col = ImGui::GetColorU32(ImVec4(0.92f, 0.93f, 0.97f, 0.95f));

        draw_list->AddRectFilled(plus_min, plus_max, ImGui::GetColorU32(plus_bg), 8.0f);
        draw_list->AddLine(ImVec2(plus_cx - 5.0f, plus_cy), ImVec2(plus_cx + 5.0f, plus_cy), plus_fg, 2.0f);
        draw_list->AddLine(ImVec2(plus_cx, plus_cy - 5.0f), ImVec2(plus_cx, plus_cy + 5.0f), plus_fg, 2.0f);
        draw_list->AddText(
            ImVec2(win_pos.x + start_x + plus_box + gap, win_pos.y + center_y - text_size.y * 0.5f),
            text_col,
            label);

        ImGui::SetNextWindowSizeConstraints(ImVec2(300.0f, 0.0f), ImVec2(420.0f, 420.0f));
        if (ImGui::BeginPopup("add_source_popup"))
        {
            ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(14.0f, 12.0f));
            ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(8.0f, 8.0f));
            ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(8.0f, 6.0f));

            ImDrawList *popup_draw_list = ImGui::GetWindowDrawList();
            const ImVec2 popup_pos = ImGui::GetWindowPos();
            const ImVec2 popup_size = ImGui::GetWindowSize();
            popup_draw_list->AddRectFilled(
                popup_pos,
                ImVec2(popup_pos.x + popup_size.x, popup_pos.y + popup_size.y),
                ImGui::GetColorU32(ImVec4(0.08f, 0.09f, 0.14f, 0.98f)),
                14.0f);
            popup_draw_list->AddRect(
                popup_pos,
                ImVec2(popup_pos.x + popup_size.x, popup_pos.y + popup_size.y),
                ImGui::GetColorU32(ImVec4(0.60f, 0.66f, 0.86f, 0.10f)),
                14.0f);

            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.93f, 0.94f, 0.98f, 0.98f));
            ImGui::TextUnformatted("Add source");
            ImGui::PopStyleColor();

            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.66f, 0.68f, 0.77f, 0.72f));
            ImGui::TextWrapped("Choose which detected device or app should appear in Sources.");
            ImGui::PopStyleColor();

            {
                const float y = ImGui::GetCursorScreenPos().y + 4.0f;
                popup_draw_list->AddLine(
                    ImVec2(popup_pos.x + 12.0f, y),
                    ImVec2(popup_pos.x + popup_size.x - 12.0f, y),
                    ImGui::GetColorU32(ImVec4(1.0f, 1.0f, 1.0f, 0.06f)),
                    1.0f);
            }

            ImGui::Dummy(ImVec2(0.0f, 10.0f));
            bool drew_selectable = false;
            for (int i = 0; i < snapshot->source_count; ++i)
            {
                WireDeckUiSource &source = snapshot->sources[i];
                if (source_is_already_added(snapshot, source.id))
                {
                    continue;
                }
                drew_selectable = true;

                const float item_h = 42.0f;
                const float item_w = ImGui::GetContentRegionAvail().x;
                const ImVec2 item_pos = ImGui::GetCursorScreenPos();
                const ImVec2 item_min(item_pos.x, item_pos.y);
                const ImVec2 item_max(item_pos.x + item_w, item_pos.y + item_h);

                ImGui::SetCursorScreenPos(item_pos);
                ImGui::PushID(source.id);
                ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 0.0f);
                ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.0f, 0.0f, 0.0f, 0.0f));
                ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(1.0f, 1.0f, 1.0f, 0.03f));
                ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(1.0f, 1.0f, 1.0f, 0.05f));
                const bool clicked = ImGui::Button("##source_item", ImVec2(item_w, item_h));
                const bool hovered_item = ImGui::IsItemHovered();
                ImGui::PopStyleColor(3);
                ImGui::PopStyleVar();

                const char *item_label = (source.label != nullptr && source.label[0] != '\0') ? source.label : source.id;
                const char *item_subtitle = (source.subtitle != nullptr && source.subtitle[0] != '\0') ? source.subtitle : "Other";
                popup_draw_list->AddText(
                    ImVec2(item_min.x + 12.0f, item_min.y + 8.0f),
                    ImGui::GetColorU32(hovered_item ? ImVec4(0.97f, 0.98f, 1.0f, 1.0f) : ImVec4(0.93f, 0.94f, 0.98f, 0.96f)),
                    item_label);
                popup_draw_list->AddText(
                    ImVec2(item_min.x + 12.0f, item_min.y + 24.0f),
                    ImGui::GetColorU32(hovered_item ? ImVec4(0.76f, 0.78f, 0.86f, 0.82f) : ImVec4(0.66f, 0.68f, 0.77f, 0.72f)),
                    item_subtitle);
                popup_draw_list->AddText(
                    ImVec2(item_max.x - 16.0f, item_min.y + 12.0f),
                    ImGui::GetColorU32(hovered_item ? ImVec4(0.90f, 0.92f, 0.98f, 0.92f) : ImVec4(0.78f, 0.80f, 0.88f, 0.78f)),
                    ">");

                if (i < snapshot->source_count - 1)
                {
                    popup_draw_list->AddLine(
                        ImVec2(item_min.x, item_max.y),
                        ImVec2(item_max.x, item_max.y),
                        ImGui::GetColorU32(ImVec4(1.0f, 1.0f, 1.0f, 0.08f)),
                        1.0f);
                }

                ImGui::SetCursorScreenPos(ImVec2(item_pos.x, item_pos.y + item_h));
                if (clicked)
                {
                    queue_select_source(snapshot, source.id);
                    ImGui::CloseCurrentPopup();
                }
                ImGui::PopID();
            }
            if (!drew_selectable)
            {
                const float empty_h = 44.0f;
                const float item_w = ImGui::GetContentRegionAvail().x;
                const ImVec2 item_pos = ImGui::GetCursorScreenPos();
                const ImVec2 item_min(item_pos.x, item_pos.y);
                const ImVec2 item_max(item_pos.x + item_w, item_pos.y + empty_h);

                popup_draw_list->AddRectFilled(
                    item_min,
                    item_max,
                    ImGui::GetColorU32(ImVec4(0.12f, 0.13f, 0.19f, 0.92f)),
                    10.0f);
                popup_draw_list->AddText(
                    ImVec2(item_min.x + 12.0f, item_min.y + 13.0f),
                    ImGui::GetColorU32(ImVec4(0.66f, 0.68f, 0.77f, 0.72f)),
                    "All detected sources are already visible.");
                ImGui::Dummy(ImVec2(item_w, empty_h));
            }
            ImGui::PopStyleVar(3);
            ImGui::EndPopup();
        }
        ImGui::PopStyleVar();
        ImGui::EndChild();
    }

    int count_enabled_channels_for_bus(WireDeckUiSnapshot *snapshot, const char *bus_id)
    {
        int enabled_count = 0;
        for (int channel_index = 0; channel_index < snapshot->channel_count; ++channel_index)
        {
            const WireDeckUiChannel &channel = snapshot->channels[channel_index];
            WireDeckUiSend *send = find_send(snapshot, channel.id, bus_id);
            if (send != nullptr && send->enabled != 0)
            {
                enabled_count += 1;
            }
        }
        return enabled_count;
    }

    void render_output_card(WireDeckImGuiBridge *bridge, WireDeckUiSnapshot *snapshot, WireDeckUiBus &bus, int index, float card_width, float card_height)
    {
        (void)index;
        const float meter_left = bus.muted != 0 ? 0.0f : std::clamp(bus.level_left, 0.0f, 1.0f);
        const float meter_right = bus.muted != 0 ? 0.0f : std::clamp(bus.level_right, 0.0f, 1.0f);
        bool expose_as_microphone = bus.expose_as_microphone != 0;
        bool share_on_network = bus.share_on_network != 0;
        ImGui::PushID(bus.id);
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(14.0f, 12.0f));
        ImGui::BeginChild(
            "output_card",
            ImVec2(card_width, card_height),
            ImGuiChildFlags_Borders,
            ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse);
        ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(6.0f, 4.0f));
        ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(6.0f, 4.0f));

        ImDrawList *draw_list = ImGui::GetWindowDrawList();
        const ImVec2 win_pos = ImGui::GetWindowPos();
        const ImVec2 win_size = ImGui::GetWindowSize();
        const ImVec2 card_min = win_pos;
        const ImVec2 card_max(win_pos.x + win_size.x, win_pos.y + win_size.y);
        draw_list->AddRectFilled(card_min, card_max, ImGui::GetColorU32(ImVec4(0.08f, 0.09f, 0.14f, 0.96f)), 18.0f);
        draw_list->AddRect(card_min, card_max, ImGui::GetColorU32(ImVec4(0.60f, 0.66f, 0.86f, 0.10f)), 18.0f);

        const float pad_x = 18.0f;
        const float top_y = 14.0f;
        ImGui::SetCursorPos(ImVec2(pad_x, top_y + 1.0f));
        ImGui::TextUnformatted(bus.label);
        render_rename_popup(bridge, "rename_output_popup", snapshot, bus.id, bus.label, false);

        const float seg_h = 24.0f;
        const float seg_btn_w = 28.0f;
        const float seg_w = seg_btn_w * 3.0f;
        const float seg_x = win_size.x - 18.0f - seg_w;
        const float seg_y = top_y;
        const ImVec2 seg_min(win_pos.x + seg_x, win_pos.y + seg_y);
        const ImVec2 seg_max(seg_min.x + seg_w, seg_min.y + seg_h);
        draw_list->AddRectFilled(seg_min, seg_max, ImGui::GetColorU32(ImVec4(0.18f, 0.20f, 0.29f, 0.96f)), 8.0f);
        draw_list->AddLine(ImVec2(seg_min.x + seg_btn_w, seg_min.y + 4.0f), ImVec2(seg_min.x + seg_btn_w, seg_max.y - 4.0f), ImGui::GetColorU32(ImVec4(1.0f, 1.0f, 1.0f, 0.10f)), 1.0f);
        draw_list->AddLine(ImVec2(seg_min.x + seg_btn_w * 2.0f, seg_min.y + 4.0f), ImVec2(seg_min.x + seg_btn_w * 2.0f, seg_max.y - 4.0f), ImGui::GetColorU32(ImVec4(1.0f, 1.0f, 1.0f, 0.10f)), 1.0f);

        ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 8.0f);
        ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.0f, 0.0f, 0.0f, 0.0f));
        ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(1.0f, 1.0f, 1.0f, 0.03f));
        ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(1.0f, 1.0f, 1.0f, 0.05f));

        ImGui::SetCursorPos(ImVec2(seg_x, seg_y));
        if (render_mic_exposure_button(bridge, "##output_mic_exposure", expose_as_microphone, ImVec2(seg_btn_w, seg_h), 9.0f))
        {
            bus.expose_as_microphone = expose_as_microphone ? 0 : 1;
            bus.dirty_flags |= kUiBusDirtyExposeAsMicrophone;
        }
        if (ImGui::IsItemHovered())
        {
            ImGui::SetTooltip("%s as virtual microphone", expose_as_microphone ? "Stop exposing this output" : "Expose this output");
        }

        ImGui::SetCursorPos(ImVec2(seg_x + seg_btn_w, seg_y));
        if (render_web_exposure_button(bridge, "##output_network_share", share_on_network, ImVec2(seg_btn_w, seg_h), 9.0f))
        {
            bus.share_on_network = share_on_network ? 0 : 1;
            bus.dirty_flags |= kUiBusDirtyShareOnNetwork;
        }
        if (ImGui::IsItemHovered())
        {
            ImGui::SetTooltip("%s to the OBS network plugin", share_on_network ? "Hide this output" : "Share this output");
        }

        ImGui::SetCursorPos(ImVec2(seg_x + seg_btn_w * 2.0f, seg_y));
        if (render_delete_icon_button(bridge, "##output_delete", ImVec2(seg_btn_w, seg_h), 5.5f))
        {
            queue_output_delete(snapshot, bus.id);
        }
        if (ImGui::IsItemHovered())
        {
            ImGui::SetTooltip("Delete output");
        }
        ImGui::PopStyleColor(3);
        ImGui::PopStyleVar();

        const float row2_y = 40.0f;
        ImGui::SetCursorPos(ImVec2(pad_x, row2_y));
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.66f, 0.68f, 0.77f, 0.72f));
        ImGui::TextUnformatted("Physical destination");
        ImGui::PopStyleColor();

        /*const std::string system_capture_label = system_capture_status_label(bus);
        ImGui::SameLine();
        ImGui::PushStyleColor(
            ImGuiCol_Text,
            bus.system_muted != 0 ? ImVec4(0.96f, 0.52f, 0.52f, 0.92f) : ImVec4(0.58f, 0.80f, 0.98f, 0.82f));
        ImGui::TextUnformatted(system_capture_label.c_str());
        ImGui::PopStyleColor();*/

        const float combo_y = 56.0f;
        const float combo_x = pad_x;
        const float combo_w = win_size.x - pad_x * 2.0f;
        const float combo_h = 24.0f;
        const ImVec2 combo_min(win_pos.x + combo_x, win_pos.y + combo_y);
        const ImVec2 combo_max(combo_min.x + combo_w, combo_min.y + combo_h);
        draw_list->AddRectFilled(combo_min, combo_max, ImGui::GetColorU32(ImVec4(0.12f, 0.14f, 0.20f, 0.96f)), 8.0f);
        draw_list->AddRect(combo_min, combo_max, ImGui::GetColorU32(ImVec4(1.0f, 1.0f, 1.0f, 0.05f)), 8.0f);
        draw_list->AddRectFilled(ImVec2(combo_max.x - 24.0f, combo_min.y), combo_max, ImGui::GetColorU32(ImVec4(0.22f, 0.35f, 0.55f, 0.85f)), 8.0f);

        const std::string preview = output_destination_preview(snapshot, bus.id);
        ImGui::SetCursorPos(ImVec2(combo_x + 10.0f, combo_y + 3.0f));
        ImGui::TextUnformatted(preview.c_str());
        ImGui::SetCursorPos(ImVec2(combo_x, combo_y));
        ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.0f, 0.0f, 0.0f, 0.0f));
        ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.0f, 0.0f, 0.0f, 0.0f));
        ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(0.0f, 0.0f, 0.0f, 0.0f));
        if (ImGui::Button("##destinations", ImVec2(combo_w, combo_h)))
        {
            ImGui::OpenPopup("destinations_popup");
        }
        ImGui::PopStyleColor(3);

        ImGui::SetNextWindowSizeConstraints(ImVec2(300.0f, 0.0f), ImVec2(420.0f, 420.0f));
        if (ImGui::BeginPopup("destinations_popup"))
        {
            ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(14.0f, 12.0f));
            ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(8.0f, 8.0f));
            ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(8.0f, 6.0f));

            ImDrawList *popup_draw_list = ImGui::GetWindowDrawList();
            const ImVec2 popup_pos = ImGui::GetWindowPos();
            const ImVec2 popup_size = ImGui::GetWindowSize();

            popup_draw_list->AddRectFilled(
                popup_pos,
                ImVec2(popup_pos.x + popup_size.x, popup_pos.y + popup_size.y),
                ImGui::GetColorU32(ImVec4(0.08f, 0.09f, 0.14f, 0.98f)),
                14.0f);
            popup_draw_list->AddRect(
                popup_pos,
                ImVec2(popup_pos.x + popup_size.x, popup_pos.y + popup_size.y),
                ImGui::GetColorU32(ImVec4(0.60f, 0.66f, 0.86f, 0.10f)),
                14.0f);

            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.93f, 0.94f, 0.98f, 0.98f));
            ImGui::TextUnformatted("Physical destination");
            ImGui::PopStyleColor();

            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.66f, 0.68f, 0.77f, 0.72f));
            ImGui::TextWrapped("Choose where this output should be heard.");
            ImGui::PopStyleColor();

            {
                const float y = ImGui::GetCursorScreenPos().y + 4.0f;
                popup_draw_list->AddLine(
                    ImVec2(popup_pos.x + 12.0f, y),
                    ImVec2(popup_pos.x + popup_size.x - 12.0f, y),
                    ImGui::GetColorU32(ImVec4(1.0f, 1.0f, 1.0f, 0.06f)),
                    1.0f);
            }

            ImGui::Dummy(ImVec2(0.0f, 10.0f));

            std::string current_group;
            bool drew_any = false;
            for (int i = 0; i < snapshot->destination_count; ++i)
            {
                WireDeckUiDestination &destination = snapshot->destinations[i];
                WireDeckUiBusDestination *bus_destination = find_bus_destination(snapshot, bus.id, destination.id);
                if (bus_destination == nullptr)
                    continue;
                drew_any = true;

                const char *subtitle = (destination.subtitle != nullptr && destination.subtitle[0] != 0) ? destination.subtitle : "Other";
                if (current_group != subtitle)
                {
                    if (!current_group.empty())
                    {
                        ImGui::Dummy(ImVec2(0.0f, 6.0f));
                    }
                    current_group = subtitle;
                    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.66f, 0.68f, 0.77f, 0.72f));
                    ImGui::TextUnformatted(subtitle);
                    ImGui::PopStyleColor();
                }

                const float item_h = 42.0f;
                const float item_w = ImGui::GetContentRegionAvail().x;
                const ImVec2 item_pos = ImGui::GetCursorScreenPos();
                const ImVec2 item_min(item_pos.x, item_pos.y);
                const ImVec2 item_max(item_pos.x + item_w, item_pos.y + item_h);

                ImGui::SetCursorScreenPos(item_pos);
                ImGui::PushID(destination.id);
                ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 0.0f);
                ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.0f, 0.0f, 0.0f, 0.0f));
                ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(1.0f, 1.0f, 1.0f, 0.03f));
                ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(1.0f, 1.0f, 1.0f, 0.05f));
                const bool clicked = ImGui::Button("##destination_item", ImVec2(item_w, item_h));
                const bool hovered_item = ImGui::IsItemHovered();
                ImGui::PopStyleColor(3);
                ImGui::PopStyleVar();

                const bool enabled = bus_destination->enabled != 0;
                const std::string status_text = enabled
                                                    ? ((destination.muted != 0)
                                                           ? "Enabled | Muted"
                                                           : ("Enabled | " + std::to_string(static_cast<int>(std::round(std::clamp(destination.volume, 0.0f, 4.0f) * 100.0f))) + "%"))
                                                    : "Disabled";
                if (enabled)
                {
                    popup_draw_list->AddRectFilled(
                        ImVec2(item_min.x + 6.0f, item_min.y + 8.0f),
                        ImVec2(item_min.x + 10.0f, item_max.y - 8.0f),
                        ImGui::GetColorU32(ImVec4(0.36f, 0.86f, 0.42f, 1.0f)),
                        999.0f);
                }

                const char *item_label = (destination.label != nullptr && destination.label[0] != '\0') ? destination.label : destination.id;
                popup_draw_list->AddText(
                    ImVec2(item_min.x + 18.0f, item_min.y + 8.0f),
                    ImGui::GetColorU32(hovered_item ? ImVec4(0.97f, 0.98f, 1.0f, 1.0f) : ImVec4(0.93f, 0.94f, 0.98f, 0.96f)),
                    item_label);
                popup_draw_list->AddText(
                    ImVec2(item_min.x + 18.0f, item_min.y + 24.0f),
                    ImGui::GetColorU32(hovered_item ? ImVec4(0.76f, 0.78f, 0.86f, 0.82f) : ImVec4(0.66f, 0.68f, 0.77f, 0.72f)),
                    status_text.c_str());
                if (i < snapshot->destination_count - 1)
                {
                    popup_draw_list->AddLine(
                        ImVec2(item_min.x, item_max.y),
                        ImVec2(item_max.x, item_max.y),
                        ImGui::GetColorU32(ImVec4(1.0f, 1.0f, 1.0f, 0.08f)),
                        1.0f);
                }

                ImGui::SetCursorScreenPos(ImVec2(item_pos.x, item_pos.y + item_h));
                if (clicked)
                {
                    bus_destination->enabled = enabled ? 0 : 1;
                }
                ImGui::PopID();
            }

            if (!drew_any)
            {
                const float empty_h = 44.0f;
                const float item_w = ImGui::GetContentRegionAvail().x;
                const ImVec2 item_pos = ImGui::GetCursorScreenPos();
                const ImVec2 item_min(item_pos.x, item_pos.y);
                const ImVec2 item_max(item_pos.x + item_w, item_pos.y + empty_h);
                popup_draw_list->AddRectFilled(
                    item_min,
                    item_max,
                    ImGui::GetColorU32(ImVec4(0.12f, 0.13f, 0.19f, 0.92f)),
                    10.0f);
                popup_draw_list->AddText(
                    ImVec2(item_min.x + 12.0f, item_min.y + 13.0f),
                    ImGui::GetColorU32(ImVec4(0.66f, 0.68f, 0.77f, 0.72f)),
                    "No destinations available.");
                ImGui::Dummy(ImVec2(item_w, empty_h));
            }

            ImGui::PopStyleVar(3);
            ImGui::EndPopup();
        }

        const float sep_y = 84.0f;
        draw_list->AddLine(ImVec2(win_pos.x + 16.0f, win_pos.y + sep_y), ImVec2(win_pos.x + win_size.x - 16.0f, win_pos.y + sep_y), ImGui::GetColorU32(ImVec4(1.0f, 1.0f, 1.0f, 0.06f)), 1.0f);

        const float meter_x = pad_x;
        const float meter_y = 91.0f;
        const float meter_w = win_size.x - pad_x * 2.0f;
        const float label_w = 12.0f;
        const float gap = 6.0f;
        const float track_h = 5.0f;
        const float row_gap = 6.0f;
        const float track_x0 = win_pos.x + meter_x + label_w + gap;
        const float track_x1 = win_pos.x + meter_x + meter_w;
        const float track_w = std::max(0.0f, track_x1 - track_x0);
        const auto draw_meter_row = [&](float y, const char *label, float value)
        {
            draw_list->AddText(ImVec2(win_pos.x + meter_x, y - 6.0f), ImGui::GetColorU32(ImVec4(0.72f, 0.74f, 0.82f, 0.72f)), label);
            draw_list->AddRectFilled(ImVec2(track_x0, y), ImVec2(track_x1, y + track_h), ImGui::GetColorU32(ImVec4(0.15f, 0.16f, 0.24f, 0.95f)), 999.0f);
            const float clamped = std::clamp(value, 0.0f, 1.0f);
            draw_list->AddRectFilled(ImVec2(track_x0, y), ImVec2(track_x0 + track_w * clamped, y + track_h), ImGui::GetColorU32(meter_color(clamped)), 999.0f);
        };
        draw_meter_row(win_pos.y + meter_y, "L", meter_left);
        draw_meter_row(win_pos.y + meter_y + track_h + row_gap, "R", meter_right);

        ImGui::PopStyleVar(3);
        ImGui::EndChild();
        ImGui::PopID();
    }

    void render_mixer_bus_card(WireDeckImGuiBridge *bridge, WireDeckUiSnapshot *snapshot, WireDeckUiBus &bus, int index, float card_width, float card_height)
    {
        const float left_level = bus.muted != 0 ? 0.0f : std::clamp(bus.level_left, 0.0f, 1.0f);
        const float right_level = bus.muted != 0 ? 0.0f : std::clamp(bus.level_right, 0.0f, 1.0f);
        const int assigned_inputs = count_enabled_channels_for_bus(snapshot, bus.id);
        const int selected_destinations = count_selected_destinations(snapshot, bus.id);

        ImGui::PushID(bus.id);
        ImGui::BeginChild(
            "mixer_bus_card",
            ImVec2(card_width, card_height),
            ImGuiChildFlags_Borders,
            ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse);
        ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(6.0f, 4.0f));
        ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(6.0f, 4.0f));

        ImGui::TextUnformatted(bus.label);
        render_rename_popup(bridge, "rename_mixer_bus_popup", snapshot, bus.id, bus.label, false);
        ImGui::TextDisabled(assigned_inputs == 1 ? "1 source feeding this bus" : "%d sources feeding this bus", assigned_inputs);
        ImGui::TextDisabled(selected_destinations == 1 ? "1 playback destination" : "%d playback destinations", selected_destinations);

        bool muted = bus.muted != 0;
        {
            const float action_width = 58.0f;
            const float action_x = ImGui::GetCursorPosX() + ImGui::GetContentRegionAvail().x - action_width;
            if (action_x > ImGui::GetCursorPosX())
            {
                ImGui::SetCursorPosX(action_x);
            }
        }
        if (render_mute_icon_button(bridge, "##mixer_bus_mute_toggle", muted, ImVec2(30.0f, 30.0f), 2.0f))
        {
            bus.muted = muted ? 0 : 1;
            bus.dirty_flags |= kUiBusDirtyMuted;
        }

        ImGui::Dummy(ImVec2(0.0f, 10.0f));
        ImGui::TextDisabled("Bus gain");
        float bus_percent = bus.volume * 100.0f;
        if (render_stereo_meter_with_volume("mixer_meter_volume_overlay", "##mixer_bus_volume", left_level, right_level, &bus_percent))
        {
            bus.volume = bus_percent / 100.0f;
            bus.dirty_flags |= kUiBusDirtyVolume;
        }

        ImGui::Dummy(ImVec2(0.0f, 6.0f));
        ImGui::TextDisabled("Destination summary");
        const std::string preview = output_destination_preview(snapshot, bus.id);
        ImGui::TextUnformatted(preview.c_str());

        ImGui::Dummy(ImVec2(0.0f, 6.0f));
        ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.64f, 0.16f, 0.16f, 1.0f));
        ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.78f, 0.20f, 0.20f, 1.0f));
        ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(0.52f, 0.12f, 0.12f, 1.0f));
        if (ImGui::Button("Delete", ImVec2(-1.0f, 0.0f)))
        {
            queue_output_delete(snapshot, bus.id);
        }
        ImGui::PopStyleColor(3);

        ImGui::PopStyleVar(2);
        ImGui::EndChild();
        ImGui::PopID();
    }

    void render_add_output_card(WireDeckUiSnapshot *snapshot, float card_width, float card_height)
    {
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(14.0f, 12.0f));
        ImGui::BeginChild(
            "add_output_card",
            ImVec2(card_width, card_height),
            ImGuiChildFlags_Borders,
            ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse);

        ImDrawList *draw_list = ImGui::GetWindowDrawList();
        const ImVec2 win_pos = ImGui::GetWindowPos();
        const ImVec2 win_size = ImGui::GetWindowSize();
        const ImVec2 card_min = win_pos;
        const ImVec2 card_max(win_pos.x + win_size.x, win_pos.y + win_size.y);
        const char *label = "Add output";
        const ImVec2 text_size = ImGui::CalcTextSize(label);
        const float plus_box = 26.0f;
        const float gap = 10.0f;
        const float content_w = plus_box + gap + text_size.x;
        const float start_x = (win_size.x - content_w) * 0.5f;
        const float center_y = win_size.y * 0.5f;

        draw_list->AddRectFilled(card_min, card_max, ImGui::GetColorU32(ImVec4(0.08f, 0.09f, 0.14f, 0.96f)), 18.0f);
        draw_list->AddRect(card_min, card_max, ImGui::GetColorU32(ImVec4(0.60f, 0.66f, 0.86f, 0.10f)), 18.0f);

        ImGui::SetCursorPos(ImVec2(0.0f, 0.0f));
        ImGui::InvisibleButton("add_output_btn", ImVec2(win_size.x, win_size.y));
        const bool hovered = ImGui::IsItemHovered();
        const bool active = ImGui::IsItemActive();
        if (ImGui::IsItemClicked())
        {
            snapshot->request_add_output = 1;
        }

        const ImVec2 plus_min(win_pos.x + start_x, win_pos.y + center_y - plus_box * 0.5f);
        const ImVec2 plus_max(plus_min.x + plus_box, plus_min.y + plus_box);
        const float plus_cx = (plus_min.x + plus_max.x) * 0.5f;
        const float plus_cy = (plus_min.y + plus_max.y) * 0.5f;
        ImVec4 plus_bg = ImVec4(0.18f, 0.20f, 0.29f, 0.96f);
        if (hovered)
            plus_bg = ImVec4(0.22f, 0.24f, 0.34f, 1.0f);
        if (active)
            plus_bg = ImVec4(0.25f, 0.28f, 0.38f, 1.0f);
        const ImU32 plus_fg = ImGui::GetColorU32(ImVec4(0.92f, 0.93f, 0.97f, 0.94f));
        const ImU32 text_col = ImGui::GetColorU32(ImVec4(0.92f, 0.93f, 0.97f, 0.95f));

        draw_list->AddRectFilled(plus_min, plus_max, ImGui::GetColorU32(plus_bg), 8.0f);
        draw_list->AddLine(ImVec2(plus_cx - 5.0f, plus_cy), ImVec2(plus_cx + 5.0f, plus_cy), plus_fg, 2.0f);
        draw_list->AddLine(ImVec2(plus_cx, plus_cy - 5.0f), ImVec2(plus_cx, plus_cy + 5.0f), plus_fg, 2.0f);
        draw_list->AddText(ImVec2(win_pos.x + start_x + plus_box + gap, win_pos.y + center_y - text_size.y * 0.5f), text_col, label);

        ImGui::PopStyleVar();
        ImGui::EndChild();
    }

    void render_ui(WireDeckImGuiBridge *bridge, WireDeckUiSnapshot *snapshot)
    {
        float aggregate = 0.0f;
        for (int i = 0; i < snapshot->channel_count; ++i)
        {
            aggregate += input_card_activity(snapshot, snapshot->channels[i], bridge->frame_index, static_cast<float>(i));
        }
        if (snapshot->channel_count > 0)
        {
            aggregate /= static_cast<float>(snapshot->channel_count);
        }
        std::rotate(bridge->activity_history.begin(), bridge->activity_history.begin() + 1, bridge->activity_history.end());
        bridge->activity_history.back() = aggregate;

        const ImGuiViewport *viewport = ImGui::GetMainViewport();
        ImGui::SetNextWindowPos(viewport->WorkPos, ImGuiCond_Always);
        ImGui::SetNextWindowSize(viewport->WorkSize, ImGuiCond_Always);
        ImGui::SetNextWindowViewport(viewport->ID);
        ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 0.0f);
        ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0.0f);
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(18.0f, 18.0f));
        ImGui::Begin(
            "WireDeck Mixer",
            nullptr,
            ImGuiWindowFlags_NoCollapse |
                ImGuiWindowFlags_NoSavedSettings |
                ImGuiWindowFlags_NoTitleBar |
                ImGuiWindowFlags_NoScrollbar |
                ImGuiWindowFlags_NoScrollWithMouse |
                ImGuiWindowFlags_NoResize |
                ImGuiWindowFlags_NoMove);
        ImGui::PopStyleVar(3);

        const float full_height = ImGui::GetContentRegionAvail().y;
        const float left_width = 316.0f;
        const float right_width = 308.0f;
        const float source_card_width = 300.0f;
        const float source_card_height = 110.0f;
        const float output_card_height = 120.0f;

        if (ImGui::BeginTable("wiredeck_main_columns", 3, ImGuiTableFlags_SizingFixedFit | ImGuiTableFlags_BordersInnerV | ImGuiTableFlags_NoPadOuterX))
        {
            ImGui::TableSetupColumn("Sources", ImGuiTableColumnFlags_WidthFixed, left_width);
            ImGui::TableSetupColumn("Mixer", ImGuiTableColumnFlags_WidthStretch, 0.0f);
            ImGui::TableSetupColumn("Outputs", ImGuiTableColumnFlags_WidthFixed, right_width);

            ImGui::TableNextColumn();
            // ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.97f, 0.82f, 0.32f, 1.0f));
            // ImGui::TextUnformatted("Sources");
            // ImGui::PopStyleColor();
            // ImGui::TextDisabled("Capture strips you care about, kept visible and adjustable.");
            // ImGui::Dummy(ImVec2(0.0f, 10.0f));
            ImGui::PushStyleColor(ImGuiCol_ChildBg, ImVec4(0.0f, 0.0f, 0.0f, 0.0f));
            ImGui::BeginChild("sources_column", ImVec2(0.0f, full_height - 10.0f), ImGuiChildFlags_None, ImGuiWindowFlags_None);
            for (int i = 0; i < snapshot->channel_count; ++i)
            {
                const float available_card_width = std::max(220.0f, ImGui::GetContentRegionAvail().x);
                render_input_card(bridge, snapshot, snapshot->channels[i], i, available_card_width, source_card_height);
            }
            const float available_card_width = std::max(220.0f, ImGui::GetContentRegionAvail().x);
            render_add_input_card(snapshot, available_card_width, 40.0f);
            ImGui::EndChild();
            ImGui::PopStyleColor();

            ImGui::TableNextColumn();
            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.97f, 0.82f, 0.32f, 1.0f));
            // ImGui::TextUnformatted("Mixer");
            ImGui::PopStyleColor();
            // ImGui::TextDisabled("Shape each bus first, then patch it to your playback targets.");
            // ImGui::Dummy(ImVec2(0.0f, 10.0f));
            ImGui::PushStyleColor(ImGuiCol_ChildBg, ImVec4(0.0f, 0.0f, 0.0f, 0.0f));
            ImGui::BeginChild("mixer_column", ImVec2(0.0f, full_height - 10.0f), ImGuiChildFlags_None, ImGuiWindowFlags_None);
            ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(14.0f, 12.0f));
            ImGui::PushStyleColor(ImGuiCol_ChildBg, ImVec4(0.0f, 0.0f, 0.0f, 0.0f));
            ImGui::BeginChild("routing_matrix_placeholder", ImVec2(0.0f, 0.0f), ImGuiChildFlags_Borders, ImGuiWindowFlags_None);
            {
                ImDrawList *matrix_draw_list = ImGui::GetWindowDrawList();
                const ImVec2 matrix_pos = ImGui::GetWindowPos();
                const ImVec2 matrix_size = ImGui::GetWindowSize();
                matrix_draw_list->AddRectFilled(
                    matrix_pos,
                    ImVec2(matrix_pos.x + matrix_size.x, matrix_pos.y + matrix_size.y),
                    ImGui::GetColorU32(ImVec4(0.08f, 0.09f, 0.14f, 0.96f)),
                    18.0f);
                matrix_draw_list->AddRect(
                    matrix_pos,
                    ImVec2(matrix_pos.x + matrix_size.x, matrix_pos.y + matrix_size.y),
                    ImGui::GetColorU32(ImVec4(0.60f, 0.66f, 0.86f, 0.10f)),
                    18.0f,
                    0,
                    1.0f);
            }
            ImGui::TextDisabled("Routing matrix");
            ImGui::Dummy(ImVec2(0.0f, 6.0f));
            ImGui::PushStyleVar(ImGuiStyleVar_CellPadding, ImVec2(12.0f, 6.0f));
            if (ImGui::BeginTable("routing_matrix", snapshot->bus_count + 1, ImGuiTableFlags_Borders | ImGuiTableFlags_RowBg | ImGuiTableFlags_SizingStretchProp))
            {
                ImGui::TableSetupColumn("Source", ImGuiTableColumnFlags_WidthStretch, 1.2f);
                for (int i = 0; i < snapshot->bus_count; ++i)
                {
                    ImGui::TableSetupColumn(snapshot->buses[i].label, ImGuiTableColumnFlags_WidthStretch, 1.0f);
                }
                ImGui::TableHeadersRow();
                for (int channel_index = 0; channel_index < snapshot->channel_count; ++channel_index)
                {
                    WireDeckUiChannel &channel = snapshot->channels[channel_index];
                    ImGui::TableNextRow();
                    ImGui::TableSetColumnIndex(0);
                    ImGui::TextUnformatted(channel.label);
                    if (channel.subtitle != nullptr && channel.subtitle[0] != '\0')
                    {
                        ImGui::TextDisabled("%s", channel.subtitle);
                    }
                    for (int bus_index = 0; bus_index < snapshot->bus_count; ++bus_index)
                    {
                        ImGui::TableSetColumnIndex(bus_index + 1);
                        WireDeckUiSend *send = find_send(snapshot, channel.id, snapshot->buses[bus_index].id);
                        bool enabled = send != nullptr && send->enabled != 0;
                        const std::string button_id = std::string(enabled ? "On##matrix_" : "Off##matrix_") + channel.id + "_" + snapshot->buses[bus_index].id;
                        ImGui::PushStyleColor(ImGuiCol_Button, enabled ? ImVec4(0.78f, 0.54f, 0.16f, 1.0f) : ImVec4(0.15f, 0.18f, 0.22f, 1.0f));
                        ImGui::PushStyleColor(ImGuiCol_ButtonHovered, enabled ? ImVec4(0.90f, 0.63f, 0.21f, 1.0f) : ImVec4(0.20f, 0.23f, 0.28f, 1.0f));
                        ImGui::PushStyleColor(ImGuiCol_ButtonActive, enabled ? ImVec4(0.94f, 0.70f, 0.24f, 1.0f) : ImVec4(0.24f, 0.28f, 0.33f, 1.0f));
                        if (ImGui::Button(button_id.c_str(), ImVec2(-FLT_MIN, 28.0f)) && send != nullptr)
                        {
                            send->enabled = enabled ? 0 : 1;
                        }
                        if (ImGui::IsItemHovered())
                        {
                            ImGui::SetTooltip("%s -> %s", channel.label, snapshot->buses[bus_index].label);
                        }
                        ImGui::PopStyleColor(3);
                    }
                }
                ImGui::EndTable();
            }
            ImGui::PopStyleVar();
            ImGui::EndChild();
            ImGui::PopStyleColor();
            ImGui::PopStyleVar();
            ImGui::EndChild();
            ImGui::PopStyleColor();

            ImGui::TableNextColumn();
            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.97f, 0.82f, 0.32f, 1.0f));
            // ImGui::TextUnformatted("Outputs");
            ImGui::PopStyleColor();
            // ImGui::TextDisabled("Choose where each bus should be heard in the real world.");
            // ImGui::Dummy(ImVec2(0.0f, 10.0f));
            ImGui::PushStyleColor(ImGuiCol_ChildBg, ImVec4(0.0f, 0.0f, 0.0f, 0.0f));
            ImGui::BeginChild("outputs_column", ImVec2(0.0f, full_height - 10.0f), ImGuiChildFlags_None, ImGuiWindowFlags_None);
            for (int i = 0; i < snapshot->bus_count; ++i)
            {
                const float available_output_card_width = std::max(220.0f, ImGui::GetContentRegionAvail().x);
                render_output_card(bridge, snapshot, snapshot->buses[i], i, available_output_card_width, output_card_height);
            }
            const float available_output_card_width = std::max(220.0f, ImGui::GetContentRegionAvail().x);
            render_add_output_card(snapshot, available_output_card_width, 40.0f);
            ImGui::EndChild();
            ImGui::PopStyleColor();

            ImGui::EndTable();
        }

        ImGui::End();
    }

} // namespace

extern "C" WireDeckImGuiBridge *wiredeck_imgui_create(SDL_Window *window)
{
    if (window == nullptr)
    {
        set_error("wiredeck_imgui_create received a null SDL window");
        return nullptr;
    }

    auto *bridge = new WireDeckImGuiBridge();
    bridge->window = window;
    bridge->activity_history.fill(0.0f);

    const auto icon_path = find_wiredeck_icon_path();
    if (!icon_path.empty())
    {
        if (SDL_Surface *window_icon = load_png_surface(icon_path.c_str()))
        {
            SDL_SetWindowIcon(window, window_icon);
            SDL_DestroySurface(window_icon);
        }
    }

    if (!setup_vulkan(bridge) || !setup_window(bridge))
    {
        cleanup_vulkan(bridge);
        delete bridge;
        return nullptr;
    }

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    io.ConfigFlags |= ImGuiConfigFlags_DockingEnable;
    io.ConfigDpiScaleFonts = true;
    io.IniFilename = nullptr;

    push_wiredeck_style();
    ImGuiStyle &style = ImGui::GetStyle();
    if (!ImGui_ImplSDL3_InitForVulkan(window))
    {
        set_error("ImGui_ImplSDL3_InitForVulkan failed");
        ImGui::DestroyContext();
        cleanup_vulkan(bridge);
        delete bridge;
        return nullptr;
    }

    ImGui_ImplVulkan_InitInfo init_info{};
    init_info.ApiVersion = VK_API_VERSION_1_0;
    init_info.Instance = bridge->instance;
    init_info.PhysicalDevice = bridge->physical_device;
    init_info.Device = bridge->device;
    init_info.QueueFamily = bridge->queue_family;
    init_info.Queue = bridge->queue;
    init_info.PipelineCache = bridge->pipeline_cache;
    init_info.DescriptorPool = bridge->descriptor_pool;
    init_info.MinImageCount = bridge->min_image_count;
    init_info.ImageCount = bridge->main_window_data.ImageCount;
    init_info.Allocator = bridge->allocator;
    init_info.PipelineInfoMain.RenderPass = bridge->main_window_data.RenderPass;
    init_info.PipelineInfoMain.Subpass = 0;
    init_info.PipelineInfoMain.MSAASamples = VK_SAMPLE_COUNT_1_BIT;
    init_info.CheckVkResultFn = nullptr;
    if (!ImGui_ImplVulkan_Init(&init_info))
    {
        set_error("ImGui_ImplVulkan_Init failed");
        ImGui_ImplSDL3_Shutdown();
        ImGui::DestroyContext();
        cleanup_vulkan(bridge);
        delete bridge;
        return nullptr;
    }

    if (!load_icon_textures(bridge))
    {
        g_last_error += " (falling back to built-in mute icon)";
    }

    if (!setup_tray(bridge))
    {
        if (g_last_error.empty())
        {
            g_last_error = "tray unavailable";
        }
        else
        {
            g_last_error += " (tray unavailable)";
        }
    }

    return bridge;
}

extern "C" int wiredeck_imgui_render_frame(WireDeckImGuiBridge *bridge, WireDeckUiSnapshot *snapshot)
{
    if (bridge == nullptr || snapshot == nullptr)
    {
        set_error("wiredeck_imgui_render_frame received invalid arguments");
        return -1;
    }

    int fb_width = 0;
    int fb_height = 0;
    SDL_GetWindowSize(bridge->window, &fb_width, &fb_height);
    if (fb_width > 0 && fb_height > 0 && (bridge->swapchain_rebuild || bridge->main_window_data.Width != fb_width || bridge->main_window_data.Height != fb_height))
    {
        ImGui_ImplVulkan_SetMinImageCount(bridge->min_image_count);
        ImGui_ImplVulkanH_CreateOrResizeWindow(
            bridge->instance,
            bridge->physical_device,
            bridge->device,
            &bridge->main_window_data,
            bridge->queue_family,
            bridge->allocator,
            fb_width,
            fb_height,
            bridge->min_image_count,
            0);
        bridge->main_window_data.FrameIndex = 0;
        bridge->swapchain_rebuild = false;
    }

    ImGui_ImplVulkan_NewFrame();
    ImGui_ImplSDL3_NewFrame();
    ImGui::NewFrame();

    render_ui(bridge, snapshot);

    ImGui::Render();
    ImDrawData *draw_data = ImGui::GetDrawData();
    const bool minimized = draw_data->DisplaySize.x <= 0.0f || draw_data->DisplaySize.y <= 0.0f;
    bridge->main_window_data.ClearValue.color.float32[0] = 0.05f;
    bridge->main_window_data.ClearValue.color.float32[1] = 0.06f;
    bridge->main_window_data.ClearValue.color.float32[2] = 0.08f;
    bridge->main_window_data.ClearValue.color.float32[3] = 1.0f;

    if (!minimized)
    {
        frame_render(bridge, draw_data);
    }

    if (!minimized)
    {
        frame_present(bridge);
    }

    bridge->frame_index += 1;
    return 1;
}

extern "C" int wiredeck_imgui_pump_events(WireDeckImGuiBridge *bridge)
{
    if (bridge == nullptr)
    {
        set_error("wiredeck_imgui_pump_events received invalid arguments");
        return -1;
    }

    SDL_Event event;
    while (SDL_PollEvent(&event))
    {
        ImGui_ImplSDL3_ProcessEvent(&event);
        if (event.type == SDL_EVENT_QUIT)
        {
            return 0;
        }
        if (event.type == SDL_EVENT_WINDOW_CLOSE_REQUESTED && event.window.windowID == SDL_GetWindowID(bridge->window))
        {
            if (bridge->tray != nullptr)
            {
                set_window_visible(bridge, false);
                continue;
            }
            return 0;
        }
    }

    if (bridge->pending_quit)
    {
        return 0;
    }

    if (is_window_hidden(bridge->window) || (SDL_GetWindowFlags(bridge->window) & SDL_WINDOW_MINIMIZED) != 0)
    {
        return 1;
    }

    return 2;
}

extern "C" void wiredeck_imgui_set_tray_autostart_enabled(WireDeckImGuiBridge *bridge, int enabled)
{
    if (bridge == nullptr)
    {
        return;
    }

    bridge->tray_autostart_enabled = enabled != 0;
    if (bridge->tray_autostart_entry != nullptr)
    {
        SDL_SetTrayEntryChecked(bridge->tray_autostart_entry, bridge->tray_autostart_enabled);
    }
}

extern "C" int wiredeck_imgui_take_tray_autostart_request(WireDeckImGuiBridge *bridge, int *enabled)
{
    if (bridge == nullptr || enabled == nullptr || !bridge->pending_autostart_change)
    {
        return 0;
    }

    *enabled = bridge->tray_autostart_enabled ? 1 : 0;
    bridge->pending_autostart_change = false;
    return 1;
}

extern "C" int wiredeck_imgui_convert_icon_path(const char *source_path, char *out_path, size_t out_path_len)
{
    if (source_path == nullptr || source_path[0] == '\0' || out_path == nullptr || out_path_len == 0)
    {
        set_error("invalid icon conversion arguments");
        return 0;
    }

    std::string renderable_path{};
    if (!resolve_renderable_icon_path(source_path, &renderable_path))
    {
        if (g_last_error.empty())
        {
            set_error(std::string("could not convert icon path: ") + source_path);
        }
        return 0;
    }

    std::snprintf(out_path, out_path_len, "%s", renderable_path.c_str());
    return 1;
}

extern "C" void wiredeck_imgui_destroy(WireDeckImGuiBridge *bridge)
{
    if (bridge == nullptr)
    {
        return;
    }

    if (bridge->device != VK_NULL_HANDLE)
    {
        vkDeviceWaitIdle(bridge->device);
        destroy_icon_texture(bridge, &bridge->volume_icon);
        destroy_icon_texture(bridge, &bridge->volume_off_icon);
        destroy_icon_texture(bridge, &bridge->fx_icon);
        destroy_icon_texture(bridge, &bridge->mic_icon);
        destroy_icon_texture(bridge, &bridge->mic_off_icon);
        destroy_icon_texture(bridge, &bridge->world_icon);
        destroy_icon_texture(bridge, &bridge->world_off_icon);
        destroy_icon_texture(bridge, &bridge->trash_icon);
        destroy_icon_texture(bridge, &bridge->toggle_left_icon);
        destroy_icon_texture(bridge, &bridge->toggle_right_icon);
        destroy_icon_texture(bridge, &bridge->config_icon);
        destroy_icon_texture(bridge, &bridge->headset_icon);
        destroy_icon_texture(bridge, &bridge->generic_app_icon);
        for (auto &icon : bridge->source_icons)
        {
            destroy_icon_texture(bridge, &icon.texture);
        }
        bridge->source_icons.clear();
    }
    ImGui_ImplVulkan_Shutdown();
    ImGui_ImplSDL3_Shutdown();
    ImGui::DestroyContext();
    if (bridge->tray != nullptr)
    {
        SDL_DestroyTray(bridge->tray);
    }
    if (bridge->tray_icon_surface != nullptr)
    {
        SDL_DestroySurface(bridge->tray_icon_surface);
    }
    cleanup_vulkan(bridge);
    delete bridge;
}

extern "C" const char *wiredeck_imgui_last_error(void)
{
    return g_last_error.empty() ? nullptr : g_last_error.c_str();
}
