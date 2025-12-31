const std = @import("std");
const context = @import("../context.zig");
const memory = @import("memory.zig");
const logger = @import("../core/logging.zig");

const max_message_codes: usize = 16384;

/// Event data context - 16 bytes union for passing event data
/// Can be interpreted as different types depending on the event
pub const EventContext = extern union {
    i64: [2]i64,
    u64: [2]u64,
    f64: [2]f64,

    i32: [4]i32,
    u32: [4]u32,
    f32: [4]f32,

    i16: [8]i16,
    u16: [8]u16,

    i8: [16]i8,
    u8: [16]u8,

    c: [16]u8,
};

/// System internal event codes. Application should use codes beyond 255.
pub const SystemEventCode = enum(u16) {
    /// Shuts the application down on the next frame.
    application_quit = 0x01,

    /// Keyboard key pressed.
    /// Context usage: key_code = data.u16[0]
    key_pressed = 0x02,

    /// Keyboard key released.
    /// Context usage: key_code = data.u16[0]
    key_released = 0x03,

    /// Mouse button pressed.
    /// Context usage: button = data.u16[0]
    button_pressed = 0x04,

    /// Mouse button released.
    /// Context usage: button = data.u16[0]
    button_released = 0x05,

    /// Mouse moved.
    /// Context usage: x = data.u16[0], y = data.u16[1]
    mouse_moved = 0x06,

    /// Mouse wheel scrolled.
    /// Context usage: z_delta = data.i8[0]
    mouse_wheel = 0x07,

    /// Resized/resolution changed from the OS.
    /// Context usage: width = data.u16[0], height = data.u16[1]
    resized = 0x08,

    debug0 = 0x10,
    debug1 = 0x11,
    debug2 = 0x12,
    debug3 = 0x13,
    debug4 = 0x14,

    // Application can use codes 0x100 and above
    _,
};

/// Event callback function type
/// Returns true if the event was handled and should not propagate further
pub const OnEventFn = *const fn (code: u16, sender: ?*anyopaque, listener: ?*anyopaque, data: EventContext) bool;

/// A registered event listener
const RegisteredEvent = struct {
    listener: ?*anyopaque,
    callback: OnEventFn,
};

/// Entry for a single event code containing all registered listeners
const EventCodeEntry = struct {
    events: std.ArrayList(RegisteredEvent),
};

// Private instance storage
var instance: EventSystem = undefined;

pub const EventSystem = struct {
    allocator: std.mem.Allocator,
    registered: [max_message_codes]?EventCodeEntry,

    /// Initialize the event system
    pub fn initialize() bool {
        instance = EventSystem{
            .allocator = memory.getAllocator(),
            .registered = [_]?EventCodeEntry{null} ** max_message_codes,
        };
        // Register with the shared context
        context.get().event = &instance;
        logger.info("Event system initialized.", .{});
        return true;
    }

    /// Shutdown the event system and free all registered event arrays
    pub fn shutdown() void {
        const sys = context.get().event orelse return;

        // Free all event arrays
        for (&sys.registered) |*entry| {
            if (entry.*) |*e| {
                e.events.deinit(sys.allocator);
                entry.* = null;
            }
        }

        context.get().event = null;
        logger.info("Event system shutdown.", .{});
    }
};

/// Get the event system instance
pub fn getSystem() ?*EventSystem {
    return context.get().event;
}

/// Register to listen for events with the provided code.
/// Events with duplicate listener/callback combos will not be registered again.
pub fn register(code: SystemEventCode, listener: ?*anyopaque, on_event: OnEventFn) bool {
    const sys = getSystem() orelse return false;

    const c: u16 = @intFromEnum(code);
    // Initialize the events array for this code if needed
    if (sys.registered[c] == null) {
        sys.registered[c] = EventCodeEntry{
            .events = std.ArrayList(RegisteredEvent).initCapacity(sys.allocator, 256) catch return false,
        };
    }

    var entry = &(sys.registered[c].?);

    // Check for duplicates
    for (entry.events.items) |e| {
        if (e.listener == listener and e.callback == on_event) {
            // Already registered
            return false;
        }
    }
    // Register the event
    entry.events.append(sys.allocator, .{
        .listener = listener,
        .callback = on_event,
    }) catch return false;
    return true;
}

/// Unregister from listening for events with the provided code.
pub fn unregister(code: SystemEventCode, listener: ?*anyopaque, on_event: OnEventFn) bool {
    const sys = getSystem() orelse return false;

    const c: u16 = @intFromEnum(code);
    const entry = &(sys.registered[c] orelse return false);

    // Find and remove the matching registration
    for (entry.events.items, 0..) |e, i| {
        if (e.listener == listener and e.callback == on_event) {
            _ = entry.events.orderedRemove(i);
            return true;
        }
    }
    return false;
}

/// Fire an event to listeners of the given code.
/// If an event handler returns true, the event is considered handled
/// and is not passed on to any more listeners.
pub fn fire(code: SystemEventCode, sender: ?*anyopaque, data: EventContext) bool {
    const sys = getSystem() orelse return false;

    const c: u16 = @intFromEnum(code);
    const entry = sys.registered[c] orelse return false;

    for (entry.events.items) |e| {
        if (e.callback(c, sender, e.listener, data)) {
            // Event was handled
            return true;
        }
    }
    return false;
}
