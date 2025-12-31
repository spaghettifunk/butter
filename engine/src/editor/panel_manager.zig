//! Panel Manager
//! Manages panel registration, visibility, and focus state.

const std = @import("std");
const logger = @import("../core/logging.zig");

/// Panel render callback type.
pub const PanelRenderFn = *const fn (*bool) void;

/// Panel state information.
pub const PanelState = struct {
    /// Unique identifier for the panel.
    id: []const u8,
    /// Human-readable name for the panel.
    name: []const u8,
    /// Whether the panel is currently visible.
    is_open: bool = false,
    /// Whether the panel is currently focused.
    is_focused: bool = false,
    /// Whether the panel can be docked.
    is_dockable: bool = true,
    /// Render callback for the panel.
    render_fn: PanelRenderFn,
};

pub const PanelManager = struct {
    allocator: std.mem.Allocator,
    panels: std.StringHashMap(PanelState),
    focused_panel: ?[]const u8 = null,

    /// Initialize the panel manager.
    pub fn init(allocator: std.mem.Allocator) PanelManager {
        return .{
            .allocator = allocator,
            .panels = std.StringHashMap(PanelState).init(allocator),
        };
    }

    /// Shutdown and free resources.
    pub fn deinit(self: *PanelManager) void {
        self.panels.deinit();
    }

    /// Register a panel.
    pub fn register(self: *PanelManager, panel: PanelState) !void {
        try self.panels.put(panel.id, panel);
        logger.debug("Registered panel: {s}", .{panel.id});
    }

    /// Unregister a panel by ID.
    pub fn unregister(self: *PanelManager, id: []const u8) bool {
        return self.panels.remove(id);
    }

    /// Toggle a panel's visibility.
    pub fn toggle(self: *PanelManager, id: []const u8) void {
        if (self.panels.getPtr(id)) |panel| {
            panel.is_open = !panel.is_open;
            if (panel.is_open) {
                self.focus(id);
            }
            logger.debug("Panel {s} toggled: {}", .{ id, panel.is_open });
        }
    }

    /// Open a panel.
    pub fn open(self: *PanelManager, id: []const u8) void {
        if (self.panels.getPtr(id)) |panel| {
            panel.is_open = true;
            self.focus(id);
        }
    }

    /// Close a panel.
    pub fn close(self: *PanelManager, id: []const u8) void {
        if (self.panels.getPtr(id)) |panel| {
            panel.is_open = false;
            if (self.focused_panel != null and std.mem.eql(u8, self.focused_panel.?, id)) {
                self.focused_panel = null;
            }
        }
    }

    /// Focus a panel (unfocusing the previous one).
    pub fn focus(self: *PanelManager, id: []const u8) void {
        // Unfocus previous
        if (self.focused_panel) |prev| {
            if (self.panels.getPtr(prev)) |panel| {
                panel.is_focused = false;
            }
        }

        // Focus new
        if (self.panels.getPtr(id)) |panel| {
            panel.is_focused = true;
            self.focused_panel = id;
        }
    }

    /// Check if a panel is open.
    pub fn isOpen(self: *PanelManager, id: []const u8) bool {
        if (self.panels.get(id)) |panel| {
            return panel.is_open;
        }
        return false;
    }

    /// Check if a panel is focused.
    pub fn isFocused(self: *PanelManager, id: []const u8) bool {
        if (self.panels.get(id)) |panel| {
            return panel.is_focused;
        }
        return false;
    }

    /// Get a panel's open state pointer (for ImGui integration).
    pub fn getOpenPtr(self: *PanelManager, id: []const u8) ?*bool {
        if (self.panels.getPtr(id)) |panel| {
            return &panel.is_open;
        }
        return null;
    }

    /// Render all open panels.
    pub fn renderAll(self: *PanelManager) void {
        var iter = self.panels.iterator();
        while (iter.next()) |entry| {
            const panel = entry.value_ptr;
            if (panel.is_open) {
                panel.render_fn(&panel.is_open);
            }
        }
    }

    /// Get the number of registered panels.
    pub fn count(self: *PanelManager) usize {
        return self.panels.count();
    }

    /// Get the number of open panels.
    pub fn openCount(self: *PanelManager) usize {
        var c: usize = 0;
        var iter = self.panels.valueIterator();
        while (iter.next()) |panel| {
            if (panel.is_open) c += 1;
        }
        return c;
    }
};
