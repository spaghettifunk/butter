//! ImGui Stub Module
//! Provides no-op implementations for runtime builds without ImGui.
//! This allows game code to call ImGui functions without crashing.

const std = @import("std");

// Stub types that match the real ImGui types
pub const ImGuiContext = opaque {};
pub const ImGuiIO = extern struct {
    WantCaptureKeyboard: bool = false,
    WantCaptureMouse: bool = false,
    ConfigFlags: c_int = 0,
};
pub const ImVec2 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
};
pub const ImVec4 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 0,
};
pub const ImDrawData = opaque {};

// Window flags (matching real ImGui)
pub const WindowFlags = struct {
    pub const None: c_int = 0;
    pub const NoTitleBar: c_int = 1 << 0;
    pub const NoResize: c_int = 1 << 1;
    pub const NoMove: c_int = 1 << 2;
    pub const NoScrollbar: c_int = 1 << 3;
    pub const NoScrollWithMouse: c_int = 1 << 4;
    pub const NoCollapse: c_int = 1 << 5;
    pub const AlwaysAutoResize: c_int = 1 << 6;
    pub const NoBackground: c_int = 1 << 7;
    pub const NoSavedSettings: c_int = 1 << 8;
    pub const NoMouseInputs: c_int = 1 << 9;
    pub const MenuBar: c_int = 1 << 10;
    pub const HorizontalScrollbar: c_int = 1 << 11;
    pub const NoFocusOnAppearing: c_int = 1 << 12;
    pub const NoBringToFrontOnFocus: c_int = 1 << 13;
    pub const AlwaysVerticalScrollbar: c_int = 1 << 14;
    pub const AlwaysHorizontalScrollbar: c_int = 1 << 15;
    pub const NoNavInputs: c_int = 1 << 16;
    pub const NoNavFocus: c_int = 1 << 17;
    pub const UnsavedDocument: c_int = 1 << 18;
    pub const NoNav: c_int = NoNavInputs | NoNavFocus;
    pub const NoDecoration: c_int = NoTitleBar | NoResize | NoScrollbar | NoCollapse;
    pub const NoInputs: c_int = NoMouseInputs | NoNavInputs | NoNavFocus;
};

// Condition flags
pub const Cond = struct {
    pub const None: c_int = 0;
    pub const Always: c_int = 1 << 0;
    pub const Once: c_int = 1 << 1;
    pub const FirstUseEver: c_int = 1 << 2;
    pub const Appearing: c_int = 1 << 3;
};

// =============================================================================
// ImGui System - No-op implementation
// =============================================================================

pub const ImGuiSystem = struct {
    pub fn initialize() bool {
        return true; // No-op success
    }

    pub fn shutdown() void {}

    pub fn beginFrame() void {}

    pub fn endFrame() void {}

    pub fn isInitialized() bool {
        return false;
    }

    pub fn wantsCaptureKeyboard() bool {
        return false;
    }

    pub fn wantsCaptureMouse() bool {
        return false;
    }
};

// =============================================================================
// Convenience wrappers - all no-ops
// =============================================================================

pub fn begin(_: [*:0]const u8, _: ?*bool, _: c_int) bool {
    return false;
}

pub fn end() void {}

pub fn text(_: [*:0]const u8) void {}

pub fn textColored(_: ImVec4, _: [*:0]const u8) void {}

pub fn button(_: [*:0]const u8) bool {
    return false;
}

pub fn buttonEx(_: [*:0]const u8, _: ImVec2) bool {
    return false;
}

pub fn checkbox(_: [*:0]const u8, _: *bool) bool {
    return false;
}

pub fn sliderInt(_: [*:0]const u8, _: *c_int, _: c_int, _: c_int) bool {
    return false;
}

pub fn sliderFloat(_: [*:0]const u8, _: *f32, _: f32, _: f32) bool {
    return false;
}

pub fn colorEdit3(_: [*:0]const u8, _: *[3]f32) bool {
    return false;
}

pub fn colorEdit4(_: [*:0]const u8, _: *[4]f32) bool {
    return false;
}

pub fn inputText(_: [*:0]const u8, _: [*]u8, _: usize) bool {
    return false;
}

pub fn showDemoWindow(_: ?*bool) void {}

pub fn sameLine() void {}

pub fn separator() void {}

pub fn spacing() void {}

pub fn setNextWindowPos(_: ImVec2, _: c_int) void {}

pub fn setNextWindowSize(_: ImVec2, _: c_int) void {}

pub fn treeNode(_: [*:0]const u8) bool {
    return false;
}

pub fn treePop() void {}

pub fn collapsingHeader(_: [*:0]const u8) bool {
    return false;
}

pub fn beginMenuBar() bool {
    return false;
}

pub fn endMenuBar() void {}

pub fn beginMainMenuBar() bool {
    return false;
}

pub fn endMainMenuBar() void {}

pub fn beginMenu(_: [*:0]const u8) bool {
    return false;
}

pub fn endMenu() void {}

pub fn menuItem(_: [*:0]const u8) bool {
    return false;
}

pub fn menuItemSelected(_: [*:0]const u8, _: *bool) bool {
    return false;
}

var dummy_io: ImGuiIO = .{};

pub fn getIO() *ImGuiIO {
    return &dummy_io;
}
