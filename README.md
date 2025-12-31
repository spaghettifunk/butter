# Butter Engine

Simple game engine written in Zig

## Building

The engine produces two separate executables:

- **`butter_editor`** - Full-featured development environment with ImGui, validation layers, and editor UI
- **`butter_runtime`** - Minimal runtime for shipping games (no ImGui, no validation, no editor)

### Build Commands

```shell
# Build both executables
zig build

# Build and run the editor (default)
zig build run

# Build and run the runtime
zig build run-runtime

# Release build (optimized)
zig build -Doptimize=ReleaseFast
```

### Build Outputs

Executables are placed in `zig-out/bin/`:

| Executable       | Description                                       |
| ---------------- | ------------------------------------------------- |
| `butter_editor`  | Editor with ImGui, debug tools, validation layers |
| `butter_runtime` | Minimal runtime for game distribution             |
