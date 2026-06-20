#pragma once
#include <SDL2/SDL.h>
#include "Scene.h"

class IRenderer {
public:
    virtual ~IRenderer() = default;
    
    // Returns false on failure
    virtual bool Init(SDL_Window* window, int width, int height) = 0;
    
    // Main render call
    virtual void Render(float dt) = 0;
    
    // Updates camera based on input
    virtual void ProcessInput(const Uint8* keys, int mx, int my, float dt) = 0;
    
    // Toggles features
    virtual void ToggleFog() = 0;
    
    // Switches demo scene
    virtual void SwitchDemo(int version) = 0; // 0 for v0.2, 1 for v0.3
    
    // Cleanup resources
    virtual void Cleanup() = 0;

    // Get Stats
    virtual void GetStats(float& outFrameTimeMs, int& outRayCount, int& outTriCount, float& outGpuTimeMs) = 0;
};

// Backend factories
#ifdef USE_METAL
IRenderer* CreateRendererMetal();
#endif
#ifdef USE_OPENGL
IRenderer* CreateRendererGL();
#endif
#ifdef USE_VULKAN
IRenderer* CreateRendererVK();
#endif
