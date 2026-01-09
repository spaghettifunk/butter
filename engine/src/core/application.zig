const std = @import("std");
const build_options = @import("build_options");

const logger = @import("logging.zig");
const memory = @import("../systems/memory.zig");
const event = @import("../systems/event.zig");
const input = @import("../systems/input.zig");
const texture = @import("../systems/texture.zig");
const material = @import("../systems/material.zig");
const mesh_asset = @import("../systems/mesh_asset.zig");
const jobs = @import("../systems/jobs.zig");
const resource_manager = @import("../resources/manager.zig");
const environment = @import("../systems/environment.zig");

const clock = @import("clock.zig");

const Game = @import("../game_types.zig").Game;
const platform = @import("../platform/platform.zig");
const renderer = @import("../renderer/renderer.zig");
const render_graph = @import("../systems/render_graph.zig");

// Conditional ImGui import based on build options
const imgui = if (build_options.enable_imgui)
    @import("../systems/imgui.zig")
else
    @import("../systems/imgui_stub.zig");

// Conditional editor import based on build options
const editor = if (build_options.enable_editor)
    @import("../editor/editor.zig")
else
    struct {
        pub const EditorSystem = struct {
            pub fn updateCamera(_: f32) void {}
            pub fn update(_: f32) void {}
        };
    };

const applicationState = struct {
    gameInstance: Game,
    isRunning: bool,
    isSuspended: bool,
    platform: platform.PlatformState,
    width: i16,
    height: i16,
    clock: clock.Clock,
    lastTime: f64,
    editorMode: bool, // Whether we're running in editor mode
};

pub var appState: *applicationState = undefined;

fn onResized(code: u16, sender: ?*anyopaque, listener: ?*anyopaque, data: event.EventContext) bool {
    _ = sender;
    _ = listener;

    if (code == @intFromEnum(event.SystemEventCode.resized)) {
        const width = data.u16[0];
        const height = data.u16[1];

        // Check if different. If so, trigger a resize event.
        if (width != appState.width or height != appState.height) {
            appState.width = @intCast(width);
            appState.height = @intCast(height);

            logger.debug("Window resize: {}, {}", .{ width, height });

            // Handle minimization
            if (width == 0 or height == 0) {
                logger.info("Window minimized, suspending application.", .{});
                appState.isSuspended = true;
                return true;
            } else {
                if (appState.isSuspended) {
                    logger.info("Window restored, resuming application.", .{});
                    appState.isSuspended = false;
                }
                appState.gameInstance.onResize(&appState.gameInstance, width, height);
                if (renderer.getSystem()) |sys| {
                    sys.onResized(width, height);
                }
                // Also resize render graph
                render_graph.RenderGraphSystem.onResized(width, height);
            }
        }
    }

    // Event purposely not handled to allow other listeners to get this.
    return false;
}

fn onEvent(code: u16, sender: ?*anyopaque, listener: ?*anyopaque, data: event.EventContext) bool {
    _ = sender;
    _ = listener;
    _ = data;

    const code_enum: event.SystemEventCode = @enumFromInt(code);
    switch (code_enum) {
        else => {
            return false;
        },
    }
    return false;
}

fn onKey(code: u16, sender: ?*anyopaque, listener: ?*anyopaque, data: event.EventContext) bool {
    _ = sender;
    _ = listener;

    const code_enum: event.SystemEventCode = @enumFromInt(code);
    switch (code_enum) {
        .key_pressed => {
            const key_code: u16 = data.u16[0];

            if (key_code == @intFromEnum(input.Key.escape)) {
                // NOTE: Technically firing an event to itself, but there may be other listeners.
                const ctx: event.EventContext = undefined;
                _ = event.fire(event.SystemEventCode.application_quit, null, ctx);
                // Block anything else from processing this.
                return true;
            }
        },
        else => {
            return false;
        },
    }
    return false;
}

/// Create application for runtime mode (no ImGui, no editor features)
pub fn createRuntime(gameInstance: *Game) bool {
    return createInternal(gameInstance, false);
}

/// Create application for editor mode (with ImGui and editor features)
pub fn createEditor(gameInstance: *Game) bool {
    return createInternal(gameInstance, true);
}

/// Legacy create function - defaults to editor mode if ImGui is enabled
pub fn create(gameInstance: *Game) bool {
    return createInternal(gameInstance, build_options.enable_imgui);
}

fn createInternal(gameInstance: *Game, editorMode: bool) bool {
    if (gameInstance.applicationState != null) {
        logger.fatal("application_create called more than once.", .{});
        return false;
    }

    // Initialize memory system FIRST so allocations are tracked
    if (!memory.MemorySystem.initialize()) {
        logger.fatal("Could not initialize memory system!", .{});
        return false;
    }

    // Initialize Job System early (before other systems that may use it)
    const job_scheduler = jobs.JobScheduler.init(memory.getAllocator()) catch |err| {
        logger.fatal("Failed to initialize job system: {}", .{err});
        return false;
    };
    logger.info("Job system initialized with {} workers", .{job_scheduler.worker_count});

    // Allocate application state
    appState = memory.allocate(applicationState, .application) orelse {
        logger.fatal("Failed to allocate application state!", .{});
        return false;
    };
    gameInstance.applicationState = @ptrCast(appState);

    appState.gameInstance = gameInstance.*;
    appState.isRunning = false;
    appState.isSuspended = false;
    appState.editorMode = editorMode;
    appState.width = appState.gameInstance.appConfig.startWidth;
    appState.height = appState.gameInstance.appConfig.startHeight;

    // Initialize logging subsystem
    if (!logger.LoggingSystem.initialize("logs.txt")) {
        logger.fatal("Failed to initialize logging subsystem.", .{});
        return false;
    }

    // Initialize input subsystem
    if (!input.InputSystem.initialize()) {
        logger.fatal("Failed to initialize input subsystem.", .{});
        return false;
    }

    // Initialize events subsystem
    if (!event.EventSystem.initialize()) {
        logger.fatal("Could not initialize event system!", .{});
        return false;
    }

    // Register for resize events
    _ = event.register(.application_quit, null, onEvent);
    _ = event.register(.key_pressed, null, onKey);
    _ = event.register(.key_released, null, onKey);
    _ = event.register(.resized, null, onResized);

    if (!platform.startup(&appState.platform, appState.gameInstance.appConfig.name, appState.gameInstance.appConfig.startPosX, appState.gameInstance.appConfig.startPosY, appState.gameInstance.appConfig.startWidth, appState.gameInstance.appConfig.startHeight)) {
        return false;
    }

    // Initialize renderer subsystem
    // TODO: make backend type configurable
    if (!renderer.RendererSystem.initialize(.vulkan, appState.gameInstance.appConfig.name)) {
        logger.err("Failed to initialize renderer subsystem.", .{});
        return false;
    }

    // Initialize texture system (after renderer is available)
    if (!texture.TextureSystem.initialize()) {
        logger.err("Failed to initialize texture system.", .{});
        return false;
    }

    // Initialize environment system (after texture system is available)
    _ = environment.initialize(std.heap.page_allocator) catch |err| {
        logger.err("Failed to initialize environment system: {}", .{err});
        // Continue without environment - materials will use default textures
    };

    // Initialize material system (after texture system is available)
    if (!material.MaterialSystem.initialize()) {
        logger.err("Failed to initialize material system.", .{});
        return false;
    }

    // Initialize mesh asset system (after renderer, texture, material)
    if (!mesh_asset.MeshAssetSystem.initialize()) {
        logger.err("Failed to initialize mesh asset system.", .{});
        return false;
    }

    // Initialize Resource Manager (after all resource systems)
    if (!resource_manager.ResourceManager.init(memory.getAllocator())) {
        logger.err("Failed to initialize resource manager system.", .{});
        return false;
    }

    // Initialize render graph system (after renderer)
    if (!render_graph.RenderGraphSystem.initialize(
        @intCast(appState.width),
        @intCast(appState.height),
    )) {
        logger.err("Failed to initialize render graph system.", .{});
        return false;
    }

    // Register grid pass callback (editor only)
    if (build_options.enable_editor and editorMode) {
        logger.debug("Registering grid pass callback (editor mode active)...", .{});
        if (renderer.getSystem()) |sys| {
            switch (sys.backend) {
                .vulkan => |*v| {
                    logger.debug("Registering grid callback for Vulkan backend", .{});
                    if (!render_graph.RenderGraphSystem.setPassCallback(
                        "grid_pass",
                        @import("../renderer/vulkan/backend.zig").VulkanBackend.renderGridPass,
                        v,
                    )) {
                        logger.warn("Failed to register grid pass callback", .{});
                    } else {
                        logger.info("Grid pass callback registered successfully (Vulkan)", .{});
                    }
                },
                .metal => |*m| {
                    logger.debug("Registering grid callback for Metal backend", .{});
                    if (!render_graph.RenderGraphSystem.setPassCallback(
                        "grid_pass",
                        @import("../renderer/metal/backend.zig").MetalBackend.renderGridPass,
                        m,
                    )) {
                        logger.warn("Failed to register grid pass callback", .{});
                    } else {
                        logger.info("Grid pass callback registered successfully (Metal)", .{});
                    }
                },
                else => {},
            }
        }
    } else {
        logger.debug("NOT registering grid callback: enable_editor={}, editorMode={}", .{ build_options.enable_editor, editorMode });
    }

    // Initialize ImGui system (after renderer) - only in editor mode with ImGui enabled
    if (build_options.enable_imgui and editorMode) {
        if (!imgui.ImGuiSystem.initialize()) {
            logger.warn("Failed to initialize ImGui system - UI will be disabled.", .{});
            // Don't fail - ImGui is optional
        }
    }

    // Initialize game instance
    if (!appState.gameInstance.initialize(&appState.gameInstance)) {
        logger.err("Game failed to initialize.", .{});
        return false;
    }

    appState.gameInstance.onResize(&appState.gameInstance, @intCast(appState.width), @intCast(appState.height));

    return true;
}

pub fn run() bool {
    appState.isRunning = true;

    clock.start(&appState.clock);
    clock.update(&appState.clock);
    appState.lastTime = appState.clock.elapsed;

    var running_time: f64 = 0;
    var frame_count: u64 = 0;
    const target_frame_seconds: f64 = 1.0 / 60.0;

    logger.info("{s}", .{memory.usageString()});

    while (appState.isRunning) {
        if (!platform.pumpMessages(&appState.platform)) {
            appState.isRunning = false;
        }

        if (!appState.isSuspended) {
            // Update clock and get delta time.
            clock.update(&appState.clock);
            const current_time: f64 = appState.clock.elapsed;
            const delta: f64 = (current_time - appState.lastTime);
            const frame_start_time: f64 = platform.getAbsoluteTime();

            if (!appState.gameInstance.update(&appState.gameInstance, delta)) {
                logger.err("Game update failed, shutting down.", .{});
                appState.isRunning = false;
                break;
            }

            // Draw the frame using the renderer, with game render in between begin/end
            const delta_f32: f32 = @floatCast(delta);

            // Update Job System (process main-thread jobs)
            const ctx = @import("../context.zig");
            if (ctx.get().jobs) |job_scheduler| {
                job_scheduler.update();
            }

            // Update editor camera BEFORE beginFrame so view matrix is correct for rendering
            if (build_options.enable_editor and appState.editorMode) {
                editor.EditorSystem.updateCamera(delta_f32);
            }

            if (renderer.getSystem()) |sys| {
                // Begin the frame (starts command buffer recording)
                if (sys.beginFrame(delta_f32)) {
                    // Begin ImGui frame (must be after renderer beginFrame) - only in editor mode
                    if (build_options.enable_imgui and appState.editorMode) {
                        imgui.ImGuiSystem.beginFrame();
                    }

                    // Call the game's render routine (now inside the frame)
                    // Game can use imgui.* functions here to render UI
                    if (!appState.gameInstance.render(&appState.gameInstance, delta)) {
                        logger.err("Game render failed, shutting down.", .{});
                        appState.isRunning = false;
                        break;
                    }

                    // Execute render graph passes (AFTER game render so grid appears on top)
                    // Note: Currently the render graph just logs execution, actual rendering
                    // still happens via the game's render callback above. The grid pass executes here
                    // so it renders on top of the game geometry.
                    if (!render_graph.RenderGraphSystem.execute(delta_f32)) {
                        logger.warn("Render graph execution failed", .{});
                        // Don't fail completely, fall back to traditional rendering
                    }

                    // Update editor UI (command palette, panels, overlays) - only in editor mode
                    if (build_options.enable_editor and appState.editorMode) {
                        editor.EditorSystem.update(delta_f32);
                    }

                    // End ImGui frame and render (must be before renderer endFrame) - only in editor mode
                    if (build_options.enable_imgui and appState.editorMode) {
                        imgui.ImGuiSystem.endFrame();
                    }

                    // End the frame (submits command buffer)
                    if (!sys.endFrame(delta_f32)) {
                        logger.err("Renderer end_frame failed, shutting down.", .{});
                        appState.isRunning = false;
                        break;
                    }
                }

                // Figure out how long the frame took and, if below
                const frame_end_time: f64 = platform.getAbsoluteTime();
                const frame_elapsed_time: f64 = frame_end_time - frame_start_time;
                running_time += frame_elapsed_time;
                const remaining_seconds: f64 = target_frame_seconds - frame_elapsed_time;

                if (remaining_seconds > 0) {
                    const remaining_ms: u64 = @intFromFloat(remaining_seconds * 1000);

                    // If there is time left, give it back to the OS.
                    const limit_frames: bool = false;
                    if (remaining_ms > 0 and limit_frames) {
                        std.Thread.sleep(remaining_ms - 1);
                    }

                    frame_count += 1;
                }
            }

            // NOTE: Input update/state copying should always be handled
            // after any input should be recorded; I.E. before this line.
            // As a safety, input is the last thing to be updated before
            // this frame ends.
            input.InputSystem.update(delta);

            appState.lastTime = current_time;
        }
    }

    appState.isRunning = false;

    _ = event.unregister(.application_quit, null, onEvent);
    _ = event.unregister(.key_pressed, null, onKey);
    _ = event.unregister(.key_released, null, onKey);

    // Shutdown game first (so it can release GPU resources before renderer shuts down)
    appState.gameInstance.shutdown(&appState.gameInstance);

    // Shutdown subsystems in reverse order
    // Shutdown ImGui only if it was enabled and we're in editor mode
    if (build_options.enable_imgui and appState.editorMode) {
        imgui.ImGuiSystem.shutdown();
    }
    render_graph.RenderGraphSystem.shutdown();

    // Shutdown Resource Manager (before resource systems)
    const ctx = @import("../context.zig");
    if (ctx.get().resource_manager) |resource_mgr| {
        resource_mgr.deinit();
        memory.deallocate(resource_manager.ResourceManager, resource_mgr, .resource_system);
        ctx.get().resource_manager = null;
        logger.info("Resource manager shutdown", .{});
    }

    mesh_asset.MeshAssetSystem.shutdown();

    material.MaterialSystem.shutdown();

    texture.TextureSystem.shutdown();
    renderer.RendererSystem.shutdown();
    event.EventSystem.shutdown();
    input.InputSystem.shutdown();

    platform.shutdown(&appState.platform);

    // Shutdown Job System (after all systems that use it)
    if (ctx.get().jobs) |job_scheduler| {
        job_scheduler.deinit();
        ctx.get().jobs = null;
    }

    // Deallocate application state before shutting down memory system
    memory.deallocate(applicationState, appState, .application);
    memory.MemorySystem.shutdown();

    return true;
}
