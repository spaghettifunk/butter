//! Selection System
//! Manages which objects are currently selected in the editor.

const editor_scene = @import("editor_scene.zig");

const EditorObjectId = editor_scene.EditorObjectId;
const INVALID_OBJECT_ID = editor_scene.INVALID_OBJECT_ID;

/// Selection state for the editor
pub const Selection = struct {
    /// Currently selected object ID (0 = none)
    selected_id: EditorObjectId = INVALID_OBJECT_ID,
    /// Currently selected light ID (0 = none)
    selected_light_id: u32 = 0,

    /// Optional callback for selection changes
    on_selection_changed: ?*const fn (old_id: EditorObjectId, new_id: EditorObjectId) void = null,

    /// Select an object by ID
    pub fn select(self: *Selection, id: EditorObjectId) void {
        if (self.selected_id == id) return;

        const old_id = self.selected_id;
        self.selected_id = id;

        // Deselect light if object is selected
        if (id != INVALID_OBJECT_ID) {
            self.selected_light_id = 0;
        }

        if (self.on_selection_changed) |callback| {
            callback(old_id, id);
        }
    }

    /// Select a light by ID
    pub fn selectLight(self: *Selection, id: u32) void {
        if (self.selected_light_id == id) return;

        // Deselect object if light is selected
        if (id != 0) {
            self.deselect();
        }

        self.selected_light_id = id;
    }

    /// Deselect the current object
    pub fn deselect(self: *Selection) void {
        self.select(INVALID_OBJECT_ID);
    }

    /// Deselect the current light
    pub fn deselectLight(self: *Selection) void {
        self.selected_light_id = 0;
    }

    /// Check if a specific object is selected
    pub fn isSelected(self: *const Selection, id: EditorObjectId) bool {
        return self.selected_id == id and id != INVALID_OBJECT_ID;
    }

    /// Get the selected object ID, or null if nothing selected
    pub fn getSelected(self: *const Selection) ?EditorObjectId {
        if (self.selected_id == INVALID_OBJECT_ID) {
            return null;
        }
        return self.selected_id;
    }

    /// Check if anything is selected
    pub fn hasSelection(self: *const Selection) bool {
        return self.selected_id != INVALID_OBJECT_ID;
    }
};
