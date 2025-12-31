const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_editor = b.option(bool, "enable_editor", "Enable editor features") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "enable_editor", enable_editor);
    options.addOption(bool, "enable_imgui", enable_editor); // Assume imgui if editor checks out

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/entry.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("build_options", options.createModule());

    const lib = b.addLibrary(.{
        .name = "butter_game",
        .root_module = root_module,
    });

    b.installArtifact(lib);
}
