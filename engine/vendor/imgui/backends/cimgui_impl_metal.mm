// C bindings for imgui_impl_metal.mm
// This provides C-callable functions that can be used from Zig

#include "cimgui_impl_metal.h"
#include "imgui_impl_metal.h"
#include "../imgui.h"

#import <Metal/Metal.h>

extern "C" {

bool cImGui_ImplMetal_Init(cImGui_MTLDevice device)
{
    return ImGui_ImplMetal_Init((__bridge id<MTLDevice>)device);
}

void cImGui_ImplMetal_Shutdown(void)
{
    ImGui_ImplMetal_Shutdown();
}

void cImGui_ImplMetal_NewFrame(cImGui_MTLRenderPassDescriptor renderPassDescriptor)
{
    ImGui_ImplMetal_NewFrame((__bridge MTLRenderPassDescriptor*)renderPassDescriptor);
}

void cImGui_ImplMetal_RenderDrawData(cImGui_ImDrawData drawData,
                                      cImGui_MTLCommandBuffer commandBuffer,
                                      cImGui_MTLRenderCommandEncoder commandEncoder)
{
    ImGui_ImplMetal_RenderDrawData((ImDrawData*)drawData,
                                    (__bridge id<MTLCommandBuffer>)commandBuffer,
                                    (__bridge id<MTLRenderCommandEncoder>)commandEncoder);
}

bool cImGui_ImplMetal_CreateDeviceObjects(cImGui_MTLDevice device)
{
    return ImGui_ImplMetal_CreateDeviceObjects((__bridge id<MTLDevice>)device);
}

void cImGui_ImplMetal_DestroyDeviceObjects(void)
{
    ImGui_ImplMetal_DestroyDeviceObjects();
}

} // extern "C"
