//! Render Graph Compiler
//!
//! Performs dependency resolution, topological sorting, and barrier generation
//! to produce an executable render graph from the declarative specification.

const std = @import("std");
const resource = @import("resource.zig");
const pass = @import("pass.zig");
const graph_mod = @import("graph.zig");

const ResourceHandle = resource.ResourceHandle;
const RenderPass = pass.RenderPass;
const RenderGraph = graph_mod.RenderGraph;
const MAX_PASSES = graph_mod.MAX_PASSES;
const MAX_RESOURCES = graph_mod.MAX_RESOURCES;

/// Access flags for resource barriers
pub const AccessFlags = packed struct(u16) {
    vertex_read: bool = false,
    index_read: bool = false,
    uniform_read: bool = false,
    shader_read: bool = false,
    shader_write: bool = false,
    color_attachment_read: bool = false,
    color_attachment_write: bool = false,
    depth_read: bool = false,
    depth_write: bool = false,
    transfer_read: bool = false,
    transfer_write: bool = false,
    _padding: u5 = 0,

    pub const none = AccessFlags{};

    pub const color_write_flags = AccessFlags{ .color_attachment_write = true };
    pub const depth_write_flags = AccessFlags{ .depth_write = true };
    pub const shader_sample = AccessFlags{ .shader_read = true };

    /// Convert to Vulkan VkAccessFlags
    pub fn toVulkan(self: AccessFlags) u32 {
        var flags: u32 = 0;
        if (self.vertex_read) flags |= 0x00000002; // VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT
        if (self.index_read) flags |= 0x00000001; // VK_ACCESS_INDEX_READ_BIT
        if (self.uniform_read) flags |= 0x00000004; // VK_ACCESS_UNIFORM_READ_BIT
        if (self.shader_read) flags |= 0x00000020; // VK_ACCESS_SHADER_READ_BIT
        if (self.shader_write) flags |= 0x00000040; // VK_ACCESS_SHADER_WRITE_BIT
        if (self.color_attachment_read) flags |= 0x00000080; // VK_ACCESS_COLOR_ATTACHMENT_READ_BIT
        if (self.color_attachment_write) flags |= 0x00000100; // VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT
        if (self.depth_read) flags |= 0x00000200; // VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT
        if (self.depth_write) flags |= 0x00000400; // VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT
        if (self.transfer_read) flags |= 0x00000800; // VK_ACCESS_TRANSFER_READ_BIT
        if (self.transfer_write) flags |= 0x00001000; // VK_ACCESS_TRANSFER_WRITE_BIT
        return flags;
    }

    /// Get the pipeline stage mask for these access flags
    pub fn toPipelineStage(self: AccessFlags) u32 {
        var stage: u32 = 0;
        if (self.vertex_read or self.index_read) stage |= 0x00000002; // VK_PIPELINE_STAGE_VERTEX_INPUT_BIT
        if (self.uniform_read or self.shader_read or self.shader_write) stage |= 0x00000080; // VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
        if (self.color_attachment_read or self.color_attachment_write) stage |= 0x00000400; // VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
        if (self.depth_read or self.depth_write) stage |= 0x00000100; // VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT
        if (self.transfer_read or self.transfer_write) stage |= 0x00001000; // VK_PIPELINE_STAGE_TRANSFER_BIT
        if (stage == 0) stage = 0x00000001; // VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT
        return stage;
    }
};

/// Image layout states
pub const ImageLayout = enum(u8) {
    undefined,
    general,
    color_attachment,
    depth_stencil_attachment,
    depth_stencil_read_only,
    shader_read_only,
    transfer_src,
    transfer_dst,
    present_src,

    /// Convert to Vulkan VkImageLayout
    pub fn toVulkan(self: ImageLayout) u32 {
        return switch (self) {
            .undefined => 0, // VK_IMAGE_LAYOUT_UNDEFINED
            .general => 1, // VK_IMAGE_LAYOUT_GENERAL
            .color_attachment => 2, // VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
            .depth_stencil_attachment => 3, // VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
            .depth_stencil_read_only => 4, // VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL
            .shader_read_only => 5, // VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
            .transfer_src => 6, // VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
            .transfer_dst => 7, // VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
            .present_src => 1000001002, // VK_IMAGE_LAYOUT_PRESENT_SRC_KHR
        };
    }
};

/// Resource barrier for synchronization
pub const ResourceBarrier = struct {
    resource: ResourceHandle,
    src_access: AccessFlags,
    dst_access: AccessFlags,
    src_layout: ImageLayout,
    dst_layout: ImageLayout,
};

/// Maximum barriers per pass
pub const MAX_BARRIERS_PER_PASS: usize = 32;

/// Compiled pass with execution info
pub const CompiledPass = struct {
    /// Index into the original pass array
    pass_index: u16,

    /// Execution order in the compiled graph
    execution_order: u16,

    /// Passes this pass must wait for
    wait_passes: [16]u16 = [_]u16{0xFFFF} ** 16,
    wait_pass_count: u8 = 0,

    /// Resource barriers to execute before this pass
    barriers: [MAX_BARRIERS_PER_PASS]ResourceBarrier = undefined,
    barrier_count: u8 = 0,
};

/// Compiler error types
pub const CompileError = error{
    CycleDetected,
    ResourceNotFound,
    InvalidPass,
    TooManyDependencies,
};

/// Graph compiler state
pub const GraphCompiler = struct {
    graph: *RenderGraph,

    // Dependency tracking (adjacency[i][j] = pass i depends on pass j)
    adjacency: [MAX_PASSES][MAX_PASSES]bool = [_][MAX_PASSES]bool{[_]bool{false} ** MAX_PASSES} ** MAX_PASSES,

    // In-degree for each pass (number of passes that must complete first)
    in_degree: [MAX_PASSES]u16 = [_]u16{0} ** MAX_PASSES,

    // Compiled passes
    compiled_passes: [MAX_PASSES]CompiledPass = undefined,
    compiled_pass_count: u16 = 0,

    // Execution order (indices into compiled_passes)
    execution_order: [MAX_PASSES]u16 = [_]u16{0} ** MAX_PASSES,

    // Resource state tracking for barrier generation
    resource_states: [MAX_RESOURCES]struct {
        layout: ImageLayout,
        access: AccessFlags,
    } = undefined,

    /// Initialize compiler for a graph
    pub fn init(graph_ptr: *RenderGraph) GraphCompiler {
        var compiler = GraphCompiler{
            .graph = graph_ptr,
        };

        // Initialize compiled passes
        for (&compiler.compiled_passes) |*cp| {
            cp.* = CompiledPass{
                .pass_index = 0,
                .execution_order = 0,
            };
        }

        // Initialize resource states to undefined
        for (&compiler.resource_states) |*state| {
            state.* = .{
                .layout = .undefined,
                .access = AccessFlags.none,
            };
        }

        return compiler;
    }

    /// Compile the render graph
    pub fn compile(self: *GraphCompiler) CompileError!void {
        // Reset state
        self.compiled_pass_count = 0;
        for (&self.adjacency) |*row| {
            for (row) |*cell| {
                cell.* = false;
            }
        }
        for (&self.in_degree) |*deg| {
            deg.* = 0;
        }

        // Step 1: Build dependency graph
        self.buildDependencyGraph();

        // Step 2: Validate - check for cycles
        try self.validateNoCycles();

        // Step 3: Topological sort using Kahn's algorithm
        try self.topologicalSort();

        // Step 4: Compute resource lifetimes
        self.computeResourceLifetimes();

        // Step 5: Generate barriers
        self.generateBarriers();

        // Step 6: Cull unused passes (optional)
        self.cullUnusedPasses();

        self.graph.is_compiled = true;
    }

    /// Build the dependency adjacency matrix
    fn buildDependencyGraph(self: *GraphCompiler) void {
        const pass_count = self.graph.pass_count;

        for (0..pass_count) |pass_idx_usize| {
            const pass_idx: u16 = @intCast(pass_idx_usize);
            const current_pass = &self.graph.passes[pass_idx];

            // Get all resources this pass reads
            var read_handles: [32]ResourceHandle = undefined;
            const read_count = current_pass.getDependencies(&read_handles);

            // For each read resource, find the pass that writes it
            for (read_handles[0..read_count]) |read_handle| {
                if (!read_handle.isValid()) continue;

                // Find which pass writes this resource
                if (self.findWriterPass(read_handle)) |writer_idx| {
                    if (writer_idx != pass_idx) {
                        self.adjacency[pass_idx][writer_idx] = true;
                        self.in_degree[pass_idx] += 1;
                    }
                }
            }
        }
    }

    /// Find the pass that writes to a resource
    fn findWriterPass(self: *GraphCompiler, handle: ResourceHandle) ?u16 {
        for (0..self.graph.pass_count) |idx_usize| {
            const idx: u16 = @intCast(idx_usize);
            const p = &self.graph.passes[idx];
            if (p.writesResource(handle)) {
                return idx;
            }
        }
        return null;
    }

    /// Validate that there are no cycles in the dependency graph
    fn validateNoCycles(self: *GraphCompiler) CompileError!void {
        // Use DFS to detect cycles
        var visited: [MAX_PASSES]u8 = [_]u8{0} ** MAX_PASSES; // 0=unvisited, 1=visiting, 2=done

        for (0..self.graph.pass_count) |i| {
            if (visited[i] == 0) {
                try self.dfsCheckCycle(@intCast(i), &visited);
            }
        }
    }

    /// DFS helper to detect cycles
    fn dfsCheckCycle(self: *GraphCompiler, node: u16, visited: *[MAX_PASSES]u8) CompileError!void {
        if (visited[node] == 1) {
            // Currently visiting - cycle detected!
            return CompileError.CycleDetected;
        }
        if (visited[node] == 2) {
            return; // Already processed
        }

        visited[node] = 1;

        // Visit all passes this one depends on
        for (0..self.graph.pass_count) |j| {
            if (self.adjacency[node][j]) {
                try self.dfsCheckCycle(@intCast(j), visited);
            }
        }

        visited[node] = 2;
    }

    /// Topological sort using Kahn's algorithm
    fn topologicalSort(self: *GraphCompiler) CompileError!void {
        var queue: [MAX_PASSES]u16 = undefined;
        var queue_front: usize = 0;
        var queue_back: usize = 0;

        // Make a copy of in_degree since we'll modify it
        var in_deg = self.in_degree;

        // Initialize queue with nodes having in_degree 0
        for (0..self.graph.pass_count) |i| {
            if (in_deg[i] == 0) {
                queue[queue_back] = @intCast(i);
                queue_back += 1;
            }
        }

        var order_index: u16 = 0;

        while (queue_front < queue_back) {
            const current = queue[queue_front];
            queue_front += 1;

            // Add to execution order
            self.execution_order[order_index] = current;
            self.compiled_passes[order_index].pass_index = current;
            self.compiled_passes[order_index].execution_order = order_index;
            self.graph.passes[current].execution_order = order_index;

            // Record dependencies for this compiled pass
            var wait_count: u8 = 0;
            for (0..self.graph.pass_count) |j| {
                if (self.adjacency[current][j] and wait_count < 16) {
                    // Find the execution order of the dependency
                    for (0..order_index) |k| {
                        if (self.execution_order[k] == j) {
                            self.compiled_passes[order_index].wait_passes[wait_count] = @intCast(k);
                            wait_count += 1;
                            break;
                        }
                    }
                }
            }
            self.compiled_passes[order_index].wait_pass_count = wait_count;

            order_index += 1;

            // Reduce in_degree for all dependent passes
            for (0..self.graph.pass_count) |j| {
                if (self.adjacency[j][current]) {
                    in_deg[j] -= 1;
                    if (in_deg[j] == 0) {
                        queue[queue_back] = @intCast(j);
                        queue_back += 1;
                    }
                }
            }
        }

        self.compiled_pass_count = order_index;

        if (order_index != self.graph.pass_count) {
            return CompileError.CycleDetected; // Not all nodes processed
        }
    }

    /// Compute resource lifetimes (first/last use pass)
    fn computeResourceLifetimes(self: *GraphCompiler) void {
        // Reset lifetimes
        for (self.graph.resources[0..self.graph.resource_count]) |*res| {
            res.first_use_pass = 0xFFFF;
            res.last_use_pass = 0;
        }

        // Process passes in execution order
        for (self.execution_order[0..self.compiled_pass_count], 0..) |pass_idx, order| {
            const current_pass = &self.graph.passes[pass_idx];

            // Update lifetimes for all resources used by this pass
            var handles: [64]ResourceHandle = undefined;

            // Get outputs
            const output_count = current_pass.getOutputs(handles[0..32]);
            for (handles[0..output_count]) |h| {
                if (h.isValid() and h.index < self.graph.resource_count) {
                    self.updateLifetime(h, @intCast(order));
                }
            }

            // Get inputs
            const input_count = current_pass.getDependencies(handles[0..32]);
            for (handles[0..input_count]) |h| {
                if (h.isValid() and h.index < self.graph.resource_count) {
                    self.updateLifetime(h, @intCast(order));
                }
            }
        }
    }

    /// Update the lifetime of a resource
    fn updateLifetime(self: *GraphCompiler, handle: ResourceHandle, order: u16) void {
        if (!handle.isValid()) return;
        if (handle.index >= self.graph.resource_count) return;

        var res = &self.graph.resources[handle.index];
        res.first_use_pass = @min(res.first_use_pass, order);
        res.last_use_pass = @max(res.last_use_pass, order);
    }

    /// Generate resource barriers between passes
    fn generateBarriers(self: *GraphCompiler) void {
        // Reset resource states
        for (&self.resource_states) |*state| {
            state.* = .{
                .layout = .undefined,
                .access = AccessFlags.none,
            };
        }

        // Process passes in execution order
        for (0..self.compiled_pass_count) |order| {
            var compiled = &self.compiled_passes[order];
            compiled.barrier_count = 0;

            const pass_idx = self.execution_order[order];
            const current_pass = &self.graph.passes[pass_idx];

            // Generate barriers for color attachments
            for (current_pass.color_attachments[0..current_pass.color_attachment_count]) |maybe_att| {
                if (maybe_att) |att| {
                    if (att.resource.isValid() and att.resource.index < self.graph.resource_count) {
                        self.addBarrierIfNeeded(compiled, att.resource, .color_attachment, AccessFlags.color_write_flags);
                    }
                }
            }

            // Generate barriers for depth attachment
            if (current_pass.depth_attachment) |depth| {
                if (depth.resource.isValid() and depth.resource.index < self.graph.resource_count) {
                    if (depth.read_only) {
                        self.addBarrierIfNeeded(compiled, depth.resource, .depth_stencil_read_only, AccessFlags{ .depth_read = true });
                    } else {
                        self.addBarrierIfNeeded(compiled, depth.resource, .depth_stencil_attachment, AccessFlags.depth_write_flags);
                    }
                }
            }

            // Generate barriers for sampled textures
            for (current_pass.resource_reads[0..current_pass.resource_read_count]) |maybe_read| {
                if (maybe_read) |read| {
                    if (read.resource.isValid() and read.resource.index < self.graph.resource_count) {
                        self.addBarrierIfNeeded(compiled, read.resource, .shader_read_only, AccessFlags.shader_sample);
                    }
                }
            }
        }
    }

    /// Add a barrier if the resource needs a layout transition
    fn addBarrierIfNeeded(
        self: *GraphCompiler,
        compiled: *CompiledPass,
        handle: ResourceHandle,
        dst_layout: ImageLayout,
        dst_access: AccessFlags,
    ) void {
        if (!handle.isValid()) return;
        if (compiled.barrier_count >= MAX_BARRIERS_PER_PASS) return;

        const current = &self.resource_states[handle.index];

        // Check if transition is needed
        if (current.layout != dst_layout) {
            compiled.barriers[compiled.barrier_count] = .{
                .resource = handle,
                .src_access = current.access,
                .dst_access = dst_access,
                .src_layout = current.layout,
                .dst_layout = dst_layout,
            };
            compiled.barrier_count += 1;

            // Update current state
            current.layout = dst_layout;
            current.access = dst_access;
        }
    }

    /// Cull passes that don't contribute to any exported output
    fn cullUnusedPasses(self: *GraphCompiler) void {
        // For now, we don't cull any passes
        // This could be enhanced to remove passes that don't contribute
        // to exported resources (like the backbuffer)
        for (self.graph.passes[0..self.graph.pass_count]) |*p| {
            p.is_culled = false;
        }
    }

    /// Get the compiled passes in execution order
    pub fn getCompiledPasses(self: *const GraphCompiler) []const CompiledPass {
        return self.compiled_passes[0..self.compiled_pass_count];
    }

    /// Get the execution order
    pub fn getExecutionOrder(self: *const GraphCompiler) []const u16 {
        return self.execution_order[0..self.compiled_pass_count];
    }
};

test "GraphCompiler basic compilation" {
    var graph = RenderGraph.init(std.testing.allocator);
    defer graph.deinit();

    // Create resources
    const shadow_map = graph.createDepthBuffer("shadow_map", 2048, 2048, .depth32_float);
    const main_color = graph.createTexture2D("main_color", 1920, 1080, .rgba16_float, resource.ResourceUsage.render_target);

    // Create passes
    const shadow_pass = graph.addPass("shadow", .graphics).?;
    shadow_pass.depth_attachment = .{ .resource = shadow_map };

    const main_pass = graph.addPass("main", .graphics).?;
    _ = main_pass.addColorAttachment(.{ .resource = main_color });
    _ = main_pass.addResourceRead(.{
        .resource = shadow_map,
        .binding = 0,
        .shader_stages = pass.ShaderStageFlags.fragment_only,
    });

    // Compile
    var compiler = GraphCompiler.init(&graph);
    try compiler.compile();

    try std.testing.expect(graph.is_compiled);
    try std.testing.expectEqual(@as(u16, 2), compiler.compiled_pass_count);

    // Shadow pass should execute before main pass
    const order = compiler.getExecutionOrder();
    try std.testing.expectEqual(@as(u16, 0), graph.passes[order[0]].execution_order);
}
