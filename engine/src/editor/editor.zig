//! Editor System
//! Main module for the editor, coordinates all editor features including
//! the command system, keybindings, and panels.

const std = @import("std");
const logger = @import("../core/logging.zig");
const imgui = @import("../systems/imgui.zig");
const input = @import("../systems/input.zig");
const event = @import("../systems/event.zig");
const memory = @import("../systems/memory.zig");
const math = @import("../math/math.zig");
const renderer = @import("../renderer/renderer.zig");
const engine_context = @import("../context.zig");

// Command system
const Command = @import("commands/command.zig").Command;
const CommandRegistry = @import("commands/registry.zig").CommandRegistry;
const builtin_commands = @import("commands/builtin.zig");

// Keybinding system
const KeyCombo = @import("keybindings/keybinding.zig").KeyCombo;
const KeybindingManager = @import("keybindings/manager.zig").KeybindingManager;
const keybinding_config = @import("keybindings/config.zig");

// Panels
const CommandPalette = @import("panels/command_palette.zig").CommandPalette;
const ConsolePanel = @import("panels/console_panel.zig").ConsolePanel;
const DebugOverlay = @import("panels/debug_overlay.zig").DebugOverlay;
const gizmo_mod = @import("panels/gizmo.zig");
const Gizmo = gizmo_mod.Gizmo;
const TransformDelta = gizmo_mod.TransformDelta;
const PanelManager = @import("panel_manager.zig").PanelManager;

// New editor systems
const EditorScene = @import("editor_scene.zig").EditorScene;
const EditorCamera = @import("editor_camera.zig").EditorCamera;
const Selection = @import("selection.zig").Selection;
const picking = @import("picking.zig");

// Existing editor sub-modules
pub const scene_editor = @import("scene_editor.zig");
pub const property_inspector = @import("property_inspector.zig");
pub const asset_browser = @import("asset_browser.zig");
pub const console = @import("console.zig");

pub const EditorSystem = struct {
    // State
    var initialized: bool = false;
    var allocator: std.mem.Allocator = undefined;

    // Core systems
    var command_registry: CommandRegistry = undefined;
    var keybinding_manager: KeybindingManager = undefined;
    var panel_manager: PanelManager = undefined;

    // Panels and overlays
    var command_palette: CommandPalette = undefined;
    var console_panel: ConsolePanel = undefined;
    var debug_overlay: DebugOverlay = undefined;
    var gizmo: Gizmo = undefined;

    // New editor systems
    // Note: editor_scene is heap-allocated to work across library boundaries
    var editor_scene_ptr: ?*EditorScene = null;
    var editor_camera: EditorCamera = .{};
    var selection: Selection = .{};

    // Mouse click state for picking
    var was_left_button_down: bool = false;

    // Panel visibility flags (disabled by default - use palette/shortcuts to open)
    var show_scene_hierarchy: bool = false;
    var show_property_inspector: bool = false;
    var show_asset_browser: bool = false;
    var show_console: bool = false;
    var show_material_panel: bool = false;

    pub fn initialize() bool {
        if (!imgui.ImGuiSystem.isInitialized()) {
            logger.err("Editor requires ImGui to be initialized", .{});
            return false;
        }

        allocator = memory.getAllocator();

        // Initialize command registry
        command_registry = CommandRegistry.init(allocator);

        // Set up editor callbacks for built-in commands
        builtin_commands.setCallbacks(.{
            .openCommandPalette = openCommandPalette,
            .closeCommandPalette = closeCommandPalette,
            .toggleConsole = toggleConsole,
            .toggleAssetManager = toggleAssetManager,
            .toggleMaterialPanel = toggleMaterialPanel,
            .toggleSceneHierarchy = toggleSceneHierarchy,
            .togglePropertyInspector = togglePropertyInspector,
            .toggleDebugOverlay = toggleDebugOverlay,
            .toggleGizmo = toggleGizmo,
            .gizmoModeTranslate = gizmoModeTranslate,
            .gizmoModeRotate = gizmoModeRotate,
            .gizmoModeScale = gizmoModeScale,
            .gizmoToggleSpace = gizmoToggleSpace,
        });

        // Register built-in commands
        builtin_commands.registerBuiltinCommands(&command_registry) catch {
            logger.err("Failed to register built-in commands", .{});
            return false;
        };

        // Initialize keybinding manager
        keybinding_manager = KeybindingManager.init(allocator, &command_registry);
        keybinding_manager.registerDefaults() catch {
            logger.err("Failed to register default keybindings", .{});
            return false;
        };

        // Try to load custom keybindings from config file
        keybinding_config.loadFromFile(&keybinding_manager, "keybindings.conf") catch {
            // Config file is optional, defaults are already loaded
        };

        // Initialize panel manager
        panel_manager = PanelManager.init(allocator);

        // Initialize panels
        command_palette = CommandPalette.init(allocator);
        console_panel = ConsolePanel.init(allocator);
        debug_overlay = DebugOverlay{};
        gizmo = Gizmo{};

        // Register for key events
        _ = event.register(.key_pressed, null, onKeyPressed);

        // Initialize editor scene (heap-allocated for cross-library sharing)
        editor_scene_ptr = allocator.create(EditorScene) catch {
            logger.err("Failed to allocate EditorScene", .{});
            return false;
        };
        editor_scene_ptr.?.* = EditorScene.init(allocator);
        engine_context.get().editor_scene = editor_scene_ptr;
        logger.debug("[CONTEXT] Set editor_scene in context: ctx={*}, scene={*}", .{ engine_context.get(), editor_scene_ptr });

        // Initialize existing editor sub-systems and set context
        scene_editor.init();
        scene_editor.setContext(editor_scene_ptr.?, &selection);
        property_inspector.init();
        property_inspector.setContext(editor_scene_ptr.?, &selection);
        asset_browser.init();
        console.init();

        // Add initial log message
        console_panel.addLog(.info, "Editor initialized");
        console_panel.addLogFmt(.info, "Registered {} commands", .{command_registry.count()});
        console_panel.addLogFmt(.info, "Registered {} keybindings", .{keybinding_manager.count()});

        initialized = true;
        logger.info("Editor system initialized with command palette support", .{});
        return true;
    }

    pub fn shutdown() void {
        if (!initialized) return;

        _ = event.unregister(.key_pressed, null, onKeyPressed);

        console_panel.deinit();
        command_palette.deinit();
        panel_manager.deinit();
        keybinding_manager.deinit();
        command_registry.deinit();

        // Cleanup editor scene
        engine_context.get().editor_scene = null;
        if (editor_scene_ptr) |scene| {
            scene.deinit();
            allocator.destroy(scene);
            editor_scene_ptr = null;
        }

        console.shutdown();
        asset_browser.shutdown();
        property_inspector.shutdown();
        scene_editor.shutdown();

        initialized = false;
        logger.info("Editor system shutdown", .{});
    }

    /// Event callback for key presses.
    fn onKeyPressed(code: u16, sender: ?*anyopaque, listener: ?*anyopaque, data: event.EventContext) bool {
        _ = code;
        _ = sender;
        _ = listener;

        if (!initialized) return false;

        const key_code: u16 = data.u16[0];
        const mods_raw: i16 = @bitCast(data.u16[1]);

        const key = input.Key.fromGlfw(@intCast(key_code)) orelse return false;
        const mods = input.Mods.fromGlfw(@intCast(mods_raw));

        // Update keybinding manager context
        keybinding_manager.context.command_palette_open = command_palette.is_open;
        keybinding_manager.context.editing_text = imgui.ImGuiSystem.wantsCaptureKeyboard() and !command_palette.is_open;
        keybinding_manager.context.gizmo_visible = gizmo.is_visible;

        // Process keybinding
        if (keybinding_manager.processKeyEvent(key, mods)) {
            return true; // Event handled, stop propagation
        }

        return false;
    }

    /// Update editor camera and apply to renderer.
    /// Call this BEFORE beginFrame so the view matrix is correct for rendering.
    pub fn updateCamera(delta_time: f32) void {
        if (!initialized) return;

        // Update editor camera
        editor_camera.update(delta_time);

        // Apply editor camera to renderer
        if (renderer.getSystem()) |render_sys| {
            render_sys.camera_position = editor_camera.position;
            render_sys.camera_view_matrix = editor_camera.getViewMatrix();
        }
    }

    /// Call this during the ImGui frame to render editor UI.
    /// delta_time is in seconds.
    pub fn update(delta_time: f32) void {
        if (!initialized) {
            return;
        }

        // Update debug overlay metrics
        debug_overlay.update(delta_time);

        // Handle mouse click for object picking
        handleMousePicking();

        // Update gizmo from selection
        updateGizmoFromSelection();

        // Main menu bar
        renderMainMenuBar();

        // Render command palette (modal, rendered on top)
        if (command_palette.render(&command_registry)) |cmd_id| {
            _ = command_registry.execute(cmd_id);
        }

        // Editor windows
        if (show_scene_hierarchy) {
            scene_editor.render(&show_scene_hierarchy);
        }

        if (show_property_inspector) {
            property_inspector.render(&show_property_inspector);
        }

        if (show_asset_browser) {
            asset_browser.render(&show_asset_browser);
        }

        if (show_console) {
            console_panel.render(&show_console);
        }

        // Material panel (placeholder)
        if (show_material_panel) {
            renderMaterialPanel();
        }

        // Overlays (drawn on top of everything)
        debug_overlay.render();

        // Render gizmo and apply transform delta to selected object
        if (gizmo.render()) |delta| {
            applyGizmoDelta(delta);
        }
    }

    /// Handle mouse click for object picking
    fn handleMousePicking() void {
        const is_left_down = input.isButtonDown(.left);

        // Detect click (just pressed)
        if (is_left_down and !was_left_button_down) {
            logger.debug("[PICKING] Left click detected", .{});

            const imgui_wants_mouse = imgui.ImGuiSystem.wantsCaptureMouse();
            const gizmo_active = gizmo.is_active;
            const gizmo_hovered = (gizmo.hovered_axis != gizmo_mod.Axis.none);
            logger.debug("[PICKING] ImGui wants mouse: {}, Gizmo active: {}, Gizmo hovered: {}", .{ imgui_wants_mouse, gizmo_active, gizmo_hovered });

            // Don't pick if ImGui wants the mouse or gizmo is being manipulated or hovered
            if (!imgui_wants_mouse and !gizmo_active and !gizmo_hovered) {
                // Get mouse position
                const mouse = input.getMousePosition();
                const mx = @as(f32, @floatCast(mouse.x));
                const my = @as(f32, @floatCast(mouse.y));

                // Get screen size
                const io = imgui.getIO();
                const sw = io.*.DisplaySize.x;
                const sh = io.*.DisplaySize.y;

                logger.debug("[PICKING] Mouse pos: ({d:.1}, {d:.1}), Screen size: ({d:.1}, {d:.1})", .{ mx, my, sw, sh });

                // Get inverse view-projection matrix
                if (renderer.getSystem()) |render_sys| {
                    const view = editor_camera.getViewMatrix();
                    const proj = render_sys.projection;
                    const view_proj = math.mat4Mul(view, proj);
                    const inv_view_proj = math.mat4Inverse(view_proj);

                    // Create picking ray
                    const ray = picking.screenToRay(mx, my, sw, sh, inv_view_proj);

                    logger.debug("[PICKING] Ray origin: ({d:.2}, {d:.2}, {d:.2}), dir: ({d:.2}, {d:.2}, {d:.2})", .{ ray.origin[0], ray.origin[1], ray.origin[2], ray.direction[0], ray.direction[1], ray.direction[2] });

                    // Get scene from shared context
                    logger.debug("[CONTEXT] Getting editor_scene from context: ctx={*}", .{engine_context.get()});
                    const scene = engine_context.get().editor_scene orelse {
                        logger.warn("[PICKING] No editor scene in context!", .{});
                        return;
                    };

                    // Log scene objects for debugging
                    logger.debug("[PICKING] editor_scene ptr={*}", .{scene});
                    const objects = scene.getAllObjects();
                    logger.debug("[PICKING] Scene has {} objects", .{objects.len});
                    for (objects) |obj| {
                        logger.debug("[PICKING]   Object {}: bounds min=({d:.2},{d:.2},{d:.2}) max=({d:.2},{d:.2},{d:.2})", .{ obj.id, obj.world_bounds_min[0], obj.world_bounds_min[1], obj.world_bounds_min[2], obj.world_bounds_max[0], obj.world_bounds_max[1], obj.world_bounds_max[2] });
                    }

                    // Pick object
                    const picked_id = picking.pickObject(scene, ray);
                    logger.debug("[PICKING] Picked object ID: {}", .{picked_id});

                    if (picked_id != @import("editor_scene.zig").INVALID_OBJECT_ID) {
                        selection.select(picked_id);
                        gizmo.is_visible = true;
                        logger.info("[PICKING] Selected object {}", .{picked_id});
                    } else {
                        selection.deselect();
                        logger.debug("[PICKING] No object hit, deselected", .{});
                    }
                } else {
                    logger.warn("[PICKING] No renderer system available", .{});
                }
            }
        }

        was_left_button_down = is_left_down;
    }

    /// Update gizmo position from selected object
    fn updateGizmoFromSelection() void {
        const scene = engine_context.get().editor_scene orelse return;

        if (selection.getSelected()) |selected_id| {
            if (scene.getObject(selected_id)) |obj| {
                // Set gizmo target from object transform
                gizmo.setTarget(obj.transform.position, obj.transform.rotation, obj.transform.scale);
                gizmo.is_visible = true;

                // Set up view-projection for world-space rendering
                if (renderer.getSystem()) |render_sys| {
                    const io = imgui.getIO();
                    const view = editor_camera.getViewMatrix();
                    const proj = render_sys.projection;
                    const view_proj = math.mat4Mul(view, proj);
                    gizmo.setViewProjection(view_proj, io.*.DisplaySize.x, io.*.DisplaySize.y);
                } else {
                    logger.warn("[GIZMO] Renderer system not available", .{});
                }
            } else {
                logger.warn("[GIZMO] Selected object {d} not found in scene", .{selected_id});
                gizmo.is_visible = false;
            }
        } else {
            // No selection - disable gizmo
            gizmo.is_visible = false;
            gizmo.use_world_position = false;
        }
    }

    /// Apply gizmo transform delta to selected object
    fn applyGizmoDelta(delta: TransformDelta) void {
        const scene = engine_context.get().editor_scene orelse return;

        if (selection.getSelected()) |selected_id| {
            if (scene.getObject(selected_id)) |obj| {
                // Apply position delta
                obj.transform.position[0] += delta.position[0];
                obj.transform.position[1] += delta.position[1];
                obj.transform.position[2] += delta.position[2];

                // Apply rotation delta
                obj.transform.rotation[0] += delta.rotation[0];
                obj.transform.rotation[1] += delta.rotation[1];
                obj.transform.rotation[2] += delta.rotation[2];

                // Apply scale delta (multiplicative)
                obj.transform.scale[0] *= delta.scale[0];
                obj.transform.scale[1] *= delta.scale[1];
                obj.transform.scale[2] *= delta.scale[2];

                // Update bounds
                scene.updateBounds(obj);
            }
        }
    }

    fn renderMainMenuBar() void {
        if (imgui.beginMainMenuBar()) {
            if (imgui.beginMenu("File")) {
                if (imgui.menuItem("New Scene")) {
                    // TODO: Implement new scene
                }
                if (imgui.menuItem("Open Scene...")) {
                    // TODO: Implement open scene
                }
                if (imgui.menuItem("Save Scene")) {
                    // TODO: Implement save scene
                }
                imgui.separator();
                if (imgui.menuItem("Exit")) {
                    const ctx: event.EventContext = undefined;
                    _ = event.fire(.application_quit, null, ctx);
                }
                imgui.endMenu();
            }

            if (imgui.beginMenu("Edit")) {
                if (imgui.menuItem("Command Palette...")) {
                    command_palette.open();
                }
                imgui.endMenu();
            }

            if (imgui.beginMenu("View")) {
                _ = imgui.menuItemSelected("Scene Hierarchy", &show_scene_hierarchy);
                _ = imgui.menuItemSelected("Property Inspector", &show_property_inspector);
                _ = imgui.menuItemSelected("Asset Browser", &show_asset_browser);
                _ = imgui.menuItemSelected("Material Panel", &show_material_panel);
                _ = imgui.menuItemSelected("Console", &show_console);
                imgui.separator();
                _ = imgui.menuItemSelected("Debug Overlay", &debug_overlay.is_visible);
                _ = imgui.menuItemSelected("Gizmo", &gizmo.is_visible);
                imgui.endMenu();
            }

            if (imgui.beginMenu("Gizmo")) {
                if (imgui.menuItem("Translate Mode (T)")) {
                    gizmo.setMode(.translate);
                }
                if (imgui.menuItem("Rotate Mode (R)")) {
                    gizmo.setMode(.rotate);
                }
                if (imgui.menuItem("Scale Mode (S)")) {
                    gizmo.setMode(.scale);
                }
                imgui.separator();
                if (imgui.menuItem("Toggle Local/World (X)")) {
                    gizmo.toggleSpace();
                }
                imgui.endMenu();
            }

            if (imgui.beginMenu("Help")) {
                if (imgui.menuItem("About Butter Engine")) {
                    // TODO: Show about dialog
                }
                if (imgui.menuItem("Keyboard Shortcuts")) {
                    // TODO: Show shortcuts
                }
                imgui.endMenu();
            }

            imgui.endMainMenuBar();
        }
    }

    fn renderMaterialPanel() void {
        if (imgui.begin("Material Panel", &show_material_panel, imgui.WindowFlags.None)) {
            imgui.text("Material Panel");
            imgui.separator();
            imgui.text("(Material editing coming soon)");
        }
        imgui.end();
    }

    // Command callback implementations

    fn openCommandPalette() void {
        command_palette.open();
    }

    fn closeCommandPalette() void {
        command_palette.close();
    }

    fn toggleConsole() void {
        show_console = !show_console;
    }

    fn toggleAssetManager() void {
        show_asset_browser = !show_asset_browser;
    }

    fn toggleMaterialPanel() void {
        show_material_panel = !show_material_panel;
    }

    fn toggleSceneHierarchy() void {
        show_scene_hierarchy = !show_scene_hierarchy;
    }

    fn togglePropertyInspector() void {
        show_property_inspector = !show_property_inspector;
    }

    fn toggleDebugOverlay() void {
        debug_overlay.is_visible = !debug_overlay.is_visible;
    }

    fn toggleGizmo() void {
        // Only show gizmo if something is selected
        if (selection.hasSelection()) {
            gizmo.is_visible = !gizmo.is_visible;
        } else {
            gizmo.is_visible = false;
            logger.debug("Cannot show gizmo: no object selected", .{});
        }
    }

    fn gizmoModeTranslate() void {
        gizmo.setMode(.translate);
    }

    fn gizmoModeRotate() void {
        gizmo.setMode(.rotate);
    }

    fn gizmoModeScale() void {
        gizmo.setMode(.scale);
    }

    fn gizmoToggleSpace() void {
        gizmo.toggleSpace();
    }

    // Public API for external access

    /// Get the command registry for registering custom commands.
    pub fn getCommandRegistry() *CommandRegistry {
        return &command_registry;
    }

    /// Get the keybinding manager for registering custom keybindings.
    pub fn getKeybindingManager() *KeybindingManager {
        return &keybinding_manager;
    }

    /// Get the console panel for adding log messages.
    pub fn getConsolePanel() *ConsolePanel {
        return &console_panel;
    }

    /// Get the debug overlay for setting hovered object info.
    pub fn getDebugOverlay() *DebugOverlay {
        return &debug_overlay;
    }

    /// Get the gizmo for setting target transform.
    pub fn getGizmo() *Gizmo {
        return &gizmo;
    }

    /// Check if the command palette is currently open.
    pub fn isCommandPaletteOpen() bool {
        return command_palette.is_open;
    }

    /// Get the editor scene for adding objects.
    /// Uses shared context to work across library boundaries.
    pub fn getEditorScene() ?*EditorScene {
        // Use shared context to get scene - this works across library boundaries
        return engine_context.get().editor_scene;
    }

    /// Get the selection state.
    pub fn getSelection() *Selection {
        return &selection;
    }

    /// Get the editor camera.
    pub fn getEditorCamera() *EditorCamera {
        return &editor_camera;
    }
};
