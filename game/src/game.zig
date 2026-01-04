const engine = @import("engine");
const Game = engine.Game;
const input = engine.input;
const renderer = engine.renderer;
const material = engine.material;
const geometry = engine.geometry;
const math = engine.math;
const editor = engine.editor;
const std = @import("std");

pub const GameState = struct {
    deltaTime: f64 = 0,
    total_time: f64 = 0,

    // Geometry IDs for test objects
    cube_geo: u32 = 0,
    sphere_geo: u32 = 0,
    plane_geo: u32 = 0,

    // Material ID
    test_material_id: u32 = 0,

    // Flag to track if we've set up the scene
    scene_initialized: bool = false,

    // Testing flags
    test_async_loading: bool = false,
    async_texture_loaded: bool = false,
};

fn init(game: *Game) bool {
    _ = game;

    engine.logger.info("Game initialized!", .{});
    engine.logger.info("Build options: editor_enabled={}, imgui_enabled={}", .{ engine.editor_enabled, engine.imgui_enabled });

    return true;
}

fn update(game: *Game, dt: f64) bool {
    const state: *GameState = @ptrCast(@alignCast(game.state));
    state.deltaTime = dt;
    state.total_time += dt;

    // Initialize scene on first update (editor should be ready by then)
    if (!state.scene_initialized) {
        initializeTestScene(state);
        state.scene_initialized = true;
    }

    // Bind material BEFORE beginFrame (required for Vulkan descriptor set updates)
    // Vulkan cannot update descriptor sets during frame recording, so this must happen
    // during the update phase, not the render phase.
    if (state.scene_initialized) {
        material.bind(state.test_material_id);
    }

    return true;
}

// Callback for async texture loading test
fn onTextureLoaded(tex_handle: engine.resource_handle.TextureHandle) void {
    engine.logger.info("✅ ASYNC TEXTURE LOADED: ID = {d}, generation = {d}", .{tex_handle.id, tex_handle.generation});
}

// Test Resource Manager functionality
fn testResourceManager() void {
    engine.logger.info("=== Testing Resource Manager ===", .{});

    const ctx = @import("engine").context;
    const resource_mgr = ctx.get().resource_manager orelse {
        engine.logger.err("Resource Manager not available!", .{});
        return;
    };

    // Test 1: Synchronous texture loading through ResourceManager
    engine.logger.info("Test 1: Sync texture loading through ResourceManager...", .{});
    const tex_handle = resource_mgr.loadTexture("../assets/textures/cobblestone.png") catch |err| {
        engine.logger.warn("Failed to load texture through ResourceManager: {}", .{err});
        return;
    };
    engine.logger.info("✅ Loaded texture through ResourceManager: ID={d}, generation={d}", .{ tex_handle.id, tex_handle.generation });

    // Test 2: Async texture loading with callback
    engine.logger.info("Test 2: Async texture loading with callback...", .{});
    _ = resource_mgr.loadTextureAsync("../assets/textures/cobblestone.png", onTextureLoaded) catch |err| {
        engine.logger.warn("Failed to start async texture load: {}", .{err});
    };

    // Test 3: Material loading (auto-loads textures)
    engine.logger.info("Test 3: Material loading through ResourceManager...", .{});
    const mat_handle = resource_mgr.loadMaterial("cobblestone") catch |err| {
        engine.logger.warn("Failed to load material through ResourceManager: {}", .{err});
        return;
    };
    engine.logger.info("✅ Loaded material through ResourceManager: ID={d}, generation={d}", .{ mat_handle.id, mat_handle.generation });

    // Test 4: Check resource metadata
    engine.logger.info("Test 4: Querying resource metadata...", .{});
    if (resource_mgr.getMetadata("../assets/textures/cobblestone.png")) |meta| {
        engine.logger.info("✅ Texture metadata: state={s}, ref_count={d}, system_id={d}", .{
            meta.state.toString(),
            meta.ref_count,
            meta.system_id,
        });
    }

    if (resource_mgr.getMetadata("cobblestone")) |meta| {
        engine.logger.info("✅ Material metadata: state={s}, ref_count={d}, system_id={d}", .{
            meta.state.toString(),
            meta.ref_count,
            meta.system_id,
        });
    }

    engine.logger.info("=== Resource Manager Tests Complete ===", .{});
}

fn initializeTestScene(state: *GameState) void {
    engine.logger.info("Initializing test scene with geometries...", .{});

    // Run Resource Manager tests
    testResourceManager();

    const ctx = @import("engine").context;
    const resource_mgr = ctx.get().resource_manager orelse {
        engine.logger.err("Resource Manager not available!", .{});
        return;
    };

    // Load material using Resource Manager (NEW API)
    const mat_handle = resource_mgr.loadMaterial("cobblestone") catch |err| {
        engine.logger.warn("Failed to load cobblestone material through ResourceManager: {}", .{err});
        // Fallback to default material
        if (material.getDefaultMaterial()) |default_mat| {
            state.test_material_id = default_mat.id;
        }
        return;
    };
    state.test_material_id = mat_handle.id;
    engine.logger.info("Loaded cobblestone material through ResourceManager with ID: {d}", .{mat_handle.id});

    // Generate procedural geometries using Resource Manager (NEW API)
    const cube_handle = resource_mgr.loadGeometryCube(.{
        .name = "test_cube",
        .width = 1.0,
        .height = 1.0,
        .depth = 1.0,
        .color = .{ 0.8, 0.2, 0.2 }, // Red-ish
    }) catch |err| {
        engine.logger.err("Failed to create cube geometry through ResourceManager: {}", .{err});
        return;
    };
    state.cube_geo = cube_handle.id;
    engine.logger.info("Created cube geometry through ResourceManager with ID: {d}", .{cube_handle.id});

    const sphere_handle = resource_mgr.loadGeometrySphere(.{
        .name = "test_sphere",
        .radius = 0.5,
        .rings = 16,
        .sectors = 32,
        .color = .{ 0.2, 0.8, 0.2 }, // Green-ish
    }) catch |err| {
        engine.logger.err("Failed to create sphere geometry through ResourceManager: {}", .{err});
        return;
    };
    state.sphere_geo = sphere_handle.id;
    engine.logger.info("Created sphere geometry through ResourceManager with ID: {d}", .{sphere_handle.id});

    const plane_handle = resource_mgr.loadGeometryPlane(.{
        .name = "ground_plane",
        .width = 10.0,
        .height = 10.0,
        .color = .{ 0.5, 0.5, 0.5 }, // Gray
    }) catch |err| {
        engine.logger.err("Failed to create plane geometry through ResourceManager: {}", .{err});
        return;
    };
    state.plane_geo = plane_handle.id;
    engine.logger.info("Created plane geometry through ResourceManager with ID: {d}", .{plane_handle.id});

    // Add objects to editor scene
    const scene = editor.EditorSystem.getEditorScene() orelse {
        engine.logger.err("No editor scene available!", .{});
        return;
    };

    // Add cube
    if (state.cube_geo != 0) {
        const cube_id = scene.addObjectById("Cube", state.cube_geo, 0);
        if (scene.getObject(cube_id)) |obj| {
            obj.transform.position = .{ -2.0, 0.5, 0.0 };
            scene.updateBounds(obj);
        }
        engine.logger.info("Added Cube to scene with object ID: {d}", .{cube_id});
    }

    // Add sphere
    if (state.sphere_geo != 0) {
        const sphere_id = scene.addObjectById("Sphere", state.sphere_geo, 0);
        if (scene.getObject(sphere_id)) |obj| {
            obj.transform.position = .{ 2.0, 0.5, 0.0 };
            scene.updateBounds(obj);
        }
        engine.logger.info("Added Sphere to scene with object ID: {d}", .{sphere_id});
    }

    // Add ground plane (already horizontal on XZ plane, no rotation needed)
    if (state.plane_geo != 0) {
        const plane_id = scene.addObjectById("Ground", state.plane_geo, 0);
        if (scene.getObject(plane_id)) |obj| {
            obj.transform.position = .{ 0.0, 0.0, 0.0 };
            scene.updateBounds(obj);
        }
        engine.logger.info("Added Ground to scene with object ID: {d}", .{plane_id});
    }

    engine.logger.info("Test scene initialized with {d} objects", .{scene.getObjectCount()});

    // Add additional lights with different colors for testing color blending
    if (renderer.getSystem()) |render_sys| {
        if (render_sys.light_system) |*light_sys| {
            // Add a red point light on the left
            _ = light_sys.createLight(.{
                .type = .point,
                .position = .{ -3.0, 2.0, 2.0 },
                .color = .{ 1.0, 0.0, 0.0 }, // Red
                .intensity = 1.5,
                .range = 8.0,
            }) catch |err| {
                engine.logger.warn("Failed to create red point light: {}", .{err});
            };

            // Add a green point light on the right
            _ = light_sys.createLight(.{
                .type = .point,
                .position = .{ 3.0, 2.0, 2.0 },
                .color = .{ 0.0, 1.0, 0.0 }, // Green
                .intensity = 1.5,
                .range = 8.0,
            }) catch |err| {
                engine.logger.warn("Failed to create green point light: {}", .{err});
            };

            // Add a blue point light in the back
            _ = light_sys.createLight(.{
                .type = .point,
                .position = .{ 0.0, 2.0, -3.0 },
                .color = .{ 0.0, 0.3, 1.0 }, // Blue
                .intensity = 1.5,
                .range = 8.0,
            }) catch |err| {
                engine.logger.warn("Failed to create blue point light: {}", .{err});
            };

            // Add a warm point light above
            _ = light_sys.createLight(.{
                .type = .point,
                .position = .{ 0.0, 4.0, 0.0 },
                .color = .{ 1.0, 0.8, 0.4 }, // Warm white/orange
                .intensity = 1.2,
                .range = 10.0,
            }) catch |err| {
                engine.logger.warn("Failed to create warm point light: {}", .{err});
            };

            engine.logger.info("Added {d} colored point lights to the scene", .{4});
        }
    }
}

fn render(game: *Game, dt: f64) bool {
    _ = dt;

    const state: *GameState = @ptrCast(@alignCast(game.state));
    if (!state.scene_initialized) return true;

    // Get renderer system
    const render_sys = renderer.getSystem() orelse return true;

    // Bind material for rendering.
    // Note: Material is ALSO bound in update() before beginFrame for Vulkan descriptor sets.
    // Metal requires binding during render (when encoder is active), Vulkan needs it before frame.
    // Both backends handle redundant calls gracefully.
    material.bind(state.test_material_id);

    // Get editor scene and render all objects
    const scene = editor.EditorSystem.getEditorScene() orelse return true;

    for (scene.getAllObjects()) |*obj| {
        if (!obj.is_visible) continue;

        // Get geometry
        const geo = geometry.getGeometry(obj.getGeometryId()) orelse continue;

        // Calculate model matrix from transform
        const model = obj.transform.toModelMatrix();

        // Draw the geometry
        render_sys.drawGeometry(geo, &model);
    }

    return true;
}

fn onResize(_: *Game, _: u32, _: u32) void {
    engine.logger.info("Window resized", .{});
}

fn shutdown(game: *Game) void {
    _ = game;
    engine.logger.info("Game shutting down...", .{});
}

pub const callbacks = .{
    .initialize = init,
    .update = update,
    .render = render,
    .onResize = onResize,
    .shutdown = shutdown,
};
