//! Resource Loading Panel
//! Displays async resource loading progress and status.

const std = @import("std");
const imgui = @import("../../systems/imgui.zig");
const context = @import("../../context.zig");
const resource_manager = @import("../../resources/manager.zig");
const registry = @import("../../resources/registry.zig");
const handle = @import("../../resources/handle.zig");

const c = imgui.c;

/// Resource loading info for display
pub const LoadingInfo = struct {
    uri: []const u8,
    resource_type: handle.ResourceType,
    state: registry.ResourceState,
    progress: f32, // 0.0 to 1.0
};

pub const ResourceLoadingPanel = struct {
    allocator: std.mem.Allocator,

    /// Cached loading resources for display
    loading_resources: std.ArrayList(LoadingInfo),

    /// Whether to show completed resources
    show_completed: bool = true,

    /// Whether to show failed resources
    show_failed: bool = true,

    /// Auto-refresh interval in seconds
    refresh_interval: f32 = 0.5,

    /// Time since last refresh
    time_since_refresh: f32 = 0.0,

    /// Initialize the resource loading panel.
    pub fn init(allocator: std.mem.Allocator) ResourceLoadingPanel {
        return ResourceLoadingPanel{
            .allocator = allocator,
            .loading_resources = .empty,
            .show_completed = true,
            .show_failed = true,
        };
    }

    /// Shutdown and free resources.
    pub fn deinit(self: *ResourceLoadingPanel) void {
        // Free cached URIs
        for (self.loading_resources.items) |info| {
            self.allocator.free(info.uri);
        }
        self.loading_resources.deinit(self.allocator);
    }

    /// Update the panel (call each frame with delta time)
    pub fn update(self: *ResourceLoadingPanel, delta_time: f32) void {
        self.time_since_refresh += delta_time;

        // Refresh resource list periodically
        if (self.time_since_refresh >= self.refresh_interval) {
            self.refreshResourceList();
            self.time_since_refresh = 0.0;
        }
    }

    /// Refresh the list of loading resources from ResourceManager
    fn refreshResourceList(self: *ResourceLoadingPanel) void {
        // Clear old list
        for (self.loading_resources.items) |info| {
            self.allocator.free(info.uri);
        }
        self.loading_resources.clearRetainingCapacity();

        // Get resource manager
        const rm = resource_manager.getSystem() orelse return;

        // Iterate through all metadata in registry
        const metadata_count = rm.resource_registry.metadata.items.len;
        for (0..metadata_count) |i| {
            const meta = &rm.resource_registry.metadata.items[i];

            // Skip unloaded resources unless we want to show everything
            if (meta.state == .unloaded) continue;

            // Calculate progress based on state
            const progress: f32 = switch (meta.state) {
                .unloaded => 0.0,
                .loading => 0.5, // Indeterminate progress
                .loaded => 1.0,
                .failed => 0.0,
                .hot_reloading => 0.75,
            };

            // Duplicate URI for display
            const uri_copy = self.allocator.dupe(u8, meta.uri) catch continue;

            self.loading_resources.append(self.allocator, .{
                .uri = uri_copy,
                .resource_type = meta.resource_type,
                .state = meta.state,
                .progress = progress,
            }) catch {
                self.allocator.free(uri_copy);
                continue;
            };
        }
    }

    /// Render the resource loading panel.
    pub fn render(self: *ResourceLoadingPanel, p_open: *bool) void {
        if (imgui.begin("Resource Loading", p_open, imgui.WindowFlags.MenuBar)) {
            // Menu bar
            if (imgui.beginMenuBar()) {
                if (imgui.beginMenu("Options")) {
                    _ = c.ImGui_Checkbox("Show Completed", &self.show_completed);
                    _ = c.ImGui_Checkbox("Show Failed", &self.show_failed);
                    imgui.separator();

                    if (imgui.menuItem("Refresh Now")) {
                        self.refreshResourceList();
                    }

                    imgui.endMenu();
                }

                imgui.endMenuBar();
            }

            // Statistics header
            var loading_count: u32 = 0;
            var loaded_count: u32 = 0;
            var failed_count: u32 = 0;

            for (self.loading_resources.items) |info| {
                switch (info.state) {
                    .loading, .hot_reloading => loading_count += 1,
                    .loaded => loaded_count += 1,
                    .failed => failed_count += 1,
                    else => {},
                }
            }

            var stats_buf: [256]u8 = undefined;
            const stats_text = std.fmt.bufPrintZ(&stats_buf, "Loading: {d} | Loaded: {d} | Failed: {d}", .{
                loading_count,
                loaded_count,
                failed_count,
            }) catch "Stats unavailable";

            imgui.textColored(.{ .x = 0.7, .y = 0.7, .z = 0.7, .w = 1.0 }, stats_text);
            imgui.separator();

            // Resource list
            if (imgui.beginChild("##resource_list", .{ .x = 0, .y = 0 }, imgui.ChildFlags.None, imgui.WindowFlags.None)) {
                if (self.loading_resources.items.len == 0) {
                    imgui.textColored(.{ .x = 0.5, .y = 0.5, .z = 0.5, .w = 1.0 }, "No resources tracked");
                } else {
                    // Table header
                    const table_flags = c.ImGuiTableFlags_Borders |
                        c.ImGuiTableFlags_RowBg |
                        c.ImGuiTableFlags_Resizable |
                        c.ImGuiTableFlags_ScrollY;

                    if (c.ImGui_BeginTable("##resources_table", 4, table_flags)) {
                        // Setup columns
                        c.ImGui_TableSetupColumn("Type", c.ImGuiTableColumnFlags_WidthFixed);
                        c.ImGui_TableSetupColumn("URI", c.ImGuiTableColumnFlags_WidthStretch);
                        c.ImGui_TableSetupColumn("State", c.ImGuiTableColumnFlags_WidthFixed);
                        c.ImGui_TableSetupColumn("Progress", c.ImGuiTableColumnFlags_WidthFixed);
                        c.ImGui_TableHeadersRow();

                        // Render each resource
                        for (self.loading_resources.items) |info| {
                            // Filter based on state
                            if (!self.show_completed and info.state == .loaded) continue;
                            if (!self.show_failed and info.state == .failed) continue;

                            _ = c.ImGui_TableNextRow();

                            // Column 1: Type
                            _ = c.ImGui_TableSetColumnIndex(0);
                            const type_str = switch (info.resource_type) {
                                .texture => "Texture",
                                .material => "Material",
                                .mesh_asset => "Mesh",
                                .geometry => "Geometry",
                                .shader => "Shader",
                                .font => "Font",
                                .scene => "Scene",
                                .unknown => "Unknown",
                            };
                            imgui.text(type_str);

                            // Column 2: URI
                            _ = c.ImGui_TableSetColumnIndex(1);
                            imgui.text(@ptrCast(info.uri.ptr));

                            // Column 3: State
                            _ = c.ImGui_TableSetColumnIndex(2);
                            const state_color = getStateColor(info.state);
                            const state_label = info.state.toString();
                            const state_label_cstr: [*:0]const u8 = @ptrCast(state_label.ptr);
                            imgui.textColored(state_color, state_label_cstr);

                            // Column 4: Progress
                            _ = c.ImGui_TableSetColumnIndex(3);
                            if (info.state == .loading or info.state == .hot_reloading) {
                                // Animated indeterminate progress bar
                                // const time = @as(f32, @floatFromInt(std.time.milliTimestamp() % 2000)) / 2000.0;
                                const time = @as(f32, @floatFromInt(@mod(std.time.milliTimestamp(), 2000))) * (1.0 / 2000.0);
                                const animated_progress = @abs(@sin(time * std.math.pi));

                                var progress_buf: [32]u8 = undefined;
                                const overlay_text = std.fmt.bufPrintZ(&progress_buf, "Loading...", .{}) catch "";

                                c.ImGui_ProgressBar(animated_progress, .{ .x = -1, .y = 0 }, overlay_text);
                            } else if (info.state == .loaded) {
                                c.ImGui_ProgressBar(1.0, .{ .x = -1, .y = 0 }, "Complete");
                            } else if (info.state == .failed) {
                                imgui.textColored(.{ .x = 1.0, .y = 0.3, .z = 0.3, .w = 1.0 }, "Failed");
                            }
                        }

                        c.ImGui_EndTable();
                    }
                }
            }
            imgui.endChild();
        }
        imgui.end();
    }

    /// Get color for resource state
    fn getStateColor(state: registry.ResourceState) imgui.ImVec4 {
        return switch (state) {
            .unloaded => .{ .x = 0.5, .y = 0.5, .z = 0.5, .w = 1.0 }, // Gray
            .loading => .{ .x = 0.4, .y = 0.7, .z = 1.0, .w = 1.0 }, // Blue
            .loaded => .{ .x = 0.4, .y = 1.0, .z = 0.4, .w = 1.0 }, // Green
            .failed => .{ .x = 1.0, .y = 0.3, .z = 0.3, .w = 1.0 }, // Red
            .hot_reloading => .{ .x = 1.0, .y = 0.8, .z = 0.2, .w = 1.0 }, // Yellow
        };
    }
};
