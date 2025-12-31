# How to Add a New Subsystem (After This Refactor)

## Step 1: Create subsystem file (e.g., renderer.zig)

```zig
const context = @import("engine_context.zig");
var instance: RendererSystem = undefined;

pub const RendererSystem = struct {
    pub fn initialize() bool {
        instance = RendererSystem{};
        context.get().renderer = &instance;
        return true;
    }
    pub fn shutdown() void {
        context.get().renderer = null;
    }
};

pub fn getSystem() ?*RendererSystem {
    return context.get().renderer;
}
```

## Step 2: Add to engine_context.zig:

```zig
const renderer = @import("renderer.zig");
// In EngineContext:
renderer: ?*renderer.RendererSystem = null,
```

## Step 3: Add to engine.zig:

```zig
pub const renderer = @import("core/renderer.zig");
// In main(): renderer.RendererSystem.initialize() and .shutdown()
```
