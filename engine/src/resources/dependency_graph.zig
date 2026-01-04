//! Dependency Graph - Manages resource dependencies
//!
//! Provides:
//! - Cycle detection
//! - Topological sort for load ordering
//! - Recursive dependency collection
//! - Dependency validation

const std = @import("std");
const registry = @import("registry.zig");

/// Dependency Graph
pub const DependencyGraph = struct {
    registry_ref: *registry.ResourceRegistry,

    pub fn init(registry_ref: *registry.ResourceRegistry) DependencyGraph {
        return DependencyGraph{
            .registry_ref = registry_ref,
        };
    }

    /// Add a dependency relationship with cycle detection
    pub fn addDependency(
        self: *DependencyGraph,
        dependent_id: u32,
        dependency_id: u32,
    ) !void {
        // Check for self-dependency
        if (dependent_id == dependency_id) {
            return error.SelfDependency;
        }

        // Check if this would create a cycle
        if (try self.wouldCreateCycle(dependent_id, dependency_id)) {
            return error.CircularDependency;
        }

        // Add the dependency
        try self.registry_ref.addDependency(dependent_id, dependency_id);
    }

    /// Remove a dependency relationship
    pub fn removeDependency(
        self: *DependencyGraph,
        dependent_id: u32,
        dependency_id: u32,
    ) void {
        self.registry_ref.removeDependency(dependent_id, dependency_id);
    }

    /// Check if adding a dependency would create a cycle
    pub fn wouldCreateCycle(
        self: *DependencyGraph,
        dependent_id: u32,
        new_dependency_id: u32,
    ) !bool {
        // If new_dependency already depends on dependent (directly or indirectly),
        // then adding dependent -> new_dependency would create a cycle

        var visited = std.AutoHashMap(u32, void).init(self.registry_ref.allocator);
        defer visited.deinit();

        return try self.canReach(new_dependency_id, dependent_id, &visited);
    }

    /// Check if we can reach target from source following dependencies
    fn canReach(
        self: *DependencyGraph,
        source: u32,
        target: u32,
        visited: *std.AutoHashMap(u32, void),
    ) !bool {
        if (source == target) return true;

        if (visited.contains(source)) return false;
        try visited.put(source, {});

        const meta = self.registry_ref.get(source) orelse return false;

        for (meta.dependencies.items) |dep_id| {
            if (try self.canReach(dep_id, target, visited)) {
                return true;
            }
        }

        return false;
    }

    /// Get all dependencies in topological order (dependencies before dependents)
    /// Returns metadata IDs in the order they should be loaded
    pub fn getLoadOrder(
        self: *DependencyGraph,
        metadata_id: u32,
        allocator: std.mem.Allocator,
    ) ![]u32 {
        var result = std.ArrayList(u32).init(allocator);
        errdefer result.deinit();

        var visited = std.AutoHashMap(u32, void).init(allocator);
        defer visited.deinit();

        try self.topologicalSortRecursive(metadata_id, &visited, &result);

        return try result.toOwnedSlice();
    }

    fn topologicalSortRecursive(
        self: *DependencyGraph,
        metadata_id: u32,
        visited: *std.AutoHashMap(u32, void),
        result: *std.ArrayList(u32),
    ) !void {
        if (visited.contains(metadata_id)) return;
        try visited.put(metadata_id, {});

        const meta = self.registry_ref.get(metadata_id) orelse return;

        // Visit all dependencies first (depth-first)
        for (meta.dependencies.items) |dep_id| {
            try self.topologicalSortRecursive(dep_id, visited, result);
        }

        // Add this node after all its dependencies
        try result.append(metadata_id);
    }

    /// Get all resources that depend on this one (directly or indirectly)
    /// Useful for hot-reload cascade
    pub fn getAllDependents(
        self: *DependencyGraph,
        metadata_id: u32,
        allocator: std.mem.Allocator,
    ) ![]u32 {
        var result = std.ArrayList(u32).init(allocator);
        errdefer result.deinit();

        var visited = std.AutoHashMap(u32, void).init(allocator);
        defer visited.deinit();

        try self.collectDependentsRecursive(metadata_id, &visited, &result);

        return try result.toOwnedSlice();
    }

    fn collectDependentsRecursive(
        self: *DependencyGraph,
        metadata_id: u32,
        visited: *std.AutoHashMap(u32, void),
        result: *std.ArrayList(u32),
    ) !void {
        const meta = self.registry_ref.get(metadata_id) orelse return;

        for (meta.dependents.items) |dependent_id| {
            if (visited.contains(dependent_id)) continue;
            try visited.put(dependent_id, {});

            try result.append(dependent_id);

            // Recursively collect dependents of dependents
            try self.collectDependentsRecursive(dependent_id, visited, result);
        }
    }

    /// Get all dependencies (direct and indirect) of a resource
    pub fn getAllDependencies(
        self: *DependencyGraph,
        metadata_id: u32,
        allocator: std.mem.Allocator,
    ) ![]u32 {
        var result = std.ArrayList(u32).init(allocator);
        errdefer result.deinit();

        var visited = std.AutoHashMap(u32, void).init(allocator);
        defer visited.deinit();

        try self.collectDependenciesRecursive(metadata_id, &visited, &result);

        return try result.toOwnedSlice();
    }

    fn collectDependenciesRecursive(
        self: *DependencyGraph,
        metadata_id: u32,
        visited: *std.AutoHashMap(u32, void),
        result: *std.ArrayList(u32),
    ) !void {
        const meta = self.registry_ref.get(metadata_id) orelse return;

        for (meta.dependencies.items) |dependency_id| {
            if (visited.contains(dependency_id)) continue;
            try visited.put(dependency_id, {});

            try result.append(dependency_id);

            // Recursively collect dependencies of dependencies
            try self.collectDependenciesRecursive(dependency_id, visited, result);
        }
    }

    /// Validate the entire dependency graph for cycles
    pub fn validate(self: *DependencyGraph, allocator: std.mem.Allocator) !void {
        var visited = std.AutoHashMap(u32, void).init(allocator);
        defer visited.deinit();

        var rec_stack = std.AutoHashMap(u32, void).init(allocator);
        defer rec_stack.deinit();

        for (self.registry_ref.metadata.items, 0..) |_, i| {
            const metadata_id: u32 = @intCast(i + 1);
            if (!visited.contains(metadata_id)) {
                if (try self.hasCycleDFS(metadata_id, &visited, &rec_stack)) {
                    return error.CycleDetected;
                }
            }
        }
    }

    fn hasCycleDFS(
        self: *DependencyGraph,
        metadata_id: u32,
        visited: *std.AutoHashMap(u32, void),
        rec_stack: *std.AutoHashMap(u32, void),
    ) !bool {
        try visited.put(metadata_id, {});
        try rec_stack.put(metadata_id, {});

        const meta = self.registry_ref.get(metadata_id) orelse return false;

        for (meta.dependencies.items) |dep_id| {
            if (!visited.contains(dep_id)) {
                if (try self.hasCycleDFS(dep_id, visited, rec_stack)) {
                    return true;
                }
            } else if (rec_stack.contains(dep_id)) {
                // Back edge found - cycle detected
                return true;
            }
        }

        _ = rec_stack.remove(metadata_id);
        return false;
    }
};

// Tests
const testing = std.testing;

test "DependencyGraph: simple dependency" {
    var reg = registry.ResourceRegistry.init(testing.allocator);
    defer reg.deinit();

    var graph = DependencyGraph.init(&reg);

    const tex_id = try reg.register("texture.png", .texture);
    const mat_id = try reg.register("material.bmt", .material);

    // Material depends on texture
    try graph.addDependency(mat_id, tex_id);

    // Get load order
    const load_order = try graph.getLoadOrder(mat_id, testing.allocator);
    defer testing.allocator.free(load_order);

    // Should load texture first, then material
    try testing.expectEqual(@as(usize, 2), load_order.len);
    try testing.expectEqual(tex_id, load_order[0]);
    try testing.expectEqual(mat_id, load_order[1]);
}

test "DependencyGraph: cycle detection" {
    var reg = registry.ResourceRegistry.init(testing.allocator);
    defer reg.deinit();

    var graph = DependencyGraph.init(&reg);

    const a_id = try reg.register("a", .material);
    const b_id = try reg.register("b", .material);
    const c_id = try reg.register("c", .material);

    // a -> b -> c
    try graph.addDependency(a_id, b_id);
    try graph.addDependency(b_id, c_id);

    // c -> a would create cycle
    const result = graph.addDependency(c_id, a_id);
    try testing.expectError(error.CircularDependency, result);
}

test "DependencyGraph: self dependency" {
    var reg = registry.ResourceRegistry.init(testing.allocator);
    defer reg.deinit();

    var graph = DependencyGraph.init(&reg);

    const a_id = try reg.register("a", .material);

    // Self-dependency should be rejected
    const result = graph.addDependency(a_id, a_id);
    try testing.expectError(error.SelfDependency, result);
}

test "DependencyGraph: complex dependency tree" {
    var reg = registry.ResourceRegistry.init(testing.allocator);
    defer reg.deinit();

    var graph = DependencyGraph.init(&reg);

    //     mat
    //    /   \
    //  tex1  tex2
    //   |
    // shader

    const shader_id = try reg.register("shader.glsl", .material);
    const tex1_id = try reg.register("tex1.png", .texture);
    const tex2_id = try reg.register("tex2.png", .texture);
    const mat_id = try reg.register("material.bmt", .material);

    try graph.addDependency(tex1_id, shader_id);
    try graph.addDependency(mat_id, tex1_id);
    try graph.addDependency(mat_id, tex2_id);

    // Get load order
    const load_order = try graph.getLoadOrder(mat_id, testing.allocator);
    defer testing.allocator.free(load_order);

    // shader must come before tex1
    // tex1 and tex2 must come before mat
    // mat must be last
    try testing.expectEqual(@as(usize, 4), load_order.len);
    try testing.expectEqual(mat_id, load_order[3]); // Material is last

    // Find positions
    var shader_pos: usize = 0;
    var tex1_pos: usize = 0;
    var tex2_pos: usize = 0;
    for (load_order, 0..) |id, i| {
        if (id == shader_id) shader_pos = i;
        if (id == tex1_id) tex1_pos = i;
        if (id == tex2_id) tex2_pos = i;
    }

    // Verify ordering constraints
    try testing.expect(shader_pos < tex1_pos); // shader before tex1
    try testing.expect(tex1_pos < 3); // tex1 before mat
    try testing.expect(tex2_pos < 3); // tex2 before mat
}

test "DependencyGraph: get all dependents" {
    var reg = registry.ResourceRegistry.init(testing.allocator);
    defer reg.deinit();

    var graph = DependencyGraph.init(&reg);

    const tex_id = try reg.register("texture.png", .texture);
    const mat1_id = try reg.register("mat1.bmt", .material);
    const mat2_id = try reg.register("mat2.bmt", .material);
    const geo_id = try reg.register("mesh.obj", .geometry);

    // tex -> mat1 -> geo
    //    \-> mat2 /
    try graph.addDependency(mat1_id, tex_id);
    try graph.addDependency(mat2_id, tex_id);
    try graph.addDependency(geo_id, mat1_id);
    try graph.addDependency(geo_id, mat2_id);

    // Get all dependents of texture
    const dependents = try graph.getAllDependents(tex_id, testing.allocator);
    defer testing.allocator.free(dependents);

    // Should include mat1, mat2, and geo
    try testing.expectEqual(@as(usize, 3), dependents.len);
}
