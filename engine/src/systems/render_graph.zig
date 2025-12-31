//! Render Graph System
//!
//! High-level system that manages the render graph lifecycle including
//! initialization, compilation, execution, and shutdown.
//! This provides the main integration point for the engine.

const std = @import("std");
const logger = @import("../core/logging.zig");
const ctx = @import("../context.zig");
const memory = @import("memory.zig");
const renderer = @import("../renderer/renderer.zig");

const render_graph_mod = @import("../renderer/render_graph/mod.zig");
const graph_mod = render_graph_mod.graph;
const compiler_mod = render_graph_mod.compiler;
const executor_mod = render_graph_mod.executor;
const resource = render_graph_mod.resource;
const pass_mod = render_graph_mod.pass;

const RenderGraph = graph_mod.RenderGraph;
const GraphCompiler = compiler_mod.GraphCompiler;
const GraphExecutor = executor_mod.GraphExecutor;
const ResourceHandle = resource.ResourceHandle;
const RenderPass = pass_mod.RenderPass;

/// Render Graph System
/// Manages the complete lifecycle of a render graph
pub const RenderGraphSystem = struct {
    /// The render graph
    graph: RenderGraph,

    /// The compiler
    compiler: GraphCompiler,

    /// The executor
    executor: GraphExecutor,

    /// Resource handles for default graph
    shadow_map: ResourceHandle = ResourceHandle.invalid,
    main_color: ResourceHandle = ResourceHandle.invalid,
    main_depth: ResourceHandle = ResourceHandle.invalid,
    backbuffer: ResourceHandle = ResourceHandle.invalid,

    /// Current dimensions
    width: u32 = 1280,
    height: u32 = 720,
    shadow_map_size: u32 = 2048,

    /// Whether the system is initialized
    is_initialized: bool = false,

    /// Initialize the render graph system
    pub fn initialize(width: u32, height: u32) bool {
        // Use the standard allocator via page_allocator for simplicity
        // In a real scenario, you might use the memory system's allocator
        const allocator = std.heap.page_allocator;

        instance = RenderGraphSystem{
            .graph = RenderGraph.init(allocator),
            .compiler = undefined,
            .executor = undefined,
            .width = width,
            .height = height,
        };

        // Initialize compiler with pointer to graph
        instance.compiler = GraphCompiler.init(&instance.graph);

        // Build the default render graph
        const resources = executor_mod.buildDefaultGraph(
            &instance.graph,
            width,
            height,
            instance.shadow_map_size,
        );

        instance.shadow_map = resources.shadow_map;
        instance.main_color = resources.main_color;
        instance.main_depth = resources.main_depth;
        instance.backbuffer = resources.backbuffer;

        // Compile the graph
        instance.compiler.compile() catch |err| {
            logger.err("Failed to compile render graph: {}", .{err});
            return false;
        };

        // Initialize executor
        instance.executor = GraphExecutor.init(&instance.graph, &instance.compiler);

        instance.is_initialized = true;

        // Register with context
        ctx.get().render_graph = &instance.graph;

        logger.info("Render graph system initialized with {} passes, {} resources", .{
            instance.graph.pass_count,
            instance.graph.resource_count,
        });

        // Debug print the graph
        if (true) { // Set to true for debug output
            var buffer: [4096]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buffer);
            instance.graph.debugPrint(fbs.writer()) catch {};
            const output = fbs.getWritten();
            if (output.len > 0) {
                logger.debug("{s}", .{output});
            }
        }

        return true;
    }

    /// Shutdown the render graph system
    pub fn shutdown() void {
        if (!instance.is_initialized) return;

        ctx.get().render_graph = null;
        instance.graph.deinit();
        instance.is_initialized = false;

        logger.info("Render graph system shutdown.", .{});
    }

    /// Handle resize events
    pub fn onResized(width: u32, height: u32) void {
        if (!instance.is_initialized) return;

        instance.width = width;
        instance.height = height;

        // In a full implementation, we would:
        // 1. Destroy existing resources
        // 2. Recreate resources with new dimensions
        // 3. Recompile the graph

        // For now, just invalidate the graph
        instance.graph.invalidate();

        logger.debug("Render graph resized to {}x{}", .{ width, height });
    }

    /// Execute the render graph for one frame
    /// Call this during the frame to execute all render passes
    pub fn execute(delta_time: f32) bool {
        if (!instance.is_initialized) return false;

        // Recompile if needed
        if (instance.graph.needsRecompile()) {
            instance.compiler.compile() catch |err| {
                logger.err("Failed to recompile render graph: {}", .{err});
                return false;
            };
        }

        // Get command buffer and renderer from the engine context
        const renderer_sys = ctx.get().renderer orelse {
            logger.warn("No renderer available for render graph execution", .{});
            return false;
        };

        // Get current command buffer from the backend
        const command_buffer = renderer_sys.backend.getCurrentCommandBuffer();

        // Execute the graph with command buffer and renderer reference
        instance.executor.execute(delta_time, command_buffer, renderer_sys) catch |err| {
            logger.err("Failed to execute render graph: {}", .{err});
            return false;
        };

        return true;
    }

    /// Get execution statistics
    pub fn getStats() struct { passes: u32, barriers: u32 } {
        if (!instance.is_initialized) return .{ .passes = 0, .barriers = 0 };
        return instance.executor.getStats();
    }

    /// Get a pass by name for attaching execute callbacks
    pub fn getPass(name: []const u8) ?*RenderPass {
        if (!instance.is_initialized) return null;
        return instance.graph.getPass(name);
    }

    /// Get a resource handle by name
    pub fn getResource(name: []const u8) ?ResourceHandle {
        if (!instance.is_initialized) return null;
        return instance.graph.getResource(name);
    }

    /// Get the shadow map handle
    pub fn getShadowMap() ResourceHandle {
        return instance.shadow_map;
    }

    /// Get the main color buffer handle
    pub fn getMainColor() ResourceHandle {
        return instance.main_color;
    }

    /// Get the main depth buffer handle
    pub fn getMainDepth() ResourceHandle {
        return instance.main_depth;
    }

    /// Get the backbuffer handle
    pub fn getBackbuffer() ResourceHandle {
        return instance.backbuffer;
    }

    /// Get the underlying render graph
    pub fn getGraph() ?*RenderGraph {
        if (!instance.is_initialized) return null;
        return &instance.graph;
    }

    /// Set an execute callback for a named pass
    /// This allows the game or engine to register custom rendering code for specific passes
    pub fn setPassCallback(
        pass_name: []const u8,
        callback: *const fn (*render_graph_mod.RenderPassContext) void,
        user_data: ?*anyopaque,
    ) bool {
        if (!instance.is_initialized) return false;

        if (instance.graph.getPass(pass_name)) |pass_ptr| {
            pass_ptr.execute_fn = callback;
            pass_ptr.user_data = user_data;
            return true;
        }

        logger.warn("Pass '{s}' not found when setting callback", .{pass_name});
        return false;
    }

    /// Clear the execute callback for a named pass
    pub fn clearPassCallback(pass_name: []const u8) bool {
        if (!instance.is_initialized) return false;

        if (instance.graph.getPass(pass_name)) |pass_ptr| {
            pass_ptr.execute_fn = null;
            pass_ptr.user_data = null;
            return true;
        }

        return false;
    }
};

// Private instance storage
var instance: RenderGraphSystem = undefined;

/// Get the render graph system instance
pub fn getSystem() ?*RenderGraphSystem {
    if (!instance.is_initialized) return null;
    return &instance;
}
