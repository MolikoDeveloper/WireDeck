pub const c = @cImport({
    @cInclude("pipewire/pipewire.h");
    @cInclude("pipewire/extensions/profiler.h");
    @cInclude("pipewire/extensions/metadata.h");

    @cInclude("spa/utils/dict.h");
    @cInclude("spa/utils/result.h");
    @cInclude("spa/param/audio/raw.h");
    @cInclude("spa/param/audio/format-utils.h");
    @cInclude("spa/pod/parser.h");
    @cInclude("spa/pod/builder.h");
    @cInclude("spa/buffer/buffer.h");
});
