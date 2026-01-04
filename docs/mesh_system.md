# Mesh System Implementation Plan

**Goal**: Replace Geometry system with MeshAsset - a GPU-first, immutable mesh system with submesh support.

**Principles**: Follow existing patterns (MaterialSystem, TextureSystem), keep universal Vertex3D format, materials in instances not assets, dynamic geometry via MeshBuilder rebuilds.

---

## Architecture Overview

```
MeshAsset (GPU resource)          MeshInstance (scene entity)
├─ Vertex/Index buffers           ├─ Transform (Mat4)
├─ Submeshes (ranges + bounds)    ├─ MeshAssetHandle
├─ Precomputed bounds (AABB)      └─ Materials[32] (per submesh)
└─ Vulkan/Metal GPU data

MeshBuilder (CPU construction)    MeshAssetSystem (subsystem)
├─ Push vertices/indices          ├─ Ref-counting
├─ Generate normals/tangents      ├─ Name-based cache
├─ Compute bounds                 ├─ GPU lifecycle
└─ Validate → MeshAsset           └─ Async loading (job system)
```

---

## Implementation Phases

### Phase 1: Core Types & Builder (Day 1-2) ✅ Completed

**New Files:**

- `engine/src/resources/mesh_asset_types.zig` - MeshAsset, Submesh, MeshGpuData
- `engine/src/systems/mesh_builder.zig` - CPU-side construction
- `engine/src/scene/mesh_instance.zig` - Scene entity wrapper

**Key Structures:**

```zig
// mesh_asset_types.zig
pub const Submesh = struct {
    name: [64]u8,
    vertex_offset: u32, vertex_count: u32,
    index_offset: u32, index_count: u32,
    bounding_min/max/center/radius: [3]f32 + f32,
};

pub const MeshAsset = struct {
    id: u32, generation: u32,
    vertex_count: u32, index_count: u32,
    index_type: IndexType,
    vertex_layout: VertexLayout = .vertex3d,
    submeshes: [32]Submesh,
    submesh_count: u8,
    bounding_min/max/center/radius: [3]f32 + f32,
    gpu_data: ?*MeshGpuData,
};

pub const MeshGpuData = union(BackendType) {
    vulkan: struct { vertex_buffer, index_buffer },
    metal: struct { vertex_buffer, index_buffer },
};

// mesh_builder.zig
pub const MeshBuilder = struct {
    vertices: ArrayList(Vertex3D),
    indices: ArrayList(u32),
    submeshes: [32]Submesh,
    submesh_count: u8,

    pub fn addVertex(vertex: Vertex3D) void
    pub fn addIndex(index: u32) void
    pub fn beginSubmesh(name: []const u8) void
    pub fn endSubmesh() !void
    pub fn computeNormals() void
    pub fn computeTangents() void  // reuse OBJ loader code
    pub fn finalize(name: []const u8) !void
};

// mesh_instance.zig
pub const MeshInstance = struct {
    mesh_handle: MeshAssetHandle,
    transform: Mat4,
    materials: [32]MaterialHandle,
    material_count: u8,
    instance_id: u32, flags: u32,
};
```

**Pattern**: Copy MaterialSystem structure (see [material.zig:78-100](engine/src/systems/material.zig#L78-L100))

---

### Phase 2: Subsystem & Resource Integration (Day 2-3) ✅ Completed

**New File:**

- `engine/src/systems/mesh_asset.zig` - Main subsystem (replaces geometry.zig)

**Modified Files:**

- `engine/src/resources/handle.zig` - Add MeshAssetHandle

  - Add `pub const MeshAsset = opaque {};` after line 46
  - Add `pub const MeshAssetHandle = ResourceHandle(MeshAsset);` after line 55
  - Add `.mesh_asset` to ResourceType enum at line 58
  - Add `fromMeshAsset()` and `toMeshAsset()` methods to AnyResourceHandle

- `engine/src/context.zig` - Add mesh_asset field

  - Replace `geometry: ?*geometry.GeometrySystem` (line 40) with `mesh_asset: ?*mesh_asset.MeshAssetSystem`
  - Update contextStorage initialization (line 63)

- `engine/src/resources/manager.zig` - Add load methods
  - Add `loadMeshAsset(path: []const u8) !MeshAssetHandle`
  - Add `loadMeshAssetAsync(path, callback) !JobHandle`

**MeshAssetSystem API** (mirror MaterialSystem):

```zig
pub fn initialize() bool
pub fn shutdown() void
pub fn acquire(name: []const u8) ?*MeshAsset
pub fn acquireFromBuilder(builder: *MeshBuilder, name: []const u8) ?*MeshAsset
pub fn release(id: u32) void
pub fn getMesh(id: u32) ?*MeshAsset
pub fn loadFromFileAsync(path: []const u8, callback) !JobHandle
```

**Async Pattern** (copy from geometry.zig:1422-1481):

1. Background job: file I/O + parse to MeshBuilder
2. Main-thread job: GPU buffer upload
3. Callback invocation

---

### Phase 3: Loader Integration (Day 3-4) ✅ Completed

**Modified Files:**

- `engine/src/loaders/gltf_loader.zig` - Add `loadGltfToBuilder()`
- `engine/src/loaders/obj_loader.zig` - Add `loadObjToBuilder()`

**Key Changes:**

```zig
// GLTF: Each primitive becomes a submesh
pub fn loadGltfToBuilder(path: []const u8, builder: *MeshBuilder) !void {
    var result = loadGltf(allocator, path) orelse return error.LoadFailed;
    defer result.deinit();

    for (mesh.primitives) |prim| {
        builder.beginSubmesh(prim.name);
        const offset = @intCast(u32, builder.vertices.items.len);
        for (prim.vertices) |v| builder.addVertex(v);
        for (prim.indices) |idx| builder.addIndex(offset + idx);
        try builder.endSubmesh();
    }
}

// OBJ: Sub-meshes from material groups
pub fn loadObjToBuilder(path: []const u8, builder: *MeshBuilder) !void {
    var result = loadObj(allocator, path) orelse return error.LoadFailed;
    defer result.deinit();

    for (result.sub_meshes) |submesh| {
        builder.beginSubmesh(submesh.material_name);
        // Add vertices/indices with offset adjustment
        try builder.endSubmesh();
    }
}
```

**Keep existing loaders** - just add new functions (no breaking changes)

---

### Phase 4: Render Graph Integration (Day 4-5) ✅ Completed

**Modified Files:**

- `engine/src/renderer/render_graph/draw_list.zig` - Update DrawCall

**Key Changes:**

```zig
// OLD DrawCall (line ~50):
pub const DrawCall = struct {
    geometry: *const anyopaque,
    material_id: u32,
    model_matrix: Mat4,
    sort_key: u64,
};

// NEW DrawCall:
pub const DrawCall = struct {
    mesh_asset: *const MeshAsset,
    submesh_index: u8,
    material_id: u32,
    model_matrix: Mat4,
    sort_key: u64,
};

// Usage in pass execute callback:
for (draw_list.getDrawCalls()) |call| {
    const submesh = call.mesh_asset.getSubmesh(call.submesh_index);
    material_system.bind(call.material_id);

    // Bind buffers
    const gpu_data = call.mesh_asset.gpu_data.?;
    vkCmdBindVertexBuffers(..., gpu_data.vulkan.vertex_buffer.handle, ...);
    vkCmdBindIndexBuffer(..., gpu_data.vulkan.index_buffer.handle, ...);

    // Draw submesh range
    vkCmdDrawIndexed(cmd_buffer, submesh.index_count, 1,
                     submesh.index_offset, 0, 0);
}
```

---

### Phase 5: Migration & Cleanup (Day 5-6)

**Steps:**

1. **Search & replace**:

   - `GeometryHandle` → `MeshAssetHandle`
   - `geometry.acquire()` → `mesh_asset.acquire()`
   - `context.get().geometry` → `context.get().mesh_asset`

2. **Procedural generators** - migrate to MeshBuilder:

   ```zig
   pub fn generateCubeMesh(config: CubeConfig) ?MeshAssetHandle {
       var builder = MeshBuilder.init(allocator);
       defer builder.deinit();

       // Generate vertices (reuse logic from geometry.zig:1745-1850)
       for (cube_vertices) |v| builder.addVertex(v);
       builder.beginSubmesh("cube");
       for (cube_indices) |idx| builder.addIndex(idx);
       builder.endSubmesh() catch return null;

       builder.finalize(config.name) catch return null;

       const mesh = mesh_asset.acquireFromBuilder(&builder, config.name);
       return MeshAssetHandle{ .id = mesh.?.id, .generation = mesh.?.generation };
   }
   ```

3. **Delete files**:

   - `engine/src/systems/geometry.zig`

4. **Testing**:
   - Visual comparison (before/after screenshots)
   - Performance metrics (GPU memory, frame time)
   - Unit tests for MeshBuilder validation

---

## Critical Files Summary

| File                                                              | Action | Lines |
| ----------------------------------------------------------------- | ------ | ----- |
| [mesh_asset_types.zig](engine/src/resources/mesh_asset_types.zig) | CREATE | ~200  |
| [mesh_builder.zig](engine/src/systems/mesh_builder.zig)           | CREATE | ~400  |
| [mesh_asset.zig](engine/src/systems/mesh_asset.zig)               | CREATE | ~800  |
| [mesh_instance.zig](engine/src/scene/mesh_instance.zig)           | CREATE | ~100  |
| [handle.zig](engine/src/resources/handle.zig)                     | MODIFY | +30   |
| [context.zig](engine/src/context.zig)                             | MODIFY | +2    |
| [manager.zig](engine/src/resources/manager.zig)                   | MODIFY | +60   |
| [gltf_loader.zig](engine/src/loaders/gltf_loader.zig)             | MODIFY | +40   |
| [obj_loader.zig](engine/src/loaders/obj_loader.zig)               | MODIFY | +40   |
| [draw_list.zig](engine/src/renderer/render_graph/draw_list.zig)   | MODIFY | +20   |
| [geometry.zig](engine/src/systems/geometry.zig)                   | DELETE | -2054 |

---

## Design Decisions

1. **Replace, don't wrap**: MeshAsset replaces Geometry entirely (cleaner, follows design doc)
2. **Universal Vertex3D**: Keep 64-byte format (simpler, matches existing infrastructure)
3. **Materials in instances**: MeshInstance owns material bindings, not MeshAsset (allows sharing)
4. **Fixed submesh limit (32)**: Covers 99% of assets, no heap allocation
5. **Async pattern**: Background parse + main-thread GPU upload (proven in geometry.zig)
6. **Pre-computed bounds**: AABB per submesh + overall (enable frustum culling)

---

## Expected Outcomes

✅ Cleaner API - MeshAsset vs old Geometry (submeshes vs single material)
✅ Multi-material support - One draw per submesh with different materials
✅ Frustum culling - Submesh-level bounds checking
✅ Async loading - Parallel file I/O via job system
✅ GPU efficiency - Same buffer management as before (Vulkan/Metal)
✅ Migration path - Keep existing loaders, add new functions

**Estimated timeline**: 6 days (assumes 1 developer, no blockers)
