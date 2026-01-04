//! Draw List
//!
//! Provides draw call batching, sorting, and filtering for render passes.
//! Draw calls are collected during the frame and then filtered per-pass
//! based on material participation.

const std = @import("std");
const math_types = @import("../../math/types.zig");
const context = @import("../../context.zig");
const jobs = @import("../../systems/jobs.zig");

/// Maximum draw calls per frame
pub const MAX_DRAW_CALLS: usize = 8192;

/// Threshold for switching to parallel sorting
pub const PARALLEL_SORT_THRESHOLD: usize = 512;

/// Draw call information
pub const DrawCall = struct {
    /// Pointer to geometry data (opaque, backend-specific)
    geometry: *const anyopaque,

    /// Material ID for this draw call
    material_id: u32,

    /// Model transformation matrix
    model_matrix: math_types.Mat4,

    /// Sort key for batching (material, distance, etc.)
    sort_key: u64,

    /// Custom user data
    user_data: ?*anyopaque = null,
};

/// Draw list for collecting and organizing draw calls
pub const DrawList = struct {
    /// All draw calls collected this frame
    calls: std.ArrayList(DrawCall),

    /// Scratch buffer for filtered results
    filtered_indices: std.ArrayList(usize),

    /// Allocator
    allocator: std.mem.Allocator,

    /// Initialize a new draw list
    pub fn init(allocator: std.mem.Allocator) DrawList {
        return DrawList{
            .calls = std.ArrayList(DrawCall).init(allocator),
            .filtered_indices = std.ArrayList(usize).init(allocator),
            .allocator = allocator,
        };
    }

    /// Deinitialize the draw list
    pub fn deinit(self: *DrawList) void {
        self.calls.deinit();
        self.filtered_indices.deinit();
    }

    /// Clear all draw calls (call at frame start)
    pub fn clear(self: *DrawList) void {
        self.calls.clearRetainingCapacity();
        self.filtered_indices.clearRetainingCapacity();
    }

    /// Add a draw call to the list
    pub fn addDrawCall(
        self: *DrawList,
        geometry: *const anyopaque,
        material_id: u32,
        model_matrix: math_types.Mat4,
    ) void {
        self.calls.append(.{
            .geometry = geometry,
            .material_id = material_id,
            .model_matrix = model_matrix,
            .sort_key = computeSortKey(material_id, 0),
        }) catch return;
    }

    /// Add a draw call with distance for sorting
    pub fn addDrawCallWithDistance(
        self: *DrawList,
        geometry: *const anyopaque,
        material_id: u32,
        model_matrix: math_types.Mat4,
        distance_sq: f32,
    ) void {
        self.calls.append(.{
            .geometry = geometry,
            .material_id = material_id,
            .model_matrix = model_matrix,
            .sort_key = computeSortKeyWithDistance(material_id, distance_sq),
        }) catch return;
    }

    /// Sort draw calls by material (for minimizing state changes)
    pub fn sortByMaterial(self: *DrawList) void {
        std.mem.sort(DrawCall, self.calls.items, {}, struct {
            fn lessThan(_: void, a: DrawCall, b: DrawCall) bool {
                return a.material_id < b.material_id;
            }
        }.lessThan);
    }

    /// Sort draw calls by sort key (material + distance)
    pub fn sortBySortKey(self: *DrawList) void {
        std.mem.sort(DrawCall, self.calls.items, {}, struct {
            fn lessThan(_: void, a: DrawCall, b: DrawCall) bool {
                return a.sort_key < b.sort_key;
            }
        }.lessThan);
    }

    /// Sort draw calls front-to-back (for early-z optimization)
    pub fn sortFrontToBack(self: *DrawList) void {
        std.mem.sort(DrawCall, self.calls.items, {}, struct {
            fn lessThan(_: void, a: DrawCall, b: DrawCall) bool {
                // Lower bits contain distance, lower = closer
                return (a.sort_key & 0xFFFFFFFF) < (b.sort_key & 0xFFFFFFFF);
            }
        }.lessThan);
    }

    /// Sort draw calls back-to-front (for transparency)
    pub fn sortBackToFront(self: *DrawList) void {
        std.mem.sort(DrawCall, self.calls.items, {}, struct {
            fn lessThan(_: void, a: DrawCall, b: DrawCall) bool {
                // Lower bits contain distance, higher = farther
                return (a.sort_key & 0xFFFFFFFF) > (b.sort_key & 0xFFFFFFFF);
            }
        }.lessThan);
    }

    /// Sort draw calls using parallel radix sort (for large lists)
    /// Automatically falls back to serial sort if job system is unavailable or list is small
    pub fn sortBySortKeyParallel(self: *DrawList) !void {
        // Use serial sort for small lists or if job system unavailable
        if (self.calls.items.len < PARALLEL_SORT_THRESHOLD) {
            self.sortBySortKey();
            return;
        }

        const jobs_sys = context.get().jobs orelse {
            self.sortBySortKey();
            return;
        };

        try radixSortParallel(self.calls.items, jobs_sys);
    }

    /// Get all draw calls
    pub fn getDrawCalls(self: *const DrawList) []const DrawCall {
        return self.calls.items;
    }

    /// Get draw call count
    pub fn count(self: *const DrawList) usize {
        return self.calls.items.len;
    }

    /// Filter draw calls by a predicate function
    /// Returns indices into the draw call array
    pub fn filterBy(
        self: *DrawList,
        predicate: *const fn (call: *const DrawCall, user_data: ?*anyopaque) bool,
        user_data: ?*anyopaque,
    ) []const usize {
        self.filtered_indices.clearRetainingCapacity();

        for (self.calls.items, 0..) |*call, i| {
            if (predicate(call, user_data)) {
                self.filtered_indices.append(i) catch continue;
            }
        }

        return self.filtered_indices.items;
    }

    /// Get a draw call by index
    pub fn get(self: *const DrawList, index: usize) ?*const DrawCall {
        if (index >= self.calls.items.len) return null;
        return &self.calls.items[index];
    }
};

/// Compute a sort key from material ID
fn computeSortKey(material_id: u32, distance_bits: u32) u64 {
    // Upper 32 bits: material ID
    // Lower 32 bits: distance (as integer bits)
    return (@as(u64, material_id) << 32) | @as(u64, distance_bits);
}

/// Compute a sort key from material ID and squared distance
fn computeSortKeyWithDistance(material_id: u32, distance_sq: f32) u64 {
    // Convert distance to integer representation for sorting
    // We use the raw bits of the float, which preserves ordering for positive floats
    const distance_bits: u32 = @bitCast(distance_sq);
    return computeSortKey(material_id, distance_bits);
}

/// Parallel radix sort for DrawCall arrays
/// Sorts by sort_key (u64) using 8-bit radix (8 passes)
fn radixSortParallel(items: []DrawCall, jobs_sys: *jobs.JobScheduler) !void {
    const allocator = std.heap.page_allocator;

    // Allocate temporary buffer for sorting
    const temp = try allocator.alloc(DrawCall, items.len);
    defer allocator.free(temp);

    // We'll do 8 passes (8 bits per pass for u64 = 64 bits / 8 = 8 passes)
    const RADIX_BITS = 8;
    const RADIX_SIZE = 1 << RADIX_BITS; // 256
    const NUM_PASSES = 8; // 64 bits / 8 bits per pass

    // Allocate histogram arrays for parallel counting
    const num_workers = jobs_sys.worker_count;
    const histograms = try allocator.alloc([RADIX_SIZE]u32, num_workers);
    defer allocator.free(histograms);

    var src = items;
    var dst = temp;

    // Process each 8-bit chunk
    var pass: usize = 0;
    while (pass < NUM_PASSES) : (pass += 1) {
        const shift = @as(u6, @intCast(pass * RADIX_BITS));

        // Clear histograms
        for (histograms) |*hist| {
            @memset(hist, 0);
        }

        // Phase 1: Parallel histogram computation
        const batch_size = (src.len + num_workers - 1) / num_workers;
        const counter = try jobs_sys.counter_pool.allocate();
        counter.init(@intCast(num_workers));
        const generation = counter.generation.load(.acquire);

        const HistogramArgs = struct {
            worker_id: usize,
            items_slice: []const DrawCall,
            shift_amount: u6,
            histogram: *[RADIX_SIZE]u32,
            counter_ptr: *jobs.JobCounter,
        };

        const computeHistogram = struct {
            fn execute(args: HistogramArgs) void {
                for (args.items_slice) |item| {
                    const digit = @as(u8, @truncate(item.sort_key >> args.shift_amount));
                    args.histogram[digit] += 1;
                }
                _ = args.counter_ptr.decrement();
            }
        }.execute;

        // Submit histogram jobs
        var worker_id: usize = 0;
        while (worker_id < num_workers) : (worker_id += 1) {
            const start = worker_id * batch_size;
            if (start >= src.len) break;
            const end = @min(start + batch_size, src.len);

            const args = HistogramArgs{
                .worker_id = worker_id,
                .items_slice = src[start..end],
                .shift_amount = shift,
                .histogram = &histograms[worker_id],
                .counter_ptr = counter,
            };
            _ = try jobs_sys.submit(computeHistogram, .{args});
        }

        const handle = jobs.JobHandle{ .counter = counter, .generation = generation };
        jobs_sys.wait(handle);
        jobs_sys.counter_pool.release(counter);

        // Phase 2: Combine histograms and compute prefix sums (serial - fast enough)
        var global_histogram: [RADIX_SIZE]u32 = [_]u32{0} ** RADIX_SIZE;
        for (histograms) |hist| {
            for (0..RADIX_SIZE) |i| {
                global_histogram[i] += hist[i];
            }
        }

        // Convert to prefix sum (exclusive scan)
        var sum: u32 = 0;
        for (0..RADIX_SIZE) |i| {
            const count = global_histogram[i];
            global_histogram[i] = sum;
            sum += count;
        }

        // Phase 3: Parallel scatter to destination
        // Each worker needs its own local offsets
        const local_offsets = try allocator.alloc([RADIX_SIZE]u32, num_workers);
        defer allocator.free(local_offsets);

        // Initialize local offsets from global histogram
        for (local_offsets, 0..) |*offset, wid| {
            @memcpy(offset, &global_histogram);

            // Add the counts from previous workers for this bucket
            if (wid > 0) {
                for (0..RADIX_SIZE) |bucket| {
                    var prev_count: u32 = 0;
                    for (0..wid) |prev_wid| {
                        prev_count += histograms[prev_wid][bucket];
                    }
                    offset[bucket] += prev_count;
                }
            }
        }

        const scatter_counter = try jobs_sys.counter_pool.allocate();
        scatter_counter.init(@intCast(num_workers));
        const scatter_generation = scatter_counter.generation.load(.acquire);

        const ScatterArgs = struct {
            worker_id: usize,
            src_slice: []const DrawCall,
            dst_buffer: []DrawCall,
            shift_amount: u6,
            offsets: *[RADIX_SIZE]u32,
            counter_ptr: *jobs.JobCounter,
        };

        const scatterItems = struct {
            fn execute(args: ScatterArgs) void {
                for (args.src_slice) |item| {
                    const digit = @as(u8, @truncate(item.sort_key >> args.shift_amount));
                    const pos = args.offsets[digit];
                    args.dst_buffer[pos] = item;
                    args.offsets[digit] += 1;
                }
                _ = args.counter_ptr.decrement();
            }
        }.execute;

        // Submit scatter jobs
        worker_id = 0;
        while (worker_id < num_workers) : (worker_id += 1) {
            const start = worker_id * batch_size;
            if (start >= src.len) break;
            const end = @min(start + batch_size, src.len);

            const args = ScatterArgs{
                .worker_id = worker_id,
                .src_slice = src[start..end],
                .dst_buffer = dst,
                .shift_amount = shift,
                .offsets = &local_offsets[worker_id],
                .counter_ptr = scatter_counter,
            };
            _ = try jobs_sys.submit(scatterItems, .{args});
        }

        const scatter_handle = jobs.JobHandle{ .counter = scatter_counter, .generation = scatter_generation };
        jobs_sys.wait(scatter_handle);
        jobs_sys.counter_pool.release(scatter_counter);

        // Swap buffers for next pass
        const tmp = src;
        src = dst;
        dst = tmp;
    }

    // If odd number of passes, copy result back to original array
    if (NUM_PASSES % 2 == 1) {
        @memcpy(items, src);
    }
}

/// Per-pass draw list that filters the main draw list
pub const PassDrawList = struct {
    /// Reference to the main draw list
    main_list: *const DrawList,

    /// Indices of draw calls that participate in this pass
    indices: std.ArrayList(usize),

    /// Pass name for filtering
    pass_name: [64]u8 = [_]u8{0} ** 64,

    /// Initialize
    pub fn init(allocator: std.mem.Allocator, main: *const DrawList) PassDrawList {
        return PassDrawList{
            .main_list = main,
            .indices = std.ArrayList(usize).init(allocator),
        };
    }

    /// Deinitialize
    pub fn deinit(self: *PassDrawList) void {
        self.indices.deinit();
    }

    /// Set the pass name
    pub fn setPassName(self: *PassDrawList, name: []const u8) void {
        const copy_len = @min(name.len, 63);
        @memcpy(self.pass_name[0..copy_len], name[0..copy_len]);
        self.pass_name[copy_len] = 0;
    }

    /// Get the pass name
    pub fn getPassName(self: *const PassDrawList) []const u8 {
        return std.mem.sliceTo(&self.pass_name, 0);
    }

    /// Clear the filtered indices
    pub fn clear(self: *PassDrawList) void {
        self.indices.clearRetainingCapacity();
    }

    /// Build the filtered list using a material system callback
    /// The callback should return true if the material participates in this pass
    pub fn buildForPass(
        self: *PassDrawList,
        materialParticipatesInPass: *const fn (material_id: u32, pass_name: []const u8) bool,
    ) void {
        self.clear();

        const pass_name = self.getPassName();

        for (self.main_list.calls.items, 0..) |call, i| {
            if (materialParticipatesInPass(call.material_id, pass_name)) {
                self.indices.append(i) catch continue;
            }
        }
    }

    /// Get the number of draw calls for this pass
    pub fn count(self: *const PassDrawList) usize {
        return self.indices.items.len;
    }

    /// Iterate over draw calls for this pass
    pub fn iterate(self: *const PassDrawList) PassDrawIterator {
        return PassDrawIterator{
            .pass_list = self,
            .index = 0,
        };
    }
};

/// Iterator for pass draw calls
pub const PassDrawIterator = struct {
    pass_list: *const PassDrawList,
    index: usize,

    pub fn next(self: *PassDrawIterator) ?*const DrawCall {
        if (self.index >= self.pass_list.indices.items.len) return null;

        const main_index = self.pass_list.indices.items[self.index];
        self.index += 1;

        return self.pass_list.main_list.get(main_index);
    }

    pub fn reset(self: *PassDrawIterator) void {
        self.index = 0;
    }
};

test "DrawList basic operations" {
    var list = DrawList.init(std.testing.allocator);
    defer list.deinit();

    // Add some draw calls
    const dummy_geo: u32 = 0;
    const identity = math_types.Mat4{ .elements = .{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    } };

    list.addDrawCall(@ptrCast(&dummy_geo), 1, identity);
    list.addDrawCall(@ptrCast(&dummy_geo), 2, identity);
    list.addDrawCall(@ptrCast(&dummy_geo), 1, identity);

    try std.testing.expectEqual(@as(usize, 3), list.count());

    // Sort by material
    list.sortByMaterial();

    const calls = list.getDrawCalls();
    try std.testing.expectEqual(@as(u32, 1), calls[0].material_id);
    try std.testing.expectEqual(@as(u32, 1), calls[1].material_id);
    try std.testing.expectEqual(@as(u32, 2), calls[2].material_id);
}
