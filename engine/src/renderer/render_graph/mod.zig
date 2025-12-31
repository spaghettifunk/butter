//! Render Graph System
//!
//! Provides a declarative API for defining multi-pass rendering pipelines with
//! automatic dependency resolution, resource management, and backend abstraction.
//!
//! Key components:
//! - ResourceHandle: Type-safe, generation-counted handles for render resources
//! - RenderPass: Defines a single rendering pass with inputs/outputs
//! - RenderGraph: The main graph structure that owns passes and resources
//! - GraphCompiler: Resolves dependencies and generates execution order
//! - GraphExecutor: Executes the compiled graph each frame

const std = @import("std");

pub const resource = @import("resource.zig");
pub const pass = @import("pass.zig");
pub const graph = @import("graph.zig");
pub const compiler = @import("compiler.zig");
pub const executor = @import("executor.zig");
pub const draw_list = @import("draw_list.zig");

// Re-export commonly used types
pub const ResourceHandle = resource.ResourceHandle;
pub const ResourceType = resource.ResourceType;
pub const TextureFormat = resource.TextureFormat;
pub const TextureDesc = resource.TextureDesc;
pub const BufferDesc = resource.BufferDesc;
pub const ResourceDesc = resource.ResourceDesc;
pub const ResourceUsage = resource.ResourceUsage;

pub const RenderPass = pass.RenderPass;
pub const PassType = pass.PassType;
pub const LoadOp = pass.LoadOp;
pub const StoreOp = pass.StoreOp;
pub const ColorAttachment = pass.ColorAttachment;
pub const DepthAttachment = pass.DepthAttachment;
pub const ResourceRead = pass.ResourceRead;
pub const ShaderStageFlags = pass.ShaderStageFlags;
pub const RenderPassContext = pass.RenderPassContext;

pub const RenderGraph = graph.RenderGraph;
pub const ResourceEntry = graph.ResourceEntry;

pub const GraphCompiler = compiler.GraphCompiler;
pub const CompiledPass = compiler.CompiledPass;
pub const ResourceBarrier = compiler.ResourceBarrier;
pub const AccessFlags = compiler.AccessFlags;
pub const ImageLayout = compiler.ImageLayout;

pub const GraphExecutor = executor.GraphExecutor;

pub const DrawCall = draw_list.DrawCall;
pub const DrawList = draw_list.DrawList;
