const std = @import("std");
const context = @import("../context.zig");
const event = @import("event.zig");
const logger = @import("../core/logging.zig");

// GLFW constants - hardcoded to avoid @cImport issues across module boundaries
// These values are stable and defined in glfw3.h
const GLFW_RELEASE = 0;
const GLFW_PRESS = 1;
const GLFW_REPEAT = 2;

/// Mouse buttons - maps to GLFW mouse buttons
pub const MouseButton = enum(u8) {
    left = 0,
    right = 1,
    middle = 2,
    button_4 = 3,
    button_5 = 4,
    button_6 = 5,
    button_7 = 6,
    button_8 = 7,

    pub const max_buttons = 8;
};

/// Keyboard keys - uses GLFW key codes directly
/// Values from glfw3.h - these are stable across GLFW versions
pub const Key = enum(c_int) {
    // Printable keys
    space = 32,
    apostrophe = 39,
    comma = 44,
    minus = 45,
    period = 46,
    slash = 47,
    @"0" = 48,
    @"1" = 49,
    @"2" = 50,
    @"3" = 51,
    @"4" = 52,
    @"5" = 53,
    @"6" = 54,
    @"7" = 55,
    @"8" = 56,
    @"9" = 57,
    semicolon = 59,
    equal = 61,
    a = 65,
    b = 66,
    c = 67,
    d = 68,
    e = 69,
    f = 70,
    g = 71,
    h = 72,
    i = 73,
    j = 74,
    k = 75,
    l = 76,
    m = 77,
    n = 78,
    o = 79,
    p = 80,
    q = 81,
    r = 82,
    s = 83,
    t = 84,
    u = 85,
    v = 86,
    w = 87,
    x = 88,
    y = 89,
    z = 90,
    left_bracket = 91,
    backslash = 92,
    right_bracket = 93,
    grave_accent = 96,
    world_1 = 161,
    world_2 = 162,

    // Function keys
    escape = 256,
    enter = 257,
    tab = 258,
    backspace = 259,
    insert = 260,
    delete = 261,
    right = 262,
    left = 263,
    down = 264,
    up = 265,
    page_up = 266,
    page_down = 267,
    home = 268,
    end = 269,
    caps_lock = 280,
    scroll_lock = 281,
    num_lock = 282,
    print_screen = 283,
    pause = 284,
    f1 = 290,
    f2 = 291,
    f3 = 292,
    f4 = 293,
    f5 = 294,
    f6 = 295,
    f7 = 296,
    f8 = 297,
    f9 = 298,
    f10 = 299,
    f11 = 300,
    f12 = 301,
    f13 = 302,
    f14 = 303,
    f15 = 304,
    f16 = 305,
    f17 = 306,
    f18 = 307,
    f19 = 308,
    f20 = 309,
    f21 = 310,
    f22 = 311,
    f23 = 312,
    f24 = 313,
    f25 = 314,
    kp_0 = 320,
    kp_1 = 321,
    kp_2 = 322,
    kp_3 = 323,
    kp_4 = 324,
    kp_5 = 325,
    kp_6 = 326,
    kp_7 = 327,
    kp_8 = 328,
    kp_9 = 329,
    kp_decimal = 330,
    kp_divide = 331,
    kp_multiply = 332,
    kp_subtract = 333,
    kp_add = 334,
    kp_enter = 335,
    kp_equal = 336,
    left_shift = 340,
    left_control = 341,
    left_alt = 342,
    left_super = 343,
    right_shift = 344,
    right_control = 345,
    right_alt = 346,
    right_super = 347,
    menu = 348,

    // GLFW_KEY_LAST is 348
    pub const max_keys = 349;

    /// Convert a raw GLFW key code to a Key enum
    pub fn fromGlfw(glfw_key: c_int) ?Key {
        return std.meta.intToEnum(Key, glfw_key) catch null;
    }
};

/// Modifier key flags - matches GLFW modifier bits
pub const Mods = packed struct(c_int) {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _padding: u26 = 0,

    pub fn fromGlfw(mods: c_int) Mods {
        return @bitCast(mods);
    }
};

const KeyboardState = struct {
    keys: [Key.max_keys]bool = [_]bool{false} ** Key.max_keys,
};

const MouseState = struct {
    x: f64 = 0,
    y: f64 = 0,
    buttons: [MouseButton.max_buttons]bool = [_]bool{false} ** MouseButton.max_buttons,
};

var instance: InputSystem = undefined;

pub const InputSystem = struct {
    keyboard_current: KeyboardState = .{},
    keyboard_previous: KeyboardState = .{},
    mouse_current: MouseState = .{},
    mouse_previous: MouseState = .{},

    /// Initialize the input system
    pub fn initialize() bool {
        instance = InputSystem{};
        context.get().input = &instance;
        logger.info("Input system initialized.", .{});
        return true;
    }

    /// Shutdown the input system
    pub fn shutdown() void {
        context.get().input = null;
        logger.info("Input system shutdown.", .{});
    }

    /// Update input state - call once per frame after processing events
    pub fn update(_: f64) void {
        const sys = getSystem() orelse return;

        // Copy current states to previous states
        sys.keyboard_previous = sys.keyboard_current;
        sys.mouse_previous = sys.mouse_current;
    }
};

/// Get the input system instance
pub fn getSystem() ?*InputSystem {
    return context.get().input;
}

// -----------------------------------------------------------------------------
// Keyboard Input Processing
// -----------------------------------------------------------------------------

/// Process a key event from GLFW
pub fn processKey(glfw_key: c_int, _: c_int, action: c_int, mods: c_int) void {
    const sys = getSystem() orelse return;

    // Ignore unknown keys
    if (glfw_key < 0 or glfw_key >= Key.max_keys) return;

    const key_index: usize = @intCast(glfw_key);
    const pressed = (action == GLFW_PRESS or action == GLFW_REPEAT);

    // Only process if state changed (ignore GLFW_REPEAT for state tracking)
    if (action != GLFW_REPEAT and sys.keyboard_current.keys[key_index] != pressed) {
        sys.keyboard_current.keys[key_index] = pressed;

        // Fire event
        var ctx: event.EventContext = undefined;
        ctx.u16[0] = @intCast(glfw_key);
        ctx.u16[1] = @bitCast(@as(i16, @truncate(mods)));

        const code: event.SystemEventCode = if (pressed) .key_pressed else .key_released;
        _ = event.fire(code, null, ctx);
    }
}

/// Check if a key is currently pressed
pub fn isKeyDown(key: Key) bool {
    const sys = getSystem() orelse return false;
    const idx: usize = @intCast(@intFromEnum(key));
    return sys.keyboard_current.keys[idx];
}

/// Check if a key is currently released
pub fn isKeyUp(key: Key) bool {
    return !isKeyDown(key);
}

/// Check if a key was pressed in the previous frame
pub fn wasKeyDown(key: Key) bool {
    const sys = getSystem() orelse return false;
    const idx: usize = @intCast(@intFromEnum(key));
    return sys.keyboard_previous.keys[idx];
}

/// Check if a key was released in the previous frame
pub fn wasKeyUp(key: Key) bool {
    return !wasKeyDown(key);
}

/// Check if a key was just pressed this frame (transition from up to down)
pub fn isKeyJustPressed(key: Key) bool {
    return isKeyDown(key) and wasKeyUp(key);
}

/// Check if a key was just released this frame (transition from down to up)
pub fn isKeyJustReleased(key: Key) bool {
    return isKeyUp(key) and wasKeyDown(key);
}

// -----------------------------------------------------------------------------
// Mouse Input Processing
// -----------------------------------------------------------------------------

/// Process a mouse button event from GLFW
pub fn processButton(glfw_button: c_int, action: c_int, mods: c_int) void {
    const sys = getSystem() orelse return;

    if (glfw_button < 0 or glfw_button >= MouseButton.max_buttons) return;

    const button_index: usize = @intCast(glfw_button);
    const pressed = (action == GLFW_PRESS);

    if (sys.mouse_current.buttons[button_index] != pressed) {
        sys.mouse_current.buttons[button_index] = pressed;

        // Fire event
        var ctx: event.EventContext = undefined;
        ctx.u16[0] = @intCast(glfw_button);
        ctx.u16[1] = @bitCast(@as(i16, @truncate(mods)));

        const code: event.SystemEventCode = if (pressed) .button_pressed else .button_released;
        _ = event.fire(code, null, ctx);
    }
}

/// Process mouse movement from GLFW
pub fn processMouseMove(x: f64, y: f64) void {
    const sys = getSystem() orelse return;

    if (sys.mouse_current.x != x or sys.mouse_current.y != y) {
        sys.mouse_current.x = x;
        sys.mouse_current.y = y;

        // Fire event - cast to i32 for event context
        var ctx: event.EventContext = undefined;
        ctx.i32[0] = @intFromFloat(x);
        ctx.i32[1] = @intFromFloat(y);
        _ = event.fire(.mouse_moved, null, ctx);
    }
}

/// Process mouse wheel scroll from GLFW
pub fn processMouseWheel(x_offset: f64, y_offset: f64) void {
    // Fire event
    var ctx: event.EventContext = undefined;
    // Store as float for precision
    ctx.f32[0] = @floatCast(x_offset);
    ctx.f32[1] = @floatCast(y_offset);
    _ = event.fire(.mouse_wheel, null, ctx);
}

/// Check if a mouse button is currently pressed
pub fn isButtonDown(button: MouseButton) bool {
    const sys = getSystem() orelse return false;
    return sys.mouse_current.buttons[@intFromEnum(button)];
}

/// Check if a mouse button is currently released
pub fn isButtonUp(button: MouseButton) bool {
    return !isButtonDown(button);
}

/// Check if a mouse button was pressed in the previous frame
pub fn wasButtonDown(button: MouseButton) bool {
    const sys = getSystem() orelse return false;
    return sys.mouse_previous.buttons[@intFromEnum(button)];
}

/// Check if a mouse button was released in the previous frame
pub fn wasButtonUp(button: MouseButton) bool {
    return !wasButtonDown(button);
}

/// Check if a mouse button was just pressed this frame
pub fn isButtonJustPressed(button: MouseButton) bool {
    return isButtonDown(button) and wasButtonUp(button);
}

/// Check if a mouse button was just released this frame
pub fn isButtonJustReleased(button: MouseButton) bool {
    return isButtonUp(button) and wasButtonDown(button);
}

/// Get the current mouse position
pub fn getMousePosition() struct { x: f64, y: f64 } {
    const sys = getSystem() orelse return .{ .x = 0, .y = 0 };
    return .{ .x = sys.mouse_current.x, .y = sys.mouse_current.y };
}

/// Get the previous frame's mouse position
pub fn getPreviousMousePosition() struct { x: f64, y: f64 } {
    const sys = getSystem() orelse return .{ .x = 0, .y = 0 };
    return .{ .x = sys.mouse_previous.x, .y = sys.mouse_previous.y };
}

/// Get the mouse movement delta since last frame
pub fn getMouseDelta() struct { x: f64, y: f64 } {
    const sys = getSystem() orelse return .{ .x = 0, .y = 0 };
    return .{
        .x = sys.mouse_current.x - sys.mouse_previous.x,
        .y = sys.mouse_current.y - sys.mouse_previous.y,
    };
}
