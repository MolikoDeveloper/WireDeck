## Internal Bus Routing Tasks

- [x] Move bus playback exposure to internal engine-backed `wiredeck_output_bus_*` sources
- [x] Feed physical destinations from bus loopbacks instead of per-channel FX outputs
- [x] Preserve internal bus tap state across graph rebuilds
- [x] Prefer direct PipeWire app capture when a stable `Stream/Output/Audio` node resolves
- [x] Add app-stream fallback so failed legacy capture moves do not loop forever or leave streams muted
- [x] Filter synthetic/managed WireDeck loopback owners out of grouped app inventory and routing
- [x] Skip FX route creation for app channels that no longer have a live resolvable capture owner
- [x] Fix shutdown hang after `shutdown: deinit output exposure`
- [x] Validate current runtime with `./scripts/build.sh`, `./scripts/build.sh test`, and `./scripts/build.sh run`
- [x] Remove the remaining Pulse parking-sink requirement for direct app capture
- [ ] Make app/TTS capture fully internal so no app routing depends on Pulse sink moves
- [ ] Validate that zero-volume direct app capture stays stable when PipeWire corks or reconfigures streams
- [ ] Confirm audible output on every enabled destination from the internal bus mix
- [x] Decide whether FX/UI host crashes from third-party LV2 UIs should be sandboxed or disabled by policy
- [ ] Validate runtime route-switch latency and multi-source stability under load
- [x] Document crash-risk review findings for Pulse/PipeWire lifecycle paths
- [x] Fix Pulse operation timeout handling so late callbacks cannot touch expired stack request state
- [x] Validate PipeWire filter port creation before connect/activate so null ports cannot reach the process callback
- [x] Serialize FX filter link-health reads/writes to avoid routing-thread vs PipeWire callback data races

Current runtime status:
- Bus playback is now exposed through hidden PipeWire sources named `wiredeck_output_bus_*`, and Pulse loopbacks route those sources to the selected physical sinks.
- Virtual mic exposure still uses `wiredeck_busmic_*` and is fed from the internal engine.
- Firefox now uses direct PipeWire capture in the FX graph (`input=output:Firefox`) without being moved to a hidden `wiredeck_input_*` sink; the live sink input stays on its real sink and is attenuated to `0%` instead.
- Synthetic `loopback-*` and WireDeck-managed owners are no longer exposed as app sources, which removed the bogus `appgrp-unknown` source and the `legacy capture move blocked` spam.
- Unresolvable stale app channels no longer create fallback FX routes, so startup FX routing now matches the actually live sources.
- Runtime inspection with `pactl`/`pw-cli` shows only `wiredeck_output_bus_*` loopbacks feeding physical sinks; legacy `wiredeck_input_*` parking sinks and per-channel `wiredeck-combine-*` outputs are no longer part of the direct-app path.
- Audible-output behavior still needs explicit end-to-end validation on every enabled destination.
- Headless runtime shutdown now completes cleanly after switching `VirtualMicSource` to `pw_main_loop_run()`/`pw_main_loop_quit()`.
- One `run` session also hit a segmentation fault inside `lsp-plugins-lv2ui.so`, which looks separate from the bus mixer work but should be tracked.
- Custom LV2 UIs now stay isolated in `wiredeck-lv2-ui-host`; if that helper exits by signal or abnormal status, WireDeck disables that descriptor's custom UI for the rest of the session instead of relaunching it repeatedly.

Crash-risk review notes:
- `PulseContext` uses stack-local async request structs for `move/set/load/unload` operations. If an operation times out and we return immediately, a late Pulse callback can still write into expired stack memory. This is the most urgent stability fix.
- `ChannelFxFilterManager.createFilter()` currently assumes all four PipeWire filter ports were created successfully. If any port creation returns null, the process callback can later call into PipeWire with invalid handles.
- `routeReady()` reads filter link state from the routing thread while PipeWire callbacks mutate the same fields concurrently. Even when it only looks like routing instability, this is still undefined behavior and should be serialized.
