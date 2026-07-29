#pragma once
#include <SDL2/SDL.h>
#include "Scene.h"
#include "ModelLoader.h"

class IRenderer {
public:
    virtual ~IRenderer() = default;

    virtual bool Init(SDL_Window* window, int width, int height) = 0;
    virtual void Render(float dt) = 0;
    virtual void ProcessInput(const Uint8* keys, int mx, int my, float dt) = 0;
    virtual void ToggleFog()     = 0;
    virtual void SwitchDemo(int version) = 0;  // 0 = v0.2, 1 = v0.3
    virtual void LoadMesh(const MeshData& mesh) = 0;
    virtual void ClearMesh() = 0;
    virtual void SetMeshOrigin(float x, float y, float z) = 0;
    virtual void SetSamples(int samples) = 0;
    virtual void BeginImGuiFrame() = 0;
    virtual void OnResize(int new_width, int new_height) = 0;
    virtual void GetStats(float& outFrameTimeMs, int& outRayCount,
                          int& outTriCount, float& outGpuTimeMs) = 0;
    virtual void Cleanup() = 0;

    // Optional: uncap the presentation rate (benchmarking). No-op by default.
    virtual void SetVSync(bool /*enabled*/) {}
    // Optional: internal render scale, 1.0 = native, 0.5 = quarter-pixel count.
    virtual void  SetRenderScale(float /*scale*/) {}
    virtual float GetRenderScale() const { return 1.0f; }

    virtual void SetMaxDepth(int /*depth*/) {}
    virtual void SetGameMode(bool /*enabled*/) {}
};

#ifdef USE_METAL
IRenderer* CreateRendererMetal();
#endif
#ifdef USE_OPENGL
IRenderer* CreateRendererGL();
#endif
#ifdef USE_VULKAN
IRenderer* CreateRendererVK();
#endif
