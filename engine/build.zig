const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Custom step for shaders
    const compile_step = b.step("compile-shaders", "Compile GLSL/HLSL to SPIR-V and produce MSL via spirv-cross");
    compile_step.makeFn = compileShaders;

    const glfw_zig = b.dependency("glfw_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const vulkan_zig = b.dependency("vulkan_zig", .{
        .target = target,
        .optimize = optimize,
    });

    const game_dep = b.dependency("game", .{
        .target = target,
        .optimize = optimize,
        .enable_editor = false,
    });

    const game_editor_dep = b.dependency("game", .{
        .target = target,
        .optimize = optimize,
        .enable_editor = true,
    });

    // =========================================================================
    // EDITOR EXECUTABLE (full features: ImGui, validation, editor UI)
    // =========================================================================
    const editor_exe = buildExecutable(b, .{
        .name = "butter_editor",
        .root_source = "src/editor_main.zig",
        .target = target,
        .optimize = optimize,
        .enable_editor = true,
        .enable_imgui = true,
        .enable_validation = optimize == .Debug,
        .glfw = glfw_zig,
        .vulkan = vulkan_zig,
        .game = game_editor_dep,
        .compile_shaders = compile_step,
    });

    // Add ImGui ONLY to editor
    addImgui(b, editor_exe, glfw_zig.artifact("glfw"), vulkan_zig.artifact("vulkan"));

    // todo: remove me
    editor_exe.linker_allow_shlib_undefined = true;

    const run_editor = b.addRunArtifact(editor_exe);
    run_editor.step.dependOn(b.getInstallStep());

    // =========================================================================
    // RUNTIME EXECUTABLE (minimal: no ImGui, no validation, no editor)
    // =========================================================================
    const runtime_exe = buildExecutable(b, .{
        .name = "butter_runtime",
        .root_source = "src/runtime_main.zig",
        .target = target,
        .optimize = optimize,
        .enable_editor = false,
        .enable_imgui = false,
        .enable_validation = false,
        .glfw = glfw_zig,
        .vulkan = vulkan_zig,
        .game = game_dep,
        .compile_shaders = compile_step,
    });

    const run_runtime = b.addRunArtifact(runtime_exe);
    run_runtime.step.dependOn(b.getInstallStep());

    // =========================================================================
    // BUILD STEPS
    // =========================================================================

    // Default "run" runs the editor
    const run_step = b.step("run", "Run the editor (default)");
    run_step.dependOn(&run_editor.step);

    // "run-runtime" runs the runtime
    const run_runtime_step = b.step("run-runtime", "Run the runtime executable");
    run_runtime_step.dependOn(&run_runtime.step);
}

const BuildConfig = struct {
    name: []const u8,
    root_source: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    enable_editor: bool,
    enable_imgui: bool,
    enable_validation: bool,
    glfw: *std.Build.Dependency,
    vulkan: *std.Build.Dependency,
    game: *std.Build.Dependency,
    compile_shaders: *std.Build.Step,
};

fn buildExecutable(b: *std.Build, config: BuildConfig) *std.Build.Step.Compile {
    // Create build options module
    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_editor", config.enable_editor);
    build_options.addOption(bool, "enable_imgui", config.enable_imgui);
    build_options.addOption(bool, "enable_validation", config.enable_validation);

    const root_module = b.createModule(.{
        .root_source_file = b.path(config.root_source),
        .target = config.target,
        .optimize = config.optimize,
    });

    // Add build options as an import
    root_module.addImport("build_options", build_options.createModule());

    // Add stb_image include path for cImport
    root_module.addIncludePath(b.path("vendor/image"));

    // Add ImGui include paths only if imgui is enabled
    if (config.enable_imgui) {
        root_module.addIncludePath(b.path("vendor/imgui"));
        root_module.addIncludePath(b.path("vendor/imgui/backends"));
        root_module.addIncludePath(b.path("vendor/dcimgui"));
        root_module.addIncludePath(b.path("vendor/dcimgui/backends"));
    }

    const exe = b.addExecutable(.{
        .name = config.name,
        .root_module = root_module,
    });

    // Link GLFW
    const glfw_artifact = config.glfw.artifact("glfw");
    exe.root_module.addImport("glfw", glfw_artifact.root_module);
    exe.linkLibrary(glfw_artifact);

    // Link Vulkan
    const vulkan_artifact = config.vulkan.artifact("vulkan");
    exe.linkLibrary(vulkan_artifact);

    // Create engine module for game library with same build options
    const engine_module = b.createModule(.{
        .root_source_file = b.path("src/engine_lib.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });
    engine_module.addImport("build_options", build_options.createModule());
    engine_module.linkLibrary(vulkan_artifact);
    engine_module.addIncludePath(b.path("vendor/image"));
    if (config.enable_imgui) {
        engine_module.addIncludePath(b.path("vendor/imgui"));
        engine_module.addIncludePath(b.path("vendor/imgui/backends"));
        engine_module.addIncludePath(b.path("vendor/dcimgui"));
        engine_module.addIncludePath(b.path("vendor/dcimgui/backends"));
    }

    // Link game library
    const game_lib = config.game.artifact("butter_game");
    game_lib.root_module.addImport("engine", engine_module);
    exe.linkLibrary(game_lib);

    exe.step.dependOn(config.compile_shaders);

    // Link against system Vulkan loader (MoltenVK on macOS)
    exe.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
    exe.linkSystemLibrary("vulkan");

    // Link against Metal framework on macOS
    exe.linkFramework("Metal");
    exe.linkFramework("QuartzCore");

    // Add stb_image
    exe.addCSourceFiles(.{ .files = &[_][]const u8{"vendor/image/stb_image.c"} });

    // Link C++ standard library (needed even without ImGui for some dependencies)
    exe.linkLibCpp();

    b.installArtifact(exe);
    return exe;
}

fn compileShaders(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
    _ = options;
    const b = step.owner;
    const gpa = b.allocator;
    const cwd = std.fs.cwd();

    // Where compiled shaders will land
    const shaders_out = "build/shaders";

    // ensure output dir exists
    cwd.makePath(shaders_out) catch |err| {
        std.debug.print("Failed to create output directory {s}: {s}\n", .{ shaders_out, @errorName(err) });
        return err;
    };

    // iterate source shaders dir
    var shaders_dir = cwd.openDir("../assets/shaders", .{ .iterate = true }) catch |err| {
        std.debug.print("Warning: Could not open 'shaders' directory: {s}\n", .{@errorName(err)});
        return;
    };
    defer shaders_dir.close();

    var iter = shaders_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file) {
            const name = entry.name;
            // naive filter: ends with .vert/.frag/.comp (expand as needed)
            if (std.mem.endsWith(u8, name, ".vert.glsl") or
                std.mem.endsWith(u8, name, ".frag.glsl") or
                std.mem.endsWith(u8, name, ".comp.glsl") or
                std.mem.endsWith(u8, name, ".vert.hlsl") or
                std.mem.endsWith(u8, name, ".frag.hlsl"))
            {
                const src_path = try std.fs.path.join(gpa, &[_][]const u8{ "../assets/shaders", name });
                defer gpa.free(src_path);

                // remove extension for output base name
                var base_name = name;
                if (std.mem.endsWith(u8, name, ".glsl")) {
                    base_name = name[0 .. name.len - 5];
                } else if (std.mem.endsWith(u8, name, ".hlsl")) {
                    base_name = name[0 .. name.len - 5];
                }

                const spv_out = try std.fs.path.join(gpa, &[_][]const u8{ shaders_out, b.fmt("{s}.spv", .{base_name}) });
                defer gpa.free(spv_out);

                // 1) compile to SPIR-V with glslangValidator
                const glslang_cmd = &[_][]const u8{ "glslangValidator", "-V", src_path, "-o", spv_out };

                var child = std.process.Child.init(glslang_cmd, gpa);
                child.stdin_behavior = .Ignore;
                child.stdout_behavior = .Inherit;
                child.stderr_behavior = .Inherit;

                const term = try child.spawnAndWait();
                if (term != .Exited or term.Exited != 0) {
                    std.debug.print("glslangValidator failed for {s}\n", .{src_path});
                    return error.CompileStepFailed;
                }

                // 2) optimize (optional) and run spirv-cross to produce MSL for macOS
                const msl_out = try std.fs.path.join(gpa, &[_][]const u8{ shaders_out, b.fmt("{s}.msl", .{base_name}) });
                defer gpa.free(msl_out);

                // Use MSL 2.0 (version 20000) to support texture arrays
                const spirv_cmd = &[_][]const u8{ "spirv-cross", spv_out, "--msl", "--msl-version", "20000", "--output", msl_out };

                var child_spirv = std.process.Child.init(spirv_cmd, gpa);
                child_spirv.stdin_behavior = .Ignore;
                child_spirv.stdout_behavior = .Inherit;
                child_spirv.stderr_behavior = .Inherit;

                const term_spirv = try child_spirv.spawnAndWait();
                if (term_spirv != .Exited or term_spirv.Exited != 0) {
                    std.debug.print("spirv-cross failed for {s}\n", .{spv_out});
                    return error.CompileStepFailed;
                }

                std.debug.print("Compiled shader {s} -> {s} + {s}\n", .{ src_path, spv_out, msl_out });
            }
        }
    }
}

/// Adds ImGui C++ source files and dependencies to the executable
fn addImgui(b: *std.Build, exe: *std.Build.Step.Compile, glfw_artifact: *std.Build.Step.Compile, vulkan_artifact: *std.Build.Step.Compile) void {
    // C++ flags for ImGui compilation
    const cpp_flags = &[_][]const u8{
        "-std=c++11",
        "-fno-exceptions",
        "-fno-rtti",
    };

    // Objective-C++ flags for Metal backend
    const objcpp_flags = &[_][]const u8{
        "-std=c++11",
        "-fno-exceptions",
        "-fno-rtti",
        "-fobjc-arc",
    };

    // Add include paths for ImGui compilation
    exe.addIncludePath(b.path("vendor/imgui"));
    exe.addIncludePath(b.path("vendor/imgui/backends"));
    exe.addIncludePath(b.path("vendor/dcimgui"));
    exe.addIncludePath(b.path("vendor/dcimgui/backends"));

    // Add GLFW include paths from the glfw artifact for imgui_impl_glfw.cpp
    for (glfw_artifact.root_module.include_dirs.items) |include_dir| {
        switch (include_dir) {
            .path => |path| exe.addIncludePath(path),
            .path_system => |path| exe.addSystemIncludePath(path),
            else => {},
        }
    }

    // Add Vulkan include paths from the vulkan artifact for imgui_impl_vulkan.cpp
    for (vulkan_artifact.root_module.include_dirs.items) |include_dir| {
        switch (include_dir) {
            .path => |path| exe.addIncludePath(path),
            .path_system => |path| exe.addSystemIncludePath(path),
            else => {},
        }
    }

    // Add ImGui core C++ source files
    exe.addCSourceFiles(.{
        .files = &[_][]const u8{
            "vendor/imgui/imgui.cpp",
            "vendor/imgui/imgui_widgets.cpp",
            "vendor/imgui/imgui_tables.cpp",
            "vendor/imgui/imgui_draw.cpp",
            "vendor/imgui/imgui_demo.cpp",
        },
        .flags = cpp_flags,
    });

    // Add dcimgui C bindings
    exe.addCSourceFiles(.{
        .files = &[_][]const u8{
            "vendor/dcimgui/dcimgui.cpp",
        },
        .flags = cpp_flags,
    });

    // Add ImGui GLFW backend (C++ implementation)
    exe.addCSourceFiles(.{
        .files = &[_][]const u8{
            "vendor/imgui/backends/imgui_impl_glfw.cpp",
        },
        .flags = cpp_flags,
    });

    // Add dcimgui GLFW backend bindings
    exe.addCSourceFiles(.{
        .files = &[_][]const u8{
            "vendor/dcimgui/backends/dcimgui_impl_glfw.cpp",
        },
        .flags = cpp_flags,
    });

    // Add ImGui Metal backend (Objective-C++)
    exe.addCSourceFiles(.{
        .files = &[_][]const u8{
            "vendor/imgui/backends/imgui_impl_metal.mm",
            "vendor/imgui/backends/cimgui_impl_metal.mm",
        },
        .flags = objcpp_flags,
    });

    // Add ImGui Vulkan backend (C++)
    exe.addCSourceFiles(.{
        .files = &[_][]const u8{
            "vendor/imgui/backends/imgui_impl_vulkan.cpp",
        },
        .flags = cpp_flags,
    });

    // Add dcimgui Vulkan backend bindings
    exe.addCSourceFiles(.{
        .files = &[_][]const u8{
            "vendor/dcimgui/backends/dcimgui_impl_vulkan.cpp",
        },
        .flags = cpp_flags,
    });

    // Link C++ standard library
    exe.linkLibCpp();

    // Link additional frameworks needed by ImGui backends
    exe.linkFramework("Foundation");
    exe.linkFramework("AppKit");
}
