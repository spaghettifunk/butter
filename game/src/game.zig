const engine = @import("engine");
const Game = engine.Game;
const input = engine.input;
const renderer = engine.renderer;
const material = engine.material;
const math = engine.math;
const editor = engine.editor;
const std = @import("std");

pub const GameState = struct {
    deltaTime: f64 = 0,
    total_time: f64 = 0,

    // Mesh asset IDs for test objects
    cube_mesh: u32 = 0,
    sphere_mesh: u32 = 0,
    plane_mesh: u32 = 0,

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

    return true;
}

// Callback for async texture loading test
fn onTextureLoaded(tex_handle: engine.resource_handle.TextureHandle) void {
    engine.logger.info("✅ ASYNC TEXTURE LOADED: ID = {d}, generation = {d}", .{ tex_handle.id, tex_handle.generation });
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

    const ctx = @import("engine").context;
    const resource_mgr = ctx.get().resource_manager orelse {
        engine.logger.err("Resource Manager not available!", .{});
        return;
    };

    // Load skybox cubemap
    if (ctx.get().environment) |environment| {
        const skybox_faces = [6][]const u8{
            "../assets/skybox/daylight/right.jpg", // +X (right)
            "../assets/skybox/daylight/left.jpg", // -X (left)
            "../assets/skybox/daylight/top.jpg", // +Y (top)
            "../assets/skybox/daylight/bottom.jpg", // -Y (bottom)
            "../assets/skybox/daylight/front.jpg", // +Z (front)
            "../assets/skybox/daylight/back.jpg", // -Z (back)
        };

        if (environment.loadSkyboxCubemap(skybox_faces)) {
            engine.logger.info("✅ Skybox loaded successfully!", .{});
        } else {
            engine.logger.warn("Failed to load skybox cubemap", .{});
        }
    } else {
        engine.logger.warn("Environment system not available for skybox loading", .{});
    }

    // Load materials using Resource Manager (NEW API)
    const cobblestone_handle = resource_mgr.loadMaterial("cobblestone") catch |err| {
        engine.logger.warn("Failed to load cobblestone material through ResourceManager: {}", .{err});
        return;
    };
    engine.logger.info("Loaded cobblestone material through ResourceManager with ID: {d}", .{cobblestone_handle.id});

    const colorful_handle = resource_mgr.loadMaterial("colorful") catch |err| {
        engine.logger.warn("Failed to load colorful material through ResourceManager: {}", .{err});
        return;
    };
    engine.logger.info("Loaded colorful material through ResourceManager with ID: {d}", .{colorful_handle.id});

    // Load rock PBR material for testing
    const rock_handle = resource_mgr.loadMaterial("paving") catch |err| {
        engine.logger.warn("Failed to load rock material through ResourceManager: {}", .{err});
        return;
    };
    engine.logger.info("Loaded rock PBR material through ResourceManager with ID: {d}", .{rock_handle.id});

    // Generate procedural meshes using Resource Manager
    const cube_handle = resource_mgr.loadMeshCube(.{
        .name = "test_cube",
        .width = 1.0,
        .height = 1.0,
        .depth = 1.0,
        .color = .{ 1.0, 1.0, 1.0 },
    }) catch |err| {
        engine.logger.err("Failed to create cube mesh through ResourceManager: {}", .{err});
        return;
    };
    state.cube_mesh = cube_handle.id;
    engine.logger.info("Created cube mesh through ResourceManager with ID: {d}", .{cube_handle.id});

    const sphere_handle = resource_mgr.loadMeshSphere(.{
        .name = "test_sphere",
        .radius = 0.5,
        .rings = 16,
        .sectors = 32,
        .color = .{ 1.0, 1.0, 1.0 },
    }) catch |err| {
        engine.logger.err("Failed to create sphere mesh through ResourceManager: {}", .{err});
        return;
    };
    state.sphere_mesh = sphere_handle.id;
    engine.logger.info("Created sphere mesh through ResourceManager with ID: {d}", .{sphere_handle.id});

    const plane_handle = resource_mgr.loadMeshPlane(.{
        .name = "ground_plane",
        .width = 10.0,
        .height = 10.0,
        .color = .{ 1.0, 1.0, 1.0 },
    }) catch |err| {
        engine.logger.err("Failed to create plane mesh through ResourceManager: {}", .{err});
        return;
    };
    state.plane_mesh = plane_handle.id;
    engine.logger.info("Created plane mesh through ResourceManager with ID: {d}", .{plane_handle.id});

    // Add objects to editor scene
    const scene = editor.EditorSystem.getEditorScene() orelse {
        engine.logger.err("No editor scene available!", .{});
        return;
    };

    // Add cube with cobblestone material
    if (state.cube_mesh != 0) {
        const cube_id = scene.addObjectById("Cube", state.cube_mesh, cobblestone_handle.id);
        if (scene.getObject(cube_id)) |obj| {
            obj.transform.position = .{ -2.0, 0.5, 0.0 };
            scene.updateBounds(obj);
        }
        engine.logger.info("Added Cube to scene with object ID: {d}", .{cube_id});
    }

    // Add sphere with cobblestone material
    if (state.sphere_mesh != 0) {
        const sphere_id = scene.addObjectById("Sphere", state.sphere_mesh, cobblestone_handle.id);
        if (scene.getObject(sphere_id)) |obj| {
            obj.transform.position = .{ 2.0, 0.5, 0.0 };
            scene.updateBounds(obj);
        }
        engine.logger.info("Added Sphere to scene with object ID: {d}", .{sphere_id});
    }

    // Add ground plane with rock PBR material
    if (state.plane_mesh != 0) {
        const plane_id = scene.addObjectById("Ground", state.plane_mesh, rock_handle.id);
        if (scene.getObject(plane_id)) |obj| {
            obj.transform.position = .{ 0.0, -0.5, 0.0 }; // Below other objects so camera can see it from above
            scene.updateBounds(obj);
        }
        engine.logger.info("Added Ground plane to scene with rock PBR material (object ID: {d})", .{plane_id});
    }

    // Create cone mesh with colorful material
    const cone_handle = resource_mgr.loadMeshCone(.{
        .name = "test_cone",
        .radius = 0.5,
        .height = 1.0,
        .segments = 32,
        .color = .{ 1.0, 1.0, 1.0 },
    }) catch |err| {
        engine.logger.err("Failed to create cone mesh through ResourceManager: {}", .{err});
        return;
    };
    const cone_id = scene.addObjectById("Cone", cone_handle.id, colorful_handle.id);
    if (scene.getObject(cone_id)) |obj| {
        obj.transform.position = .{ -4.0, 0.5, -2.0 };
        scene.updateBounds(obj);
    }
    engine.logger.info("Added Cone to scene with object ID: {d}", .{cone_id});

    // Create cylinder mesh with colorful material
    const cylinder_handle = resource_mgr.loadMeshCylinder(.{
        .name = "test_cylinder",
        .radius = 0.4,
        .height = 1.2,
        .segments = 32,
        .color = .{ 1.0, 1.0, 1.0 },
    }) catch |err| {
        engine.logger.err("Failed to create cylinder mesh through ResourceManager: {}", .{err});
        return;
    };
    const cylinder_id = scene.addObjectById("Cylinder", cylinder_handle.id, colorful_handle.id);
    if (scene.getObject(cylinder_id)) |obj| {
        obj.transform.position = .{ 4.0, 0.6, -2.0 };
        scene.updateBounds(obj);
    }
    engine.logger.info("Added Cylinder to scene with object ID: {d}", .{cylinder_id});

    engine.logger.info("Test scene initialized with {d} objects", .{scene.getObjectCount()});

    // Add additional lights with different colors for testing color blending
    if (renderer.getSystem()) |render_sys| {
        if (render_sys.light_system) |*light_sys| {
            // Add a red point light on the left
            _ = light_sys.createLight(.{
                .type = .point,
                .position = .{ -3.0, 2.0, 2.0 },
                .color = .{ 1.0, 1.0, 1.0 }, // Red
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

    // Get editor scene and render all objects
    const scene = editor.EditorSystem.getEditorScene() orelse return true;

    // Get mesh asset system
    const ctx = @import("engine").context;
    const mesh_sys = ctx.get().mesh_asset orelse return true;

    for (scene.getAllObjects()) |*obj| {
        if (!obj.is_visible) continue;

        // Get mesh asset
        const mesh = mesh_sys.getMesh(obj.getMeshAssetId()) orelse continue;

        // Get material for this object (per-object materials now supported!)
        const obj_material = if (obj.getMaterialId() != 0)
            material.getMaterial(obj.getMaterialId())
        else
            null;

        // Calculate model matrix from transform
        const model = obj.transform.toModelMatrix();

        // Draw the mesh asset with its material
        render_sys.drawMeshAsset(mesh, &model, obj_material);
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
