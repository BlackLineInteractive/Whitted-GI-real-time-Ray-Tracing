#include <SDL2/SDL.h>
#include <iostream>
#include <string>
#include "Renderer.h"
#include "imgui.h"
#include "backends/imgui_impl_sdl2.h"

#include <fstream>
#include <sstream>

struct Config {
    int width = 1280;
    int height = 720;
    bool fullscreen = false;
};

Config LoadConfig() {
    Config cfg;
    std::string path = "config.txt";
    char* basePathStr = SDL_GetBasePath();
    if (basePathStr) {
        path = std::string(basePathStr) + "config.txt";
        SDL_free(basePathStr);
    }

    std::ifstream f(path);
    if (!f.is_open()) {
        // Create default config
        std::ofstream out(path);
        out << "width=1280\nheight=720\nfullscreen=0\n";
        return cfg;
    }

    std::string line;
    while (std::getline(f, line)) {
        if (line.find("width=") == 0) cfg.width = std::stoi(line.substr(6));
        else if (line.find("height=") == 0) cfg.height = std::stoi(line.substr(7));
        else if (line.find("fullscreen=") == 0) cfg.fullscreen = std::stoi(line.substr(11)) > 0;
    }
    return cfg;
}

int main(int argc, char* argv[]) {
    (void)argc; (void)argv;

    Config cfg = LoadConfig();
    const int RENDER_WIDTH  = cfg.width;
    const int RENDER_HEIGHT = cfg.height;

    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        std::cerr << "Error: " << SDL_GetError() << std::endl;
        return -1;
    }

    // Set up SDL Window flags depending on backend. We will default to Metal on macOS, or Vulkan/OpenGL.
    Uint32 window_flags = SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI;
#ifdef USE_METAL
    window_flags |= SDL_WINDOW_METAL;
#elif defined(USE_VULKAN)
    window_flags |= SDL_WINDOW_VULKAN;
#elif defined(USE_OPENGL)
    window_flags |= SDL_WINDOW_OPENGL;
#endif

    if (cfg.fullscreen) {
        window_flags |= SDL_WINDOW_FULLSCREEN_DESKTOP;
    }

    SDL_Window* window = SDL_CreateWindow("Whitted GI RayTracer", 
                                          SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, 
                                          RENDER_WIDTH, RENDER_HEIGHT, window_flags);

    if (!window) {
        std::cerr << "Failed to create SDL window." << std::endl;
        SDL_Quit();
        return -1;
    }

    SDL_SetRelativeMouseMode(SDL_TRUE);

    // Initialize ImGui
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO(); (void)io;
    ImGui::StyleColorsDark();

    // Create renderer
    IRenderer* renderer = nullptr;
#ifdef USE_METAL
    renderer = CreateRendererMetal();
#elif defined(USE_VULKAN)
    renderer = CreateRendererVK();
#elif defined(USE_OPENGL)
    renderer = CreateRendererGL();
#endif

    if (!renderer || !renderer->Init(window, RENDER_WIDTH, RENDER_HEIGHT)) {
        std::cerr << "Failed to initialize renderer." << std::endl;
        return -1;
    }

    bool quit = false;
    SDL_Event e;
    Uint32 last_tick = SDL_GetTicks();
    
    // Default demo version
    int demo_version = 1; // 0.3 by default
    renderer->SwitchDemo(demo_version);

    while (!quit) {
        Uint32 now = SDL_GetTicks();
        float dt = (now - last_tick) / 1000.0f;
        last_tick = now;

        int mx = 0, my = 0;
        while (SDL_PollEvent(&e)) {
            ImGui_ImplSDL2_ProcessEvent(&e);
            if (e.type == SDL_QUIT || (e.type == SDL_KEYDOWN && e.key.keysym.sym == SDLK_ESCAPE)) quit = true;
            
            // Toggle fullscreen
            if (e.type == SDL_KEYDOWN && e.key.keysym.sym == SDLK_F11) {
                bool is_fs = SDL_GetWindowFlags(window) & SDL_WINDOW_FULLSCREEN_DESKTOP;
                SDL_SetWindowFullscreen(window, is_fs ? 0 : SDL_WINDOW_FULLSCREEN_DESKTOP);
            }

            // Toggle relative mouse mode
            if (e.type == SDL_KEYDOWN && e.key.keysym.sym == SDLK_m) {
                SDL_SetRelativeMouseMode(SDL_GetRelativeMouseMode() ? SDL_FALSE : SDL_TRUE);
            }

            if (e.type == SDL_KEYDOWN && e.key.keysym.sym == SDLK_v) {
                renderer->ToggleFog();
            }
            if (e.type == SDL_MOUSEMOTION && SDL_GetRelativeMouseMode()) {
                mx += e.motion.xrel;
                my += e.motion.yrel;
            }
        }

        const Uint8* keys = SDL_GetKeyboardState(NULL);
        if (SDL_GetRelativeMouseMode()) {
            renderer->ProcessInput(keys, mx, my, dt);
        }

        // Start ImGui frame
        ImGui_ImplSDL2_NewFrame();
        renderer->BeginImGuiFrame();
        ImGui::NewFrame();

        // Draw HUD
        ImGui::SetNextWindowPos(ImVec2(10, 10));
        ImGui::SetNextWindowBgAlpha(0.35f); // Transparent background
        if (ImGui::Begin("Stats", nullptr, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoFocusOnAppearing | ImGuiWindowFlags_NoNav)) {
            float frameTimeMs = 0.0f, gpuTimeMs = 0.0f;
            int rayCount = 0, triCount = 0;
            renderer->GetStats(frameTimeMs, rayCount, triCount, gpuTimeMs);

            // Industry standard colors
            ImVec4 fpsColor = ImVec4(0.4f, 1.0f, 0.4f, 1.0f); // Green
            ImVec4 msColor = ImVec4(1.0f, 1.0f, 0.4f, 1.0f);  // Yellow
            ImVec4 gpuColor = ImVec4(0.4f, 0.8f, 1.0f, 1.0f); // Cyan
            ImVec4 statsColor = ImVec4(0.8f, 0.8f, 0.8f, 1.0f);

            ImGui::TextColored(fpsColor, "FPS: %.1f", io.Framerate);
            ImGui::TextColored(msColor, "Frame Time: %.2f ms", 1000.0f / io.Framerate);
            ImGui::TextColored(gpuColor, "GPU Time: %.2f ms", gpuTimeMs); // Approximation or placeholder
            ImGui::Separator();
            ImGui::TextColored(statsColor, "Rays Cast: %d", rayCount);
            ImGui::TextColored(statsColor, "Triangles: %d (Analytic)", triCount); // No actual triangles in analytic!
            
            ImGui::Separator();
            ImGui::Text("Controls:");
            ImGui::Text("WASD - Move | Mouse - Look");
            ImGui::Text("M - Toggle Mouse Mode");
            ImGui::Text("V - Toggle Fog (Demo 0.3)");
            ImGui::Text("F11 - Toggle Fullscreen");
            if (ImGui::Button("Toggle Fullscreen")) {
                bool is_fs = SDL_GetWindowFlags(window) & SDL_WINDOW_FULLSCREEN_DESKTOP;
                SDL_SetWindowFullscreen(window, is_fs ? 0 : SDL_WINDOW_FULLSCREEN_DESKTOP);
            }
            ImGui::Separator();
            
            int prev_version = demo_version;
            ImGui::RadioButton("Demo 0.2", &demo_version, 0); ImGui::SameLine();
            ImGui::RadioButton("Demo 0.3", &demo_version, 1);
            if (prev_version != demo_version) {
                renderer->SwitchDemo(demo_version);
            }
        }
        ImGui::End();

        ImGui::Render();

        // Render pass and swap buffers
        renderer->Render(dt);
    }

    renderer->Cleanup();
    delete renderer;

    ImGui::DestroyContext();
    SDL_DestroyWindow(window);
    SDL_Quit();

    return 0;
}
