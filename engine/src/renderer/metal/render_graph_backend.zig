//! Metal Render Graph Backend
//!
//! Provides Metal-specific implementation for render graph execution,
//! including render pass descriptor creation and encoder management.

const std = @import("std");
const metal_context = @import("context.zig");
const metal_texture = @import("texture.zig");
const logger = @import("../../core/logging.zig");

const render_graph = @import("../render_graph/mod.zig");
const ResourceHandle = render_graph.ResourceHandle;
const ResourceEntry = render_graph.ResourceEntry;
const TextureFormat = render_graph.TextureFormat;
const TextureDesc = render_graph.TextureDesc;
const RenderPass = render_graph.RenderPass;
const LoadOp = render_graph.LoadOp;
const StoreOp = render_graph.StoreOp;

// Convenient aliases
const MetalContext = metal_context.MetalContext;
const sel = metal_context.sel_registerName;
const msg = metal_context.msgSend;
const msg1 = metal_context.msgSend1;
const msg2 = metal_context.msgSend2;
const getClass = metal_context.objc_getClass;

/// Metal render graph backend
pub const MetalRenderGraphBackend = struct {
    /// Reference to Metal context
    context: *MetalContext,

    /// Current render command encoder (valid during pass execution)
    current_encoder: ?*anyopaque = null,

    /// Initialize the backend
    pub fn init(ctx: *MetalContext) MetalRenderGraphBackend {
        return MetalRenderGraphBackend{
            .context = ctx,
        };
    }

    /// Shutdown and cleanup
    pub fn deinit(self: *MetalRenderGraphBackend) void {
        self.current_encoder = null;
    }

    /// Begin a render pass and return the render command encoder
    pub fn beginRenderPass(
        self: *MetalRenderGraphBackend,
        pass: *const RenderPass,
        graph_resources: []const ResourceEntry,
        command_buffer: ?*anyopaque,
    ) ?*anyopaque {
        if (command_buffer == null) return null;

        // Create render pass descriptor
        const rpd_class = getClass("MTLRenderPassDescriptor") orelse return null;
        const render_pass_desc = msg(?*anyopaque, rpd_class, sel("renderPassDescriptor"));
        if (render_pass_desc == null) return null;

        // Configure color attachments
        const color_attachments = msg(?*anyopaque, render_pass_desc, sel("colorAttachments"));
        if (color_attachments == null) return null;

        for (0..pass.color_attachment_count) |i| {
            if (pass.color_attachments[i]) |att| {
                const color_att = msg1(
                    ?*anyopaque,
                    color_attachments,
                    sel("objectAtIndexedSubscript:"),
                    @as(u64, i),
                );

                if (color_att) |attachment| {
                    // Get texture from resource
                    if (att.resource.isValid() and att.resource.index < graph_resources.len) {
                        const res = &graph_resources[att.resource.index];
                        if (res.metal_data.texture) |texture| {
                            msg1(void, attachment, sel("setTexture:"), texture);
                        }
                    }

                    // Set load action
                    const load_action: u64 = att.load_op.toMetal();
                    msg1(void, attachment, sel("setLoadAction:"), load_action);

                    // Set store action
                    const store_action: u64 = att.store_op.toMetal();
                    msg1(void, attachment, sel("setStoreAction:"), store_action);

                    // Set clear color if loading with clear
                    if (att.load_op == .clear) {
                        // MTLClearColor is a struct, need to set components individually
                        // or use the struct directly if the ABI allows
                        msg1(void, attachment, sel("setClearColor:"), metal_context.MTLClearColor{
                            .red = att.clear_color[0],
                            .green = att.clear_color[1],
                            .blue = att.clear_color[2],
                            .alpha = att.clear_color[3],
                        });
                    }
                }
            }
        }

        // Configure depth attachment
        if (pass.depth_attachment) |depth| {
            const depth_att = msg(?*anyopaque, render_pass_desc, sel("depthAttachment"));

            if (depth_att) |attachment| {
                // Get texture from resource
                if (depth.resource.isValid() and depth.resource.index < graph_resources.len) {
                    const res = &graph_resources[depth.resource.index];
                    if (res.metal_data.texture) |texture| {
                        msg1(void, attachment, sel("setTexture:"), texture);
                    }
                }

                // Set load action
                const load_action: u64 = depth.load_op.toMetal();
                msg1(void, attachment, sel("setLoadAction:"), load_action);

                // Set store action
                const store_action: u64 = depth.store_op.toMetal();
                msg1(void, attachment, sel("setStoreAction:"), store_action);

                // Set clear depth
                if (depth.load_op == .clear) {
                    msg1(void, attachment, sel("setClearDepth:"), @as(f64, depth.clear_depth));
                }
            }
        }

        // Create render command encoder
        const encoder = msg1(
            ?*anyopaque,
            command_buffer,
            sel("renderCommandEncoderWithDescriptor:"),
            render_pass_desc,
        );

        if (encoder) |enc| {
            self.current_encoder = enc;

            // Set debug label if available
            const pass_name = pass.getName();
            if (pass_name.len > 0) {
                // Create NSString from pass name
                const ns_string_class = getClass("NSString") orelse return enc;
                const label = msg2(
                    ?*anyopaque,
                    ns_string_class,
                    sel("stringWithUTF8String:"),
                    pass_name.ptr,
                    @as(u64, pass_name.len),
                );
                if (label) |l| {
                    msg1(void, enc, sel("setLabel:"), l);
                }
            }
        }

        return encoder;
    }

    /// End the current render pass
    pub fn endRenderPass(self: *MetalRenderGraphBackend) void {
        if (self.current_encoder) |encoder| {
            msg(void, encoder, sel("endEncoding"));
        }
        self.current_encoder = null;
    }

    /// Create a render graph texture resource
    pub fn createTexture(
        self: *MetalRenderGraphBackend,
        desc: *const TextureDesc,
        res_entry: *ResourceEntry,
    ) bool {
        const device = self.context.device orelse return false;

        // Create texture descriptor
        const tex_desc_class = getClass("MTLTextureDescriptor") orelse return false;
        const tex_desc = msg(?*anyopaque, tex_desc_class, sel("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"));

        if (tex_desc == null) {
            // Try alternative approach - create descriptor and set properties
            const descriptor = msg(?*anyopaque, tex_desc_class, sel("new"));
            if (descriptor == null) return false;

            // Set texture type
            msg1(void, descriptor, sel("setTextureType:"), @as(u64, 2)); // MTLTextureType2D

            // Set pixel format
            msg1(void, descriptor, sel("setPixelFormat:"), desc.format.toMetal());

            // Set dimensions
            msg1(void, descriptor, sel("setWidth:"), @as(u64, desc.width));
            msg1(void, descriptor, sel("setHeight:"), @as(u64, desc.height));

            // Set usage flags
            var usage: u64 = 0;
            if (desc.usage.sampled) usage |= 0x0001; // MTLTextureUsageShaderRead
            if (desc.usage.storage) usage |= 0x0002; // MTLTextureUsageShaderWrite
            if (desc.usage.color_attachment) usage |= 0x0004; // MTLTextureUsageRenderTarget
            if (desc.usage.depth_attachment) usage |= 0x0004; // MTLTextureUsageRenderTarget
            msg1(void, descriptor, sel("setUsage:"), usage);

            // Set storage mode (private for GPU-only resources)
            msg1(void, descriptor, sel("setStorageMode:"), @as(u64, 2)); // MTLStorageModePrivate

            // Create texture
            const texture = msg1(?*anyopaque, device, sel("newTextureWithDescriptor:"), descriptor);

            // Release descriptor
            metal_context.release(descriptor);

            if (texture) |tex| {
                res_entry.metal_data.texture = tex;
                return true;
            }

            return false;
        }

        return false;
    }

    /// Destroy a render graph texture resource
    pub fn destroyTexture(
        self: *MetalRenderGraphBackend,
        res_entry: *ResourceEntry,
    ) void {
        _ = self;
        if (res_entry.metal_data.texture) |texture| {
            metal_context.release(texture);
        }
        res_entry.metal_data = .{};
    }

    /// Get the current render encoder
    pub fn getCurrentEncoder(self: *const MetalRenderGraphBackend) ?*anyopaque {
        return self.current_encoder;
    }
};
