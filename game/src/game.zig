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

fn initializeTestScene(state: *GameState) void {
    engine.logger.info("Initializing test scene with geometries...", .{});

    // Load a material for the test objects
    if (material.acquire("cobblestone")) |mat| {
        state.test_material_id = mat.id;
        engine.logger.info("Loaded cobblestone material with ID: {d}", .{mat.id});
    } else {
        engine.logger.warn("Failed to load cobblestone material, using default", .{});
        // Get default material ID
        if (material.getDefaultMaterial()) |default_mat| {
            state.test_material_id = default_mat.id;
        }
    }

    // Generate procedural geometries using standalone functions
    if (geometry.generateCube(.{
        .name = "test_cube",
        .width = 1.0,
        .height = 1.0,
        .depth = 1.0,
        .color = .{ 0.8, 0.2, 0.2 }, // Red-ish
    })) |cube| {
        state.cube_geo = cube.id;
        if (cube.id == 0) {
            engine.logger.err("CRITICAL: Cube geometry has invalid ID 0!", .{});
        } else {
            engine.logger.info("Created cube geometry with ID: {d}", .{cube.id});
        }
    } else {
        engine.logger.err("Failed to create cube geometry", .{});
    }

    if (geometry.generateSphere(.{
        .name = "test_sphere",
        .radius = 0.5,
        .rings = 16,
        .sectors = 32,
        .color = .{ 0.2, 0.8, 0.2 }, // Green-ish
    })) |sphere| {
        state.sphere_geo = sphere.id;
        if (sphere.id == 0) {
            engine.logger.err("CRITICAL: Sphere geometry has invalid ID 0!", .{});
        } else {
            engine.logger.info("Created sphere geometry with ID: {d}", .{sphere.id});
        }
    } else {
        engine.logger.err("Failed to create sphere geometry", .{});
    }

    if (geometry.generatePlane(.{
        .name = "ground_plane",
        .width = 10.0,
        .height = 10.0,
        .color = .{ 0.5, 0.5, 0.5 }, // Gray
    })) |plane| {
        state.plane_geo = plane.id;
        if (plane.id == 0) {
            engine.logger.err("CRITICAL: Plane geometry has invalid ID 0!", .{});
        } else {
            engine.logger.info("Created plane geometry with ID: {d}", .{plane.id});
        }
    } else {
        engine.logger.err("Failed to create plane geometry", .{});
    }

    // Add objects to editor scene
    const scene = editor.EditorSystem.getEditorScene() orelse {
        engine.logger.err("No editor scene available!", .{});
        return;
    };

    // Add cube
    if (state.cube_geo != 0) {
        const cube_id = scene.addObject("Cube", state.cube_geo, 0);
        if (scene.getObject(cube_id)) |obj| {
            obj.transform.position = .{ -2.0, 0.5, 0.0 };
            scene.updateBounds(obj);
        }
        engine.logger.info("Added Cube to scene with object ID: {d}", .{cube_id});
    }

    // Add sphere
    if (state.sphere_geo != 0) {
        const sphere_id = scene.addObject("Sphere", state.sphere_geo, 0);
        if (scene.getObject(sphere_id)) |obj| {
            obj.transform.position = .{ 2.0, 0.5, 0.0 };
            scene.updateBounds(obj);
        }
        engine.logger.info("Added Sphere to scene with object ID: {d}", .{sphere_id});
    }

    // Add ground plane (already horizontal on XZ plane, no rotation needed)
    if (state.plane_geo != 0) {
        const plane_id = scene.addObject("Ground", state.plane_geo, 0);
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
        const geo = geometry.getGeometry(obj.geometry_id) orelse continue;

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
