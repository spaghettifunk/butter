### Phase 6: Hot-Reload Support

**Goal:** Auto-reload assets when files change during development

**New Files:**

- `engine/src/resources/file_watcher.zig` - Poll-based file modification detection

**Modified Files:**

- `engine/src/systems/texture.zig` - Add `reload()` method, track file paths
- `engine/src/systems/material.zig` - Add `reload()` method
- `engine/src/resources/manager.zig` - Integrate file watcher, implement reload cascade

**Implementation:**

- Polling with `std.fs.File.stat()` for modification time (1-second interval)
- **Uses Job System** - File watching runs as periodic background job
- Cross-platform (no OS-specific APIs)
- Cascade reloads using dependency graph + Job System (texture reload → material reload → geometry reload)

**Hot-Reload Flow:**

```zig
// Background job checks files every 1 second
fn fileWatcherJob() void {
    const changed_files = file_watcher.checkModifiedFiles();

    for (changed_files) |metadata_id| {
        // Submit reload job with dependencies
        const dependents = dependency_graph.getAllDependents(metadata_id);
        const reload_jobs = submitReloadChain(metadata_id, dependents);

        // Jobs handle cascade automatically
    }
}
```

**Testing:**

- Modify texture file, verify auto-reload
- Test cascade (texture change triggers material update)
- Performance with many watched files
- Concurrent reload handling

---

### Phase 7: Font System (NEW)

**Goal:** Add font loading capability (TTF/OTF files)

**New Files:**

- `engine/src/loaders/font_loader.zig` - TTF/OTF parser using stb_truetype
- `engine/src/systems/font.zig` - FontSystem (follows TextureSystem pattern)

**Capabilities:**

- Parse TTF/OTF files (can be async via Job System)
- Generate glyph atlas textures (CPU-bound, benefits from Job System)
- Text measurement
- Integration with ResourceManager

**Job System Integration:**

- Async font loading (parse TTF in background job)
- Parallel glyph rasterization (multiple glyphs in parallel)
- Main-thread atlas texture upload

**Testing:**

- Load TTF file, verify glyph atlas generation
- Async font loading
- Render text samples
- Text measurement accuracy

---
