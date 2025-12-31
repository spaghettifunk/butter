const std = @import("std");
const build_options = @import("build_options");

const c = @cImport({
    @cInclude("GLFW/glfw3.h");
});

// Conditional ImGui GLFW bindings - only include when ImGui is enabled
const imgui_glfw = if (build_options.enable_imgui) @cImport({
    @cInclude("dcimgui_impl_glfw.h");
}) else struct {};

const input = @import("../systems/input.zig");
const event = @import("../systems/event.zig");
const logger = @import("../core/logging.zig");
const context_mod = @import("../context.zig");

// Zig-friendly wrapper types
pub const Window = c.GLFWwindow;
pub const GLFWwindow = c.GLFWwindow;

pub const PlatformState = struct {
    startTime: f64,
    window: ?*c.GLFWwindow,
};

// GLFW Callbacks
fn keyCallback(window: ?*c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    // Forward to engine input system
    input.processKey(key, scancode, action, mods);

    // Forward to ImGui (if enabled)
    // Note: @ptrCast is needed because separate @cImport creates distinct opaque types
    if (build_options.enable_imgui) {
        imgui_glfw.cImGui_ImplGlfw_KeyCallback(@ptrCast(window), key, scancode, action, mods);
    }
}

fn mouseButtonCallback(window: ?*c.GLFWwindow, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
    // Forward to engine input system
    input.processButton(button, action, mods);

    // Forward to ImGui (if enabled)
    if (build_options.enable_imgui) {
        imgui_glfw.cImGui_ImplGlfw_MouseButtonCallback(@ptrCast(window), button, action, mods);
    }
}

fn cursorPosCallback(window: ?*c.GLFWwindow, xpos: f64, ypos: f64) callconv(.c) void {
    // Forward to engine input system
    input.processMouseMove(xpos, ypos);

    // Forward to ImGui (if enabled)
    if (build_options.enable_imgui) {
        imgui_glfw.cImGui_ImplGlfw_CursorPosCallback(@ptrCast(window), xpos, ypos);
    }
}

fn scrollCallback(window: ?*c.GLFWwindow, xoffset: f64, yoffset: f64) callconv(.c) void {
    // Forward to engine input system
    input.processMouseWheel(xoffset, yoffset);

    // Forward to ImGui (if enabled)
    if (build_options.enable_imgui) {
        imgui_glfw.cImGui_ImplGlfw_ScrollCallback(@ptrCast(window), xoffset, yoffset);
    }
}

fn framebufferSizeCallback(_: ?*c.GLFWwindow, width: c_int, height: c_int) callconv(.c) void {
    var ctx = std.mem.zeroes(event.EventContext);
    ctx.u16[0] = @intCast(@max(0, width));
    ctx.u16[1] = @intCast(@max(0, height));
    _ = event.fire(.resized, null, ctx);
}

pub fn startup(
    state: *PlatformState,
    app_name: [:0]const u8,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) bool {
    if (c.glfwInit() == 0) {
        return false;
    }

    c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_TRUE);
    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);

    const window = c.glfwCreateWindow(width, height, app_name.ptr, null, null);
    if (window == null) {
        logger.fatal("Failed to create a window", .{});
        c.glfwTerminate();
        return false;
    }

    // Set up input callbacks
    _ = c.glfwSetKeyCallback(window, keyCallback);
    _ = c.glfwSetMouseButtonCallback(window, mouseButtonCallback);
    _ = c.glfwSetCursorPosCallback(window, cursorPosCallback);
    _ = c.glfwSetScrollCallback(window, scrollCallback);
    _ = c.glfwSetFramebufferSizeCallback(window, framebufferSizeCallback);

    _ = c.glfwSetWindowPos(window, x, y);
    _ = c.glfwShowWindow(window);

    state.startTime = c.glfwGetTime();
    state.window = window;

    // Register window with shared context (as opaque pointer)
    context_mod.get().platform_window = window;

    return true;
}

pub fn shutdown(state: *PlatformState) void {
    if (state.window) |win| {
        c.glfwDestroyWindow(win);
        c.glfwTerminate();
    }
}

pub fn pumpMessages(state: *PlatformState) bool {
    if (state.window) |win| {
        if (c.glfwWindowShouldClose(win) != 0) {
            return false;
        }
        c.glfwPollEvents();
        return true;
    }
    return false;
}

pub fn getAbsoluteTime() f64 {
    return c.glfwGetTime();
}
