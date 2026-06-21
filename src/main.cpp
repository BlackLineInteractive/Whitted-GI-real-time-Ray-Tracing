#include <SDL2/SDL.h>
#include <iostream>
#include <string>
#include <fstream>
#include <sstream>
#include "Renderer.h"
#include "ModelLoader.h"
#include "Physics.h"
#include "imgui.h"
#include "backends/imgui_impl_sdl2.h"
#include "ImGuiFileDialog.h"

// ------------------------------------------------------------------ Config --

struct Config {
    int   width               = 1280;
    int   height              = 720;
    bool  fullscreen          = false;
    bool  enable_physics      = true;
    bool  enable_jitter       = false;
    int   samples             = 1;
    bool  show_primitives     = true;
    std::string model_path    = "";
    float model_x = 0.0f, model_y = 0.0f, model_z = -3.0f;
};

static std::string GetConfigPath() {
    char* base = SDL_GetBasePath();
    std::string p = base ? (std::string(base) + "config.txt") : "config.txt";
    if (base) SDL_free(base);
    return p;
}

static Config LoadConfig() {
    Config cfg;
    std::ifstream f(GetConfigPath());
    if (!f.is_open()) return cfg;
    std::string line;
    while (std::getline(f, line)) {
        auto sep = line.find('=');
        if (sep == std::string::npos) continue;
        auto key = line.substr(0, sep);
        auto val = line.substr(sep + 1);
        if (key == "width")               cfg.width               = std::stoi(val);
        else if (key == "height")         cfg.height              = std::stoi(val);
        else if (key == "fullscreen")     cfg.fullscreen          = std::stoi(val) > 0;
        else if (key == "enable_physics") cfg.enable_physics      = std::stoi(val) > 0;
        else if (key == "enable_jitter")  cfg.enable_jitter       = std::stoi(val) > 0;
        else if (key == "samples")        cfg.samples             = std::stoi(val);
        else if (key == "show_primitives") cfg.show_primitives    = std::stoi(val) > 0;
        else if (key == "model_path")     cfg.model_path          = val;
        else if (key == "model_x")        cfg.model_x             = std::stof(val);
        else if (key == "model_y")        cfg.model_y             = std::stof(val);
        else if (key == "model_z")        cfg.model_z             = std::stof(val);
    }
    return cfg;
}

static void SaveConfig(const Config& cfg) {
    std::ofstream f(GetConfigPath());
    f << "width="               << cfg.width               << "\n";
    f << "height="              << cfg.height              << "\n";
    f << "fullscreen="          << (cfg.fullscreen ? 1 : 0) << "\n";
    f << "enable_physics="      << (cfg.enable_physics ? 1 : 0) << "\n";
    f << "enable_jitter="       << (cfg.enable_jitter ? 1 : 0) << "\n";
    f << "samples="             << cfg.samples << "\n";
    f << "show_primitives="     << (cfg.show_primitives ? 1 : 0) << "\n";
    f << "model_path="          << cfg.model_path          << "\n";
    f << "model_x="             << cfg.model_x             << "\n";
    f << "model_y="             << cfg.model_y             << "\n";
    f << "model_z="             << cfg.model_z             << "\n";
}

// -------------------------------------------------------------------- main --

int main(int argc, char* argv[]) {
    (void)argc; (void)argv;

    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        std::cerr << "SDL_Init error: " << SDL_GetError() << std::endl;
        return -1;
    }

    Config cfg = LoadConfig();

    Uint32 win_flags = SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI;
#ifdef USE_METAL
    win_flags |= SDL_WINDOW_METAL;
#elif defined(USE_VULKAN)
    win_flags |= SDL_WINDOW_VULKAN;
#elif defined(USE_OPENGL)
    win_flags |= SDL_WINDOW_OPENGL;
#endif
    if (cfg.fullscreen) win_flags |= SDL_WINDOW_FULLSCREEN_DESKTOP;

    SDL_Window* window = SDL_CreateWindow(
        "Whitted GI RayTracer",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        cfg.width, cfg.height, win_flags);
    if (!window) {
        std::cerr << "SDL_CreateWindow failed: " << SDL_GetError() << std::endl;
        SDL_Quit(); return -1;
    }

    SDL_SetRelativeMouseMode(SDL_TRUE);

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    ImGui::StyleColorsDark();

    // ----------------------------------------- create renderer backend
    IRenderer* renderer = nullptr;
#ifdef USE_METAL
    renderer = CreateRendererMetal();
#elif defined(USE_VULKAN)
    renderer = CreateRendererVK();
#elif defined(USE_OPENGL)
    renderer = CreateRendererGL();
#endif

    if (!renderer || !renderer->Init(window, cfg.width, cfg.height)) {
        std::cerr << "Renderer init failed." << std::endl;
        SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR,
            "Renderer Initialization Failed",
            "Failed to initialize the graphics backend.\n\n"
            "If you are on macOS and running the OpenGL version, please note that macOS does NOT support OpenGL 4.3 Compute Shaders.\n\n"
            "You MUST run the Metal version: build_metal/Whitted_GI_RayTracer",
            window);
        SDL_DestroyWindow(window); SDL_Quit(); return -1;
    }

    // Apply initial feature states
    renderer->SetSamples(cfg.samples);
    if (cfg.enable_jitter) renderer->ToggleJitter();

    // --------------------------------------- physics setup
    PhysicsWorld physics;
    if (cfg.enable_physics) {
        physics.SetFloor(-1.0f);
        // Add some fun bouncing spheres
        physics.AddSphere({-2.0f, 3.0f, -5.0f}, 1.0f, 1.0f);
        physics.AddSphere({ 0.0f, 5.0f, -4.5f}, 1.2f, 1.5f);
        physics.AddSphere({ 1.5f, 4.0f, -3.5f}, 0.3f, 0.3f);
    }

    // --------------------------------------- demo scene
    int  demo_version = 1;
    renderer->SwitchDemo(demo_version);

    // --------------------------------------- load model from config
    bool  mesh_loaded = false;
    MeshData loaded_mesh;
    if (!cfg.model_path.empty()) {
        loaded_mesh = LoadModel(cfg.model_path);
        if (loaded_mesh.valid) {
            loaded_mesh.origin = {cfg.model_x, cfg.model_y, cfg.model_z};
            renderer->LoadMesh(loaded_mesh);
            mesh_loaded = true;
        }
    }

    // ------------------------------------ UI state
    bool  fog_enabled     = true;
    bool  physics_enabled = cfg.enable_physics;
    bool  jitter_on       = cfg.enable_jitter;
    int   samples         = cfg.samples;
    bool  mouse_captured  = true;
    int   res_w           = cfg.width;
    int   res_h           = cfg.height;
    float model_pos[3]    = {cfg.model_x, cfg.model_y, cfg.model_z};
    char  model_path_buf[512] = {};
    strncpy(model_path_buf, cfg.model_path.c_str(), sizeof(model_path_buf)-1);

    bool quit = false;
    SDL_Event e;
    Uint32 last_tick = SDL_GetTicks();

    while (!quit) {
        Uint32 now = SDL_GetTicks();
        float  dt  = (now - last_tick) / 1000.0f;
        if (dt > 0.1f) dt = 0.1f;
        last_tick  = now;

        int mx = 0, my = 0;
        while (SDL_PollEvent(&e)) {
            ImGui_ImplSDL2_ProcessEvent(&e);

            if (e.type == SDL_QUIT)                          quit = true;
            if (e.type == SDL_KEYDOWN) {
                if (e.key.keysym.sym == SDLK_ESCAPE)         quit = true;
                if (e.key.keysym.sym == SDLK_F11) {
                    bool fs = SDL_GetWindowFlags(window) & SDL_WINDOW_FULLSCREEN_DESKTOP;
                    SDL_SetWindowFullscreen(window, fs ? 0 : SDL_WINDOW_FULLSCREEN_DESKTOP);
                }
                if (e.key.keysym.sym == SDLK_m) {
                    mouse_captured = !mouse_captured;
                    SDL_SetRelativeMouseMode(mouse_captured ? SDL_TRUE : SDL_FALSE);
                }
                if (e.key.keysym.sym == SDLK_v) {
                    fog_enabled = !fog_enabled;
                    renderer->ToggleFog();
                }
            }
            if (e.type == SDL_WINDOWEVENT &&
                e.window.event == SDL_WINDOWEVENT_RESIZED) {
                int nw = e.window.data1, nh = e.window.data2;
                renderer->OnResize(nw, nh);
                res_w = nw; res_h = nh;
            }
            if (e.type == SDL_MOUSEMOTION && mouse_captured)
                { mx += e.motion.xrel; my += e.motion.yrel; }
        }

        const Uint8* keys = SDL_GetKeyboardState(nullptr);
        if (mouse_captured) renderer->ProcessInput(keys, mx, my, dt);

        // Physics tick
        if (physics_enabled) {
            physics.Step(dt);
            // (Positions fed into scene in renderer update — done via SwitchDemo override)
        }

        // ---------------------------------- ImGui
        ImGui_ImplSDL2_NewFrame();
        renderer->BeginImGuiFrame();
        ImGui::NewFrame();

        ImGui::SetNextWindowPos(ImVec2(10, 10), ImGuiCond_Always);
        ImGui::SetNextWindowSize(ImVec2(310, 0), ImGuiCond_Always);
        ImGui::SetNextWindowBgAlpha(0.78f);
        ImGui::Begin("Whitted GI RayTracer", nullptr,
            ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoResize |
            ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoSavedSettings);

        // ---- Stats
        float ft = 0, gpt = 0; int rays = 0, tris = 0;
        renderer->GetStats(ft, rays, tris, gpt);
        ImGui::TextColored({0.4f,1.0f,0.4f,1}, "FPS:       %.1f", io.Framerate);
        ImGui::TextColored({1.0f,1.0f,0.4f,1}, "Frame:     %.2f ms", 1000.f/std::max(io.Framerate,0.01f));
        ImGui::TextColored({0.4f,0.8f,1.0f,1}, "Rays cast: %d", rays);
        ImGui::TextColored({0.9f,0.7f,0.5f,1}, "Triangles: %d", tris);

        ImGui::Separator();
        // ---- Demo selector
        {
            int prev = demo_version;
            ImGui::Text("Scene:");
            ImGui::RadioButton("Demo 0.2", &demo_version, 0); ImGui::SameLine();
            ImGui::RadioButton("Demo 0.3", &demo_version, 1);
            if (prev != demo_version) renderer->SwitchDemo(demo_version);
        }

        ImGui::Separator();
        // ---- Render quality
        ImGui::Text("Render quality:");
        if (ImGui::Checkbox("Fog",  &fog_enabled))     renderer->ToggleFog();
        ImGui::SameLine();
        if (ImGui::Checkbox("Jitter", &jitter_on))     renderer->ToggleJitter();
        if (ImGui::SliderInt("Samples (AA)", &samples, 1, 4))
            renderer->SetSamples(samples);

        ImGui::Separator();
        // ---- Resolution
        ImGui::Text("Resolution:");
        ImGui::SetNextItemWidth(70); ImGui::InputInt("W", &res_w, 0);
        ImGui::SameLine();
        ImGui::SetNextItemWidth(70); ImGui::InputInt("H", &res_h, 0);
        ImGui::SameLine();
        if (ImGui::Button("Apply##res")) {
            if (res_w > 100 && res_h > 100) {
                SDL_SetWindowSize(window, res_w, res_h);
                renderer->OnResize(res_w, res_h);
                cfg.width  = res_w;
                cfg.height = res_h;
            }
        }

        ImGui::Separator();
        // ---- Fullscreen
        if (ImGui::Button("Toggle Fullscreen  [F11]")) {
            bool fs = SDL_GetWindowFlags(window) & SDL_WINDOW_FULLSCREEN_DESKTOP;
            SDL_SetWindowFullscreen(window, fs ? 0 : SDL_WINDOW_FULLSCREEN_DESKTOP);
        }

        ImGui::Separator();
        // ---- Physics
        if (ImGui::Checkbox("Bullet Physics", &physics_enabled)) {
            if (physics_enabled) {
                physics.Clear();
                physics.SetFloor(-1.0f);
                physics.AddSphere({-2.0f, 3.0f, -5.0f}, 1.0f, 1.0f);
                physics.AddSphere({ 0.0f, 5.0f, -4.5f}, 1.2f, 1.5f);
                physics.AddSphere({ 1.5f, 4.0f, -3.5f}, 0.3f, 0.3f);
            }
        }

        ImGui::Separator();
        // ---- 3D model loading
        ImGui::Text("3D Model (GLB / GLTF / OBJ):");
        ImGui::SetNextItemWidth(220);
        ImGui::InputText("##mp", model_path_buf, sizeof(model_path_buf));
        ImGui::SameLine();
        if (ImGui::Button("...##browse")) {
            IGFD::FileDialogConfig fdcfg;
            fdcfg.path = ".";
            ImGuiFileDialog::Instance()->OpenDialog(
                "LoadModelDlg", "Choose 3D Model", ".glb,.gltf,.obj", fdcfg);
        }

        // Position controls
        ImGui::SetNextItemWidth(60); ImGui::InputFloat("X", &model_pos[0], 0.1f);
        ImGui::SameLine();
        ImGui::SetNextItemWidth(60); ImGui::InputFloat("Y", &model_pos[1], 0.1f);
        ImGui::SameLine();
        ImGui::SetNextItemWidth(60); ImGui::InputFloat("Z", &model_pos[2], 0.1f);

        if (ImGui::Button("Load Model") && model_path_buf[0] != '\0') {
            MeshData md = LoadModel(std::string(model_path_buf));
            if (md.valid) {
                md.origin = {model_pos[0], model_pos[1], model_pos[2]};
                renderer->LoadMesh(md);
                loaded_mesh  = md;
                mesh_loaded  = true;
                cfg.model_path = model_path_buf;
                cfg.model_x    = model_pos[0];
                cfg.model_y    = model_pos[1];
                cfg.model_z    = model_pos[2];
                SaveConfig(cfg);
            }
        }
        ImGui::SameLine();
        if (ImGui::Button("Remove Model") && mesh_loaded) {
            renderer->ClearMesh();
            mesh_loaded = false;
            renderer->SwitchDemo(demo_version);
        }

        // Update loaded model position in real-time
        if (mesh_loaded) {
            loaded_mesh.origin = {model_pos[0], model_pos[1], model_pos[2]};
            renderer->LoadMesh(loaded_mesh);
        }

        ImGui::Separator();
        ImGui::Text("Controls:");
        ImGui::TextDisabled("WASD=Move  Mouse=Look  M=Cursor  V=Fog  F11=Fullscreen");

        ImGui::End();

        // ---- File dialog popup
        if (ImGuiFileDialog::Instance()->Display("LoadModelDlg")) {
            if (ImGuiFileDialog::Instance()->IsOk()) {
                std::string sel = ImGuiFileDialog::Instance()->GetFilePathName();
                strncpy(model_path_buf, sel.c_str(), sizeof(model_path_buf)-1);
            }
            ImGuiFileDialog::Instance()->Close();
        }

        ImGui::Render();
        renderer->Render(dt);
    }

    // Save final config
    cfg.enable_physics      = physics_enabled;
    cfg.enable_jitter       = jitter_on;
    cfg.samples             = samples;
    cfg.model_x = model_pos[0];
    cfg.model_y = model_pos[1];
    cfg.model_z = model_pos[2];
    SaveConfig(cfg);

    renderer->Cleanup();
    delete renderer;

    ImGui::DestroyContext();
    SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}
