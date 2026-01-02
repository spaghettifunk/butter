//! Render Graph Executor
//!
//! Executes a compiled render graph each frame, managing resource realization,
//! pass execution, and synchronization.

const std = @import("std");
const resource = @import("resource.zig");
const pass_mod = @import("pass.zig");
const graph_mod = @import("graph.zig");
const compiler_mod = @import("compiler.zig");

const ResourceHandle = resource.ResourceHandle;
const RenderPass = pass_mod.RenderPass;
const RenderGraph = graph_mod.RenderGraph;
const ResourceEntry = graph_mod.ResourceEntry;
const GraphCompiler = compiler_mod.GraphCompiler;
const CompiledPass = compiler_mod.CompiledPass;
const ResourceBarrier = compiler_mod.ResourceBarrier;

/// Render pass execution context
/// Passed to pass execute callbacks with all the information needed to render
pub const RenderPassContext = struct {
    /// The render graph being executed
    graph: *RenderGraph,

    /// The current pass being executed
    pass: *const RenderPass,

    /// Current frame index (for double/triple buffering)
    frame_index: u32,

    /// Delta time since last frame
    delta_time: f32,

    /// User data pointer from the pass
    user_data: ?*anyopaque,

    /// Backend-specific command buffer handle (VkCommandBuffer on Vulkan)
    command_buffer_handle: ?*anyopaque = null,

    /// Renderer system reference for drawing operations
    renderer: ?*anyopaque = null,

    /// Get a resource entry by handle
    pub fn getResource(self: *RenderPassContext, handle: ResourceHandle) ?*const ResourceEntry {
        return self.graph.getResourceEntryConst(handle);
    }

    /// Get the pass name
    pub fn getPassName(self: *const RenderPassContext) []const u8 {
        return self.pass.getName();
    }
};

/// Execution error types
pub const ExecuteError = error{
    NotCompiled,
    ResourceRealizationFailed,
    PassExecutionFailed,
    BarrierInsertionFailed,
};

/// Graph executor
pub const GraphExecutor = struct {
    /// The render graph to execute
    graph: *RenderGraph,

    /// The compiler with execution order info
    compiler: *GraphCompiler,

    /// Current frame index
    current_frame: u32 = 0,

    /// Statistics
    passes_executed: u32 = 0,
    barriers_inserted: u32 = 0,

    /// Initialize the executor
    pub fn init(graph_ptr: *RenderGraph, compiler_ptr: *GraphCompiler) GraphExecutor {
        return GraphExecutor{
            .graph = graph_ptr,
            .compiler = compiler_ptr,
        };
    }

    /// Execute the render graph for one frame
    /// command_buffer: Backend-specific command buffer handle (optional)
    /// renderer_ptr: Pointer to RendererSystem for drawing operations (optional)
    pub fn execute(
        self: *GraphExecutor,
        delta_time: f32,
        command_buffer: ?*anyopaque,
        renderer_ptr: ?*anyopaque,
    ) ExecuteError!void {
        if (!self.graph.is_compiled) {
            return ExecuteError.NotCompiled;
        }

        // Reset statistics
        self.passes_executed = 0;
        self.barriers_inserted = 0;

        const frame_index = self.current_frame;

        // Execute passes in compiled order
        const compiled_passes = self.compiler.getCompiledPasses();
        const execution_order = self.compiler.getExecutionOrder();

        for (compiled_passes, 0..) |compiled, order_idx| {
            const pass_idx = execution_order[order_idx];
            const current_pass = &self.graph.passes[pass_idx];

            if (current_pass.is_culled) continue;

            // Insert barriers before this pass
            self.barriers_inserted += compiled.barrier_count;

            // Call the pass execute function
            if (current_pass.execute_fn) |exec_fn| {
                var context = RenderPassContext{
                    .graph = self.graph,
                    .pass = current_pass,
                    .frame_index = frame_index,
                    .delta_time = delta_time,
                    .user_data = current_pass.user_data,
                    .command_buffer_handle = command_buffer,
                    .renderer = renderer_ptr,
                };

                exec_fn(&context);
            }

            self.passes_executed += 1;
        }

        // Advance frame
        self.current_frame +%= 1;
        self.graph.current_frame = self.current_frame;
    }

    /// Get the compiled pass for a given execution order
    pub fn getCompiledPass(self: *const GraphExecutor, order: usize) ?*const CompiledPass {
        const passes = self.compiler.getCompiledPasses();
        if (order >= passes.len) return null;
        return &passes[order];
    }

    /// Get barriers for a specific pass
    pub fn getPassBarriers(self: *const GraphExecutor, order: usize) []const ResourceBarrier {
        const compiled = self.getCompiledPass(order) orelse return &[_]ResourceBarrier{};
        return compiled.barriers[0..compiled.barrier_count];
    }

    /// Get execution statistics
    pub fn getStats(self: *const GraphExecutor) struct { passes: u32, barriers: u32 } {
        return .{
            .passes = self.passes_executed,
            .barriers = self.barriers_inserted,
        };
    }
};

/// Helper to build a simple shadow + main + post render graph
pub fn buildDefaultGraph(
    graph: *RenderGraph,
    width: u32,
    height: u32,
    shadow_size: u32,
) struct {
    shadow_map: ResourceHandle,
    main_color: ResourceHandle,
    main_depth: ResourceHandle,
    backbuffer: ResourceHandle,
} {
    // Create resources
    const shadow_map = graph.createDepthBuffer(
        "shadow_map",
        shadow_size,
        shadow_size,
        .depth32_float,
    );

    const main_color = graph.createTexture2D(
        "main_color",
        width,
        height,
        .rgba16_float,
        resource.ResourceUsage.render_target,
    );

    const main_depth = graph.createDepthBuffer(
        "main_depth",
        width,
        height,
        .depth32_float,
    );

    const backbuffer = graph.importBackbuffer(width, height, .bgra8_unorm);

    // Create shadow pass
    if (graph.addPass("shadow_pass", .graphics)) |shadow_pass| {
        shadow_pass.depth_attachment = .{
            .resource = shadow_map,
            .load_op = .clear,
            .store_op = .store,
            .clear_depth = 1.0,
        };
    }

    // Create main pass
    if (graph.addPass("main_pass", .graphics)) |main_pass| {
        _ = main_pass.addColorAttachment(.{
            .resource = main_color,
            .load_op = .clear,
            .store_op = .store,
            .clear_color = .{ 0.53, 0.81, 0.92, 1.0 }, // Light sky blue (RGB: 135, 206, 235)
        });

        main_pass.depth_attachment = .{
            .resource = main_depth,
            .load_op = .clear,
            .store_op = .dont_care,
        };

        // Read shadow map
        _ = main_pass.addResourceRead(.{
            .resource = shadow_map,
            .binding = 2,
            .shader_stages = pass_mod.ShaderStageFlags.fragment_only,
        });
    }

    // Create grid pass (editor only, renders after main pass clears)
    if (graph.addPass("grid_pass", .graphics)) |grid_pass| {
        _ = grid_pass.addColorAttachment(.{
            .resource = main_color,
            .load_op = .load, // Preserve cleared color
            .store_op = .store,
        });

        grid_pass.depth_attachment = .{
            .resource = main_depth,
            .load_op = .load, // Preserve cleared depth
            .store_op = .dont_care,
            .read_only = false,
        };
    }

    // Create post-process pass
    if (graph.addPass("post_process", .graphics)) |post_pass| {
        _ = post_pass.addColorAttachment(.{
            .resource = backbuffer,
            .load_op = .dont_care,
            .store_op = .store,
        });

        // Read main color
        _ = post_pass.addResourceRead(.{
            .resource = main_color,
            .binding = 0,
            .shader_stages = pass_mod.ShaderStageFlags.fragment_only,
        });
    }

    return .{
        .shadow_map = shadow_map,
        .main_color = main_color,
        .main_depth = main_depth,
        .backbuffer = backbuffer,
    };
}

test "GraphExecutor basic execution" {
    var graph = RenderGraph.init(std.testing.allocator);
    defer graph.deinit();

    // Build a simple graph
    _ = buildDefaultGraph(&graph, 1920, 1080, 2048);

    // Compile
    var compiler = GraphCompiler.init(&graph);
    try compiler.compile();

    // Execute (without command buffer for testing)
    var executor = GraphExecutor.init(&graph, &compiler);
    try executor.execute(0.016, null, null);

    const stats = executor.getStats();
    try std.testing.expectEqual(@as(u32, 3), stats.passes);
}
