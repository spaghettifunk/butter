//! ImGui system - provides Dear ImGui integration for the Butter engine
//!
//! This module provides Zig-friendly wrappers around dcimgui C bindings.
//! The actual backend initialization (GLFW + Metal/Vulkan) is handled by
//! the RendererSystem, which knows which graphics backend is active.

const std = @import("std");
const logger = @import("../core/logging.zig");
const context_mod = @import("../context.zig");
const renderer = @import("../renderer/renderer.zig");

// Import dcimgui C bindings (core ImGui only - backends handled by renderer)
pub const c = @cImport({
    @cInclude("dcimgui.h");
});

// Re-export common types for convenience
pub const ImGuiContext = c.ImGuiContext;
pub const ImGuiIO = c.ImGuiIO;
pub const ImVec2 = c.ImVec2;
pub const ImVec4 = c.ImVec4;
pub const ImDrawData = c.ImDrawData;

// Window flags
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

// Condition flags for SetNextWindow* functions
pub const Cond = struct {
    pub const None: c_int = 0;
    pub const Always: c_int = 1 << 0;
    pub const Once: c_int = 1 << 1;
    pub const FirstUseEver: c_int = 1 << 2;
    pub const Appearing: c_int = 1 << 3;
};

// =============================================================================
// ImGui System - delegates to RendererSystem for backend-specific operations
// =============================================================================

pub const ImGuiSystem = struct {
    var initialized: bool = false;
    var imgui_context: ?*ImGuiContext = null;

    /// Initialize ImGui context and configure IO.
    /// Note: Backend initialization (GLFW + Metal/Vulkan) is done by RendererSystem.
    pub fn initialize() bool {
        if (initialized) {
            logger.warn("ImGui system already initialized", .{});
            return true;
        }

        // Create ImGui context
        imgui_context = c.ImGui_CreateContext(null);
        if (imgui_context == null) {
            logger.err("ImGui: Failed to create context", .{});
            return false;
        }

        // Get IO and configure
        const io = c.ImGui_GetIO();
        if (io == null) {
            logger.err("ImGui: Failed to get IO", .{});
            c.ImGui_DestroyContext(imgui_context);
            imgui_context = null;
            return false;
        }

        // Enable keyboard navigation
        io.*.ConfigFlags |= c.ImGuiConfigFlags_NavEnableKeyboard;

        // Setup dark theme by default
        c.ImGui_StyleColorsDark(null);

        // Now initialize the renderer backend (GLFW + Metal/Vulkan)
        if (renderer.getSystem()) |sys| {
            if (!sys.backend.initImGui()) {
                logger.err("ImGui: Failed to initialize renderer backend", .{});
                c.ImGui_DestroyContext(imgui_context);
                imgui_context = null;
                return false;
            }
        } else {
            logger.err("ImGui: No renderer system available", .{});
            c.ImGui_DestroyContext(imgui_context);
            imgui_context = null;
            return false;
        }

        initialized = true;
        logger.info("ImGui system initialized successfully", .{});
        return true;
    }

    /// Shutdown the ImGui system
    pub fn shutdown() void {
        if (!initialized) return;

        // Shutdown renderer backend
        if (renderer.getSystem()) |sys| {
            sys.backend.shutdownImGui();
        }

        if (imgui_context) |ctx| {
            c.ImGui_DestroyContext(ctx);
            imgui_context = null;
        }

        initialized = false;
        logger.info("ImGui system shutdown", .{});
    }

    /// Begin a new ImGui frame - call this at the start of the frame
    pub fn beginFrame() void {
        if (!initialized) {
            return;
        }

        // Let the renderer backend start its frame
        if (renderer.getSystem()) |sys| {
            sys.backend.beginImGuiFrame();
        } else {
            logger.warn("ImGui beginFrame: no renderer system", .{});
            return;
        }

        // Start ImGui frame
        c.ImGui_NewFrame();
    }

    /// End the ImGui frame and render - call this before endFrame on renderer
    pub fn endFrame() void {
        if (!initialized) {
            return;
        }

        // Render ImGui
        c.ImGui_Render();

        // Get draw data and let renderer backend render it
        const draw_data = c.ImGui_GetDrawData();
        if (draw_data != null) {
            if (renderer.getSystem()) |sys| {
                sys.backend.renderImGui(draw_data);
            }
        }
    }

    /// Check if ImGui is initialized
    pub fn isInitialized() bool {
        return initialized;
    }

    /// Check if ImGui wants to capture keyboard input
    pub fn wantsCaptureKeyboard() bool {
        if (!initialized) return false;
        const io = c.ImGui_GetIO();
        return io != null and io.*.WantCaptureKeyboard;
    }

    /// Check if ImGui wants to capture mouse input
    pub fn wantsCaptureMouse() bool {
        if (!initialized) return false;
        const io = c.ImGui_GetIO();
        return io != null and io.*.WantCaptureMouse;
    }
};

// =============================================================================
// Convenience wrappers for common ImGui functions
// =============================================================================

/// Begin a new window
pub fn begin(name: [*:0]const u8, p_open: ?*bool, flags: c_int) bool {
    return c.ImGui_Begin(name, p_open, flags);
}

/// End the current window
pub fn end() void {
    c.ImGui_End();
}

/// Display text
pub fn text(fmt: [*:0]const u8) void {
    c.ImGui_Text(fmt);
}

/// Display colored text
pub fn textColored(col: ImVec4, fmt: [*:0]const u8) void {
    c.ImGui_TextColored(col, fmt);
}

/// Button widget
pub fn button(label: [*:0]const u8) bool {
    return c.ImGui_Button(label);
}

/// Button widget with custom size
pub fn buttonEx(label: [*:0]const u8, size: ImVec2) bool {
    return c.ImGui_ButtonEx(label, size);
}

/// Checkbox widget
pub fn checkbox(label: [*:0]const u8, v: *bool) bool {
    return c.ImGui_Checkbox(label, v);
}

/// Slider for integers
pub fn sliderInt(label: [*:0]const u8, v: *c_int, v_min: c_int, v_max: c_int) bool {
    return c.ImGui_SliderInt(label, v, v_min, v_max);
}

/// Slider for floats
pub fn sliderFloat(label: [*:0]const u8, v: *f32, v_min: f32, v_max: f32) bool {
    return c.ImGui_SliderFloat(label, v, v_min, v_max);
}

/// Drag float widget
pub fn dragFloat(label: [*:0]const u8, v: *f32, v_speed: f32) bool {
    return c.ImGui_DragFloatEx(label, v, v_speed, 0.0, 0.0, "%.3f", 0);
}

/// Drag float3 widget (for position, rotation, scale vectors)
pub fn dragFloat3(label: [*:0]const u8, v: *[3]f32, v_speed: f32) bool {
    return c.ImGui_DragFloat3Ex(label, v, v_speed, 0.0, 0.0, "%.3f", 0);
}

/// Color edit widget (3 components)
pub fn colorEdit3(label: [*:0]const u8, col: *[3]f32) bool {
    return c.ImGui_ColorEdit3(label, col, 0);
}

/// Color edit widget (4 components)
pub fn colorEdit4(label: [*:0]const u8, col: *[4]f32) bool {
    return c.ImGui_ColorEdit4(label, col, 0);
}

/// Input text widget
pub fn inputText(label: [*:0]const u8, buf: [*]u8, buf_size: usize) bool {
    return c.ImGui_InputText(label, buf, buf_size, 0);
}

/// Input text widget with hint
pub fn inputTextWithHint(label: [*:0]const u8, hint: [*:0]const u8, buf: [*]u8, buf_size: usize, flags: c_int) bool {
    return c.ImGui_InputTextWithHint(label, hint, buf, buf_size, flags);
}

/// Same line - place next widget on same line
pub fn sameLine() void {
    c.ImGui_SameLine();
}

/// Separator line
pub fn separator() void {
    c.ImGui_Separator();
}

/// Spacing
pub fn spacing() void {
    c.ImGui_Spacing();
}

/// Set next window position
pub fn setNextWindowPos(pos: ImVec2, cond: c_int) void {
    c.ImGui_SetNextWindowPos(pos, cond);
}

/// Set next window size
pub fn setNextWindowSize(size: ImVec2, cond: c_int) void {
    c.ImGui_SetNextWindowSize(size, cond);
}

/// Begin a tree node
pub fn treeNode(label: [*:0]const u8) bool {
    return c.ImGui_TreeNode(label);
}

/// Pop a tree node
pub fn treePop() void {
    c.ImGui_TreePop();
}

/// Begin a collapsing header
pub fn collapsingHeader(label: [*:0]const u8) bool {
    return c.ImGui_CollapsingHeader(label, 0);
}

/// Begin a menu bar
pub fn beginMenuBar() bool {
    return c.ImGui_BeginMenuBar();
}

/// End the menu bar
pub fn endMenuBar() void {
    c.ImGui_EndMenuBar();
}

/// Begin the main menu bar (at the top of the screen)
pub fn beginMainMenuBar() bool {
    return c.ImGui_BeginMainMenuBar();
}

/// End the main menu bar
pub fn endMainMenuBar() void {
    c.ImGui_EndMainMenuBar();
}

/// Begin a menu
pub fn beginMenu(label: [*:0]const u8) bool {
    return c.ImGui_BeginMenu(label);
}

/// End a menu
pub fn endMenu() void {
    c.ImGui_EndMenu();
}

/// Menu item
pub fn menuItem(label: [*:0]const u8) bool {
    return c.ImGui_MenuItem(label);
}

/// Menu item with selected state
pub fn menuItemSelected(label: [*:0]const u8, selected: *bool) bool {
    return c.ImGui_MenuItemBoolPtr(label, null, selected, true);
}

/// Get IO structure
pub fn getIO() *ImGuiIO {
    return c.ImGui_GetIO();
}

/// Begin a child region
pub fn beginChild(str_id: [*:0]const u8, size: ImVec2, child_flags: c_int, window_flags: c_int) bool {
    return c.ImGui_BeginChild(str_id, size, child_flags, window_flags);
}

/// End a child region
pub fn endChild() void {
    c.ImGui_EndChild();
}

/// Get foreground draw list
pub fn getForegroundDrawList() *c.ImDrawList {
    return c.ImGui_GetForegroundDrawList();
}

/// Set keyboard focus to the next widget
pub fn setKeyboardFocusHere() void {
    c.ImGui_SetKeyboardFocusHere();
}

/// Set keyboard focus to a widget at relative offset
pub fn setKeyboardFocusHereEx(offset: c_int) void {
    c.ImGui_SetKeyboardFocusHereEx(offset);
}

/// Child flags
pub const ChildFlags = struct {
    pub const None: c_int = 0;
    pub const Border: c_int = 1 << 0;
    pub const AlwaysUseWindowPadding: c_int = 1 << 1;
    pub const ResizeX: c_int = 1 << 2;
    pub const ResizeY: c_int = 1 << 3;
    pub const AutoResizeX: c_int = 1 << 4;
    pub const AutoResizeY: c_int = 1 << 5;
    pub const AlwaysAutoResize: c_int = 1 << 6;
    pub const FrameStyle: c_int = 1 << 7;
};

/// Input text flags
pub const InputTextFlags = struct {
    pub const None: c_int = 0;
    pub const CharsDecimal: c_int = 1 << 0;
    pub const CharsHexadecimal: c_int = 1 << 1;
    pub const CharsUppercase: c_int = 1 << 2;
    pub const CharsNoBlank: c_int = 1 << 3;
    pub const AutoSelectAll: c_int = 1 << 4;
    pub const EnterReturnsTrue: c_int = 1 << 5;
    pub const CallbackCompletion: c_int = 1 << 6;
    pub const CallbackHistory: c_int = 1 << 7;
    pub const CallbackAlways: c_int = 1 << 8;
    pub const CallbackCharFilter: c_int = 1 << 9;
    pub const AllowTabInput: c_int = 1 << 10;
    pub const CtrlEnterForNewLine: c_int = 1 << 11;
    pub const NoHorizontalScroll: c_int = 1 << 12;
    pub const AlwaysOverwrite: c_int = 1 << 13;
    pub const ReadOnly: c_int = 1 << 14;
    pub const Password: c_int = 1 << 15;
    pub const NoUndoRedo: c_int = 1 << 16;
    pub const CharsScientific: c_int = 1 << 17;
    pub const CallbackResize: c_int = 1 << 18;
    pub const CallbackEdit: c_int = 1 << 19;
    pub const EscapeClearsAll: c_int = 1 << 20;
};

pub const Key = enum(c_int) {
    none = 0,
    tab = 512,
    left_arrow = 513,
    right_arrow = 514,
    up_arrow = 515,
    down_arrow = 516,
    page_up = 517,
    page_down = 518,
    home = 519,
    end = 520,
    insert = 521,
    delete = 522,
    backspace = 523,
    space = 524,
    enter = 525,
    escape = 526,
    left_ctrl = 527,
    left_shift = 528,
    left_alt = 529,
    left_super = 530,
    right_ctrl = 531,
    right_shift = 532,
    right_alt = 533,
    right_super = 534,
};

pub const MouseButton = enum(c_int) {
    left = 0,
    right = 1,
    middle = 2,
};

pub fn isKeyPressed(key: Key) bool {
    return c.ImGui_IsKeyPressed(@intFromEnum(key));
}

pub fn isKeyPressedEx(key: Key, repeat: bool) bool {
    return c.ImGui_IsKeyPressedEx(@intFromEnum(key), repeat);
}

pub fn isKeyReleased(key: Key) bool {
    return c.ImGui_IsKeyReleased(@intFromEnum(key));
}

pub fn isItemActive() bool {
    return c.ImGui_IsItemActive();
}

pub fn isItemDeactivatedAfterEdit() bool {
    return c.ImGui_IsItemDeactivatedAfterEdit();
}

pub fn isMouseClicked(button_idx: MouseButton) bool {
    return c.ImGui_IsMouseClicked(@intFromEnum(button_idx), false);
}

/// Push item width
pub fn pushItemWidth(item_width: f32) void {
    c.ImGui_PushItemWidth(item_width);
}

/// Pop item width
pub fn popItemWidth() void {
    c.ImGui_PopItemWidth();
}

/// Get frame height with spacing
pub fn getFrameHeightWithSpacing() f32 {
    return c.ImGui_GetFrameHeightWithSpacing();
}

/// Get scroll Y position
pub fn getScrollY() f32 {
    return c.ImGui_GetScrollY();
}

/// Get maximum scroll Y position
pub fn getScrollMaxY() f32 {
    return c.ImGui_GetScrollMaxY();
}

/// Set scroll Y position (0.0 = top, 1.0 = bottom)
pub fn setScrollHereY(center_y_ratio: f32) void {
    c.ImGui_SetScrollHereY(center_y_ratio);
}

/// Set item default focus
pub fn setItemDefaultFocus() void {
    c.ImGui_SetItemDefaultFocus();
}

/// Text disabled (dimmed)
pub fn textDisabled(fmt: [*:0]const u8) void {
    c.ImGui_TextDisabled(fmt);
}

/// Push ID (int version)
pub fn pushIdInt(int_id: c_int) void {
    c.ImGui_PushIDInt(int_id);
}

/// Pop ID
pub fn popId() void {
    c.ImGui_PopID();
}

/// Selectable
pub fn selectable(label: [*:0]const u8) bool {
    return c.ImGui_Selectable(label);
}

/// Selectable with options
pub fn selectableEx(label: [*:0]const u8, selected: bool, flags: c_int, size: ImVec2) bool {
    return c.ImGui_SelectableEx(label, selected, flags, size);
}

/// Set cursor X position
pub fn setCursorPosX(local_x: f32) void {
    c.ImGui_SetCursorPosX(local_x);
}

/// Selectable flags
pub const SelectableFlags = struct {
    pub const None: c_int = 0;
    pub const NoAutoClosePopups: c_int = 1 << 0;
    pub const SpanAllColumns: c_int = 1 << 1;
    pub const AllowDoubleClick: c_int = 1 << 2;
    pub const Disabled: c_int = 1 << 3;
    pub const AllowOverlap: c_int = 1 << 4;
};

// =============================================================================
// ImDrawList wrappers for overlays
// =============================================================================

pub const ImDrawList = c.ImDrawList;

/// Add a filled rectangle
pub fn drawListAddRectFilled(draw_list: *c.ImDrawList, p_min: ImVec2, p_max: ImVec2, col: u32) void {
    c.ImDrawList_AddRectFilled(draw_list, p_min, p_max, col);
}

/// Add a filled rectangle with rounding
pub fn drawListAddRectFilledEx(draw_list: *c.ImDrawList, p_min: ImVec2, p_max: ImVec2, col: u32, rounding: f32, flags: c_int) void {
    c.ImDrawList_AddRectFilledEx(draw_list, p_min, p_max, col, rounding, flags);
}

/// Add a line
pub fn drawListAddLine(draw_list: *c.ImDrawList, p1: ImVec2, p2: ImVec2, col: u32) void {
    c.ImDrawList_AddLine(draw_list, p1, p2, col);
}

/// Add a line with thickness
pub fn drawListAddLineEx(draw_list: *c.ImDrawList, p1: ImVec2, p2: ImVec2, col: u32, thickness: f32) void {
    c.ImDrawList_AddLineEx(draw_list, p1, p2, col, thickness);
}

/// Add text
pub fn drawListAddText(draw_list: *c.ImDrawList, pos: ImVec2, col: u32, txt: [*:0]const u8) void {
    c.ImDrawList_AddText(draw_list, pos, col, txt);
}

/// Add triangle filled
pub fn drawListAddTriangleFilled(draw_list: *c.ImDrawList, p1: ImVec2, p2: ImVec2, p3: ImVec2, col: u32) void {
    c.ImDrawList_AddTriangleFilled(draw_list, p1, p2, p3, col);
}

/// Add circle with segments and thickness
pub fn drawListAddCircleEx(draw_list: *c.ImDrawList, center: ImVec2, radius: f32, col: u32, num_segments: c_int, thickness: f32) void {
    c.ImDrawList_AddCircleEx(draw_list, center, radius, col, num_segments, thickness);
}

/// Add filled circle
pub fn drawListAddCircleFilled(draw_list: *c.ImDrawList, center: ImVec2, radius: f32, col: u32, num_segments: c_int) void {
    c.ImDrawList_AddCircleFilled(draw_list, center, radius, col, num_segments);
}

/// Add ellipse with rotation, segments and thickness
pub fn drawListAddEllipseEx(draw_list: *c.ImDrawList, center: ImVec2, radius: ImVec2, col: u32, rot: f32, num_segments: c_int, thickness: f32) void {
    c.ImDrawList_AddEllipseEx(draw_list, center, radius, col, rot, num_segments, thickness);
}
