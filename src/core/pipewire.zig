pub const c = @import("pipewire/c.zig").c;

pub const types = @import("pipewire/types.zig");
pub const PipewireContext = @import("pipewire/context.zig").PipewireContext;
pub const RegistryState = @import("pipewire/registry.zig").RegistryState;
pub const RegistrySnapshot = @import("pipewire/registry.zig").RegistrySnapshot;
pub const PipeWireLiveProfiler = @import("pipewire/live_profiler.zig").PipeWireLiveProfiler;
pub const VirtualInputManager = @import("pipewire/virtual_inputs.zig").VirtualInputManager;
pub const InputLoopbackManager = @import("pipewire/input_loopbacks.zig").InputLoopbackManager;
pub const ChannelFxFilterManager = @import("pipewire/channel_fx_filters.zig").ChannelFxFilterManager;

pub const GlobalObject = types.GlobalObject;
pub const PwProps = types.PwProps;
pub const ResolvedSource = types.ResolvedSource;
pub const ObjectKind = types.ObjectKind;
