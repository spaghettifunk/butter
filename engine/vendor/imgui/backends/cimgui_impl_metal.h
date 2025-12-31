// C bindings for imgui_impl_metal.mm
// This provides C-callable functions that can be used from Zig

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>

// Forward declarations (opaque pointers for Zig compatibility)
typedef void* cImGui_MTLDevice;
typedef void* cImGui_MTLCommandBuffer;
typedef void* cImGui_MTLRenderCommandEncoder;
typedef void* cImGui_MTLRenderPassDescriptor;
typedef void* cImGui_ImDrawData;

// Initialize the Metal backend with a device
bool cImGui_ImplMetal_Init(cImGui_MTLDevice device);

// Shutdown the Metal backend
void cImGui_ImplMetal_Shutdown(void);

// Call at the start of a new frame, before ImGui::NewFrame()
// Pass the render pass descriptor that will be used for rendering
void cImGui_ImplMetal_NewFrame(cImGui_MTLRenderPassDescriptor renderPassDescriptor);

// Render ImGui draw data using Metal
// Call after ImGui::Render() to get the draw data
void cImGui_ImplMetal_RenderDrawData(cImGui_ImDrawData drawData,
                                      cImGui_MTLCommandBuffer commandBuffer,
                                      cImGui_MTLRenderCommandEncoder commandEncoder);

// Create device objects (called automatically by Init, but can be called manually)
bool cImGui_ImplMetal_CreateDeviceObjects(cImGui_MTLDevice device);

// Destroy device objects (called automatically by Shutdown)
void cImGui_ImplMetal_DestroyDeviceObjects(void);

#ifdef __cplusplus
}
#endif
