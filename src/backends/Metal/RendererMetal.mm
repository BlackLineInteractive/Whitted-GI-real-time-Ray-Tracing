#import  <Metal/Metal.h>
#import  <QuartzCore/CAMetalLayer.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_metal.h>
#include <iostream>
#include <fstream>
#include <sstream>
#include <algorithm>
#include <cmath>
#include "Renderer.h"
#include "imgui.h"
#include "backends/imgui_impl_metal.h"
#include "backends/imgui_impl_sdl2.h"

// ---------------------------------------------------------- shader loader ---

static std::string ReadShader(const std::string& rel_path) {
    // Try next to the binary first, then one directory up (for build subdirs)
    char* raw = SDL_GetBasePath();
    std::string base = raw ? raw : "";
    if (raw) SDL_free(raw);

    for (auto prefix : {base, base + "../"}) {
        std::ifstream f(prefix + rel_path);
        if (f.is_open()) {
            std::stringstream ss; ss << f.rdbuf(); return ss.str();
        }
    }
    std::cerr << "[Metal] Cannot find shader: " << rel_path << std::endl;
    return "";
}

// --------------------------------------------------------- Metal Renderer ---

class RendererMetal : public IRenderer {
    // Window / layer
    SDL_Window*     m_window      = nullptr;
    SDL_MetalView   m_metal_view  = nullptr;
    CAMetalLayer*   m_layer       = nil;
    id<MTLDevice>          m_device       = nil;
    id<MTLCommandQueue>    m_queue        = nil;

    // Pipeline states (one per demo version)
    id<MTLComputePipelineState> m_pipeline02 = nil;
    id<MTLComputePipelineState> m_pipeline03 = nil;

    // Scene GPU buffers (primitives)
    id<MTLBuffer> m_buf_mats     = nil;
    id<MTLBuffer> m_buf_spheres  = nil;
    id<MTLBuffer> m_buf_planes   = nil;
    id<MTLBuffer> m_buf_cubes    = nil;
    id<MTLBuffer> m_buf_lights   = nil;
    id<MTLBuffer> m_buf_uniforms = nil;

    // Mesh GPU buffers
    id<MTLBuffer> m_buf_triangles = nil;
    id<MTLBuffer> m_buf_bvh      = nil;
    id<MTLBuffer> m_buf_mesh_mats= nil;

    // Needle GI buffers
    std::vector<GPUNeedle> m_needles_cpu;
    id<MTLBuffer> m_buf_needles  = nil;

    // ImGui render pass
    MTLRenderPassDescriptor* m_rpdesc    = nil;
    id<CAMetalDrawable>      m_drawable  = nil;

    // Render targets for Multi-pass
    id<MTLTexture>           m_tex_gbuffer = nil; // RGBA16F
    id<MTLTexture>           m_tex_color   = nil; // RGBA16F

    // State
    int   m_version          = 1;
    bool  m_fog              = true;
    bool  m_jitter           = false;
    int   m_samples          = 1;
    bool  m_mesh_loaded      = false;
    int   m_render_w         = 0;
    int   m_render_h         = 0;
    int   m_num_triangles    = 0;
    int   m_num_bvh_nodes    = 0;
    int   m_num_mesh_mats    = 0;

    GPUUniforms m_uniforms   = {};
    Vec3        m_cam_pos    = {0, 1.0, 2.0};
    double      m_yaw        = 0.0;
    double      m_pitch      = 0.0;

    int m_total_rays = 0;

    // ------------------------------------------------- scene setup
    void SetupScene(int version) {
        // Materials
        std::vector<GPUMaterial> mats;
        auto addm = [&](const Material& m) -> int {
            GPUMaterial gm{};
            set_vec3(gm.albedo, m.albedo);
            gm.roughness = float(m.roughness);
            set_vec3(gm.emission, m.emission);
            gm.metallic         = float(m.metallic);
            set_vec3(gm.albedo2, m.albedo2);
            gm.refractive_index = float(m.refractive_index);
            gm.type             = int(m.type);
            mats.push_back(gm); return int(mats.size()) - 1;
        };

        int i_floor  = addm(Material(CHECKERBOARD, {0.8,0.8,0.8}, {0,0,0}, 0.8, 0.0, 1.0, {0.2,0.2,0.2}));
        int i_chrome = addm(Material(METAL,        {0.9,0.9,0.95},{0,0,0}, 0.05,1.0));
        int i_glass  = addm(Material(GLASS,        {0.98,0.99,1.0},{0,0,0},0.0, 0.0, 1.5));
        int i_red    = addm(Material(DIFFUSE,      {0.8,0.15,0.1},{0,0,0}, 0.9, 0.0));
        int i_blue   = addm(Material(EMISSIVE,     {0,0,0},{0.3,0.5,2.0}, 1.0, 0.0));
        int i_water  = addm(Material(WATER,        {0.0,0.3,0.4},{0,0,0},  0.0, 0.0, 1.33));

        std::vector<GPUPlane> planes;
        if (version == 1)
            planes = {{{0,1,0},-1.0f,i_floor,0,0,0},{{0,1,0},-0.85f,i_water,0,0,0}};
        else
            planes = {{{0,1,0},-1.0f,i_floor,0,0,0}};

        std::vector<GPUSphere> spheres = {
            {{-2.0f, 0.0f,-5.0f},1.0f,i_chrome,0,0,0},
            {{ 0.0f, 0.2f,-4.5f},1.2f,i_glass, 0,0,0},
            {{ 1.5f, 0.5f,-3.5f},0.3f,i_blue,  0,0,0}
        };
        std::vector<GPUCube> cubes  = {{{1.5f,-0.5f,-6.0f},0,{0.5f,0.5f,0.5f},i_red}};
        std::vector<GPULight> lights = {
            {{-5.0f,8.0f,-2.0f},50.0f,{1.0f,0.95f,0.9f},2.0f},
            {{ 1.5f,0.5f,-3.5f},15.0f,{0.3f,0.5f,1.0f}, 0.2f}
        };

        auto mkbuf = [&](const void* data, size_t n, size_t sz) -> id<MTLBuffer> {
            size_t bytes = std::max(n * sz, sz);
            if (!data || n == 0)
                return [m_device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
            return [m_device newBufferWithBytes:data length:bytes options:MTLResourceStorageModeShared];
        };

        m_buf_mats    = mkbuf(mats.data(),    mats.size(),    sizeof(GPUMaterial));
        m_buf_spheres = mkbuf(spheres.data(), spheres.size(), sizeof(GPUSphere));
        m_buf_planes  = mkbuf(planes.data(),  planes.size(),  sizeof(GPUPlane));
        m_buf_cubes   = mkbuf(cubes.data(),   cubes.size(),   sizeof(GPUCube));
        m_buf_lights  = mkbuf(lights.data(),  lights.size(),  sizeof(GPULight));

        // Generate Needles for primitives
        m_needles_cpu.clear();
        int obj_idx = 0;
        auto add_needle = [&](Vec3 p, Vec3 n, float r, int id) {
            GPUNeedle needle{};
            set_vec3(needle.position, p);
            set_vec3(needle.normal, n);
            needle.radius = r;
            needle.object_id = id;
            set_vec3(needle.radiance, Vec3(0,0,0));
            m_needles_cpu.push_back(needle);
        };

        for (auto& s : spheres) {
            // Needles on 6 extremes of sphere
            float r = s.radius;
            Vec3 c(s.center[0], s.center[1], s.center[2]);
            add_needle(c + Vec3(r,0,0), Vec3(1,0,0), r*1.5f, obj_idx);
            add_needle(c + Vec3(-r,0,0), Vec3(-1,0,0), r*1.5f, obj_idx);
            add_needle(c + Vec3(0,r,0), Vec3(0,1,0), r*1.5f, obj_idx);
            add_needle(c + Vec3(0,-r,0), Vec3(0,-1,0), r*1.5f, obj_idx);
            add_needle(c + Vec3(0,0,r), Vec3(0,0,1), r*1.5f, obj_idx);
            add_needle(c + Vec3(0,0,-r), Vec3(0,0,-1), r*1.5f, obj_idx);
            obj_idx++;
        }
        for (auto& cb : cubes) {
            // Needles on 6 face centers
            float hx = cb.half_size[0], hy = cb.half_size[1], hz = cb.half_size[2];
            Vec3 c(cb.center[0], cb.center[1], cb.center[2]);
            float r = std::max({hx, hy, hz}) * 2.0f;
            add_needle(c + Vec3(hx,0,0), Vec3(1,0,0), r, obj_idx);
            add_needle(c + Vec3(-hx,0,0), Vec3(-1,0,0), r, obj_idx);
            add_needle(c + Vec3(0,hy,0), Vec3(0,1,0), r, obj_idx);
            add_needle(c + Vec3(0,-hy,0), Vec3(0,-1,0), r, obj_idx);
            add_needle(c + Vec3(0,0,hz), Vec3(0,0,1), r, obj_idx);
            add_needle(c + Vec3(0,0,-hz), Vec3(0,0,-1), r, obj_idx);
            obj_idx++;
        }
        
        if (!m_needles_cpu.empty()) {
            m_buf_needles = mkbuf(m_needles_cpu.data(), m_needles_cpu.size(), sizeof(GPUNeedle));
        } else {
            m_buf_needles = nil;
        }

        m_uniforms.num_spheres   = int(spheres.size());
        m_uniforms.num_planes    = int(planes.size());
        m_uniforms.num_cubes     = int(cubes.size());
        m_uniforms.num_lights    = int(lights.size());
        m_uniforms.enable_triangles = 0;
        m_mesh_loaded = false;
        m_num_triangles = 0;

        m_total_rays = m_render_w * m_render_h * 4 * 7;
    }

    id<MTLComputePipelineState> CompileKernel(const std::string& path, NSError** err) {
        std::string src = ReadShader(path);
        if (src.empty()) return nil;
        NSString* ns_src = [NSString stringWithUTF8String:src.c_str()];
        id<MTLLibrary> lib = [m_device newLibraryWithSource:ns_src options:nil error:err];
        if (!lib) return nil;
        id<MTLFunction> fn = [lib newFunctionWithName:@"raytrace_kernel"];
        if (!fn) { std::cerr << "[Metal] raytrace_kernel not found in " << path << std::endl; return nil; }
        return [m_device newComputePipelineStateWithFunction:fn error:err];
    }

    void SyncLayerSize() {
        int dw, dh;
        SDL_Metal_GetDrawableSize(m_window, &dw, &dh);
        if (dw != m_render_w || dh != m_render_h) {
            m_layer.drawableSize = CGSizeMake(dw, dh);
            m_render_w = dw;
            m_render_h = dh;
            CreateRenderTargets();
            std::cout << "[Metal] Drawable size: " << dw << "×" << dh << std::endl;
        }
    }

    void CreateRenderTargets() {
        if (m_render_w <= 0 || m_render_h <= 0) return;
        
        MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                        width:m_render_w
                                                                                       height:m_render_h
                                                                                    mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        desc.storageMode = MTLStorageModePrivate;
        
        m_tex_gbuffer = [m_device newTextureWithDescriptor:desc];
        m_tex_color   = [m_device newTextureWithDescriptor:desc];
    }

public:
    // ------------------------------------------------- Init
    bool Init(SDL_Window* win, int width, int height) override {
        m_window   = win;
        m_render_w = width;
        m_render_h = height;

        m_device = MTLCreateSystemDefaultDevice();
        if (!m_device) { std::cerr << "[Metal] No device" << std::endl; return false; }

        m_metal_view = SDL_Metal_CreateView(win);
        m_layer = (__bridge CAMetalLayer*)SDL_Metal_GetLayer(m_metal_view);
        m_layer.device      = m_device;
        m_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        m_layer.framebufferOnly = NO;  // allow compute shader writes
        SyncLayerSize();

        m_queue = [m_device newCommandQueue];
        m_rpdesc = [MTLRenderPassDescriptor new];

        NSError* err = nil;
        m_pipeline02 = CompileKernel("src/backends/Metal/shader_v02.metal", &err);
        if (!m_pipeline02) {
            std::cerr << "[Metal] Shader v02: " << (err ? [[err localizedDescription] UTF8String] : "?") << std::endl;
            return false;
        }
        m_pipeline03 = CompileKernel("src/backends/Metal/shader_v03.metal", &err);
        if (!m_pipeline03) {
            std::cerr << "[Metal] Shader v03: " << (err ? [[err localizedDescription] UTF8String] : "?") << std::endl;
            return false;
        }

        m_buf_uniforms = [m_device newBufferWithLength:sizeof(GPUUniforms)
                                               options:MTLResourceStorageModeShared];

        ImGui_ImplSDL2_InitForMetal(win);
        ImGui_ImplMetal_Init(m_device);
        return true;
    }

    // ------------------------------------------------- Input
    void ProcessInput(const Uint8* keys, int mx, int my, float dt) override {
        m_yaw   -= mx * 0.003;
        m_pitch -= my * 0.003;
        m_pitch  = std::clamp(m_pitch, -1.5, 1.5);

        Vec3 fwd(cos(m_yaw)*cos(m_pitch), sin(m_pitch), sin(m_yaw)*cos(m_pitch));
        Vec3 right = Vec3(0,1,0).cross(fwd).normalize();
        Vec3 flat  = Vec3(0,1,0).cross(right).normalize();

        float spd = 3.0f * dt;
        if (keys[SDL_SCANCODE_W]) m_cam_pos = m_cam_pos - flat  * spd;
        if (keys[SDL_SCANCODE_S]) m_cam_pos = m_cam_pos + flat  * spd;
        if (keys[SDL_SCANCODE_A]) m_cam_pos = m_cam_pos - right * spd;
        if (keys[SDL_SCANCODE_D]) m_cam_pos = m_cam_pos + right * spd;
        if (keys[SDL_SCANCODE_Q]) m_cam_pos.y -= spd;
        if (keys[SDL_SCANCODE_E]) m_cam_pos.y += spd;
    }

    void ToggleFog()     override { m_fog    = !m_fog; }
    void ToggleJitter()  override { m_jitter = !m_jitter; }

    void SetSamples(int samples) override {
        m_samples = samples;
    }

    void SetDebugMode(int mode) override {
        m_uniforms.debug_mode = mode;
    }

    void SwitchDemo(int version) override {
        m_version = version;
        SetupScene(version);
    }

    // ------------------------------------------------- Mesh loading
    void LoadMesh(const MeshData& mesh) override {
        if (!mesh.valid || mesh.triangles.empty()) return;

        auto mkbuf = [&](const void* data, size_t bytes) -> id<MTLBuffer> {
            return [m_device newBufferWithBytes:data length:bytes
                                       options:MTLResourceStorageModeShared];
        };

        m_buf_triangles = mkbuf(mesh.triangles.data(),
                                mesh.triangles.size() * sizeof(GPUTriangle));
        m_buf_bvh       = mkbuf(mesh.bvh_nodes.data(),
                                mesh.bvh_nodes.size() * sizeof(GPUBVHNode));
        m_buf_mesh_mats = mkbuf(mesh.materials.data(),
                                mesh.materials.size() * sizeof(GPUMaterial));

        m_num_triangles  = int(mesh.triangles.size());
        m_num_bvh_nodes  = int(mesh.bvh_nodes.size());
        m_num_mesh_mats  = int(mesh.materials.size());
        m_mesh_loaded    = true;
        m_uniforms.enable_triangles = 1;

        // Generate Needles for Mesh (Decimation using distance threshold / extreme vertices)
        m_needles_cpu.clear();
        float min_dist_sq = 1.0f; // Threshold for decimation
        int obj_id = 999;
        auto add_needle = [&](Vec3 p, Vec3 n, float r) {
            GPUNeedle needle{};
            set_vec3(needle.position, p);
            set_vec3(needle.normal, n);
            needle.radius = r;
            needle.object_id = obj_id;
            set_vec3(needle.radiance, Vec3(0,0,0));
            m_needles_cpu.push_back(needle);
        };

        for (const auto& tri : mesh.triangles) {
            Vec3 v0(tri.v0[0], tri.v0[1], tri.v0[2]);
            Vec3 n0(tri.n0[0], tri.n0[1], tri.n0[2]);
            
            bool too_close = false;
            for (const auto& nd : m_needles_cpu) {
                Vec3 np(nd.position[0], nd.position[1], nd.position[2]);
                if ((v0 - np).length_sq() < min_dist_sq) {
                    too_close = true; break;
                }
            }
            if (!too_close) {
                add_needle(v0, n0, 2.0f);
            }
        }
        std::cout << "[Metal] Generated " << m_needles_cpu.size() << " needles for mesh." << std::endl;
        
        if (!m_needles_cpu.empty()) {
            m_buf_needles = mkbuf(m_needles_cpu.data(), m_needles_cpu.size() * sizeof(GPUNeedle));
        }

        // Apply origin offset into uniforms
        m_uniforms.enable_triangles = 1;
        m_uniforms.num_triangles    = m_num_triangles;
        m_uniforms.num_spheres      = 0;
        m_uniforms.num_cubes        = 0;
        std::cout << "[Metal] Mesh loaded: " << m_num_triangles << " tris, "
                  << m_num_bvh_nodes << " BVH nodes" << std::endl;
    }

    void ClearMesh() override {
        m_mesh_loaded = false;
        m_buf_triangles = nil;
        m_buf_bvh       = nil;
        m_buf_mesh_mats = nil;
        m_num_triangles = 0;
        m_uniforms.enable_triangles = 0;
        m_uniforms.num_triangles    = 0;
    }

    // ------------------------------------------------- OnResize
    void OnResize(int w, int h) override {
        m_render_w = w;
        m_render_h = h;
        SyncLayerSize();
    }

    // ------------------------------------------------- BeginImGuiFrame
    void BeginImGuiFrame() override {
        m_drawable = [[m_layer nextDrawable] retain];
        if (!m_drawable) return;

        m_rpdesc.colorAttachments[0].texture     = m_drawable.texture;
        m_rpdesc.colorAttachments[0].loadAction  = MTLLoadActionLoad;
        m_rpdesc.colorAttachments[0].storeAction = MTLStoreActionStore;
        ImGui_ImplMetal_NewFrame(m_rpdesc);
    }

    // ------------------------------------------------- Render
    void Render(float dt) override {
        @autoreleasepool {
            if (!m_drawable) return;
            id<CAMetalDrawable> drawable = m_drawable;

            // Update uniforms
            Vec3 fwd(cos(m_yaw)*cos(m_pitch), sin(m_pitch), sin(m_yaw)*cos(m_pitch));
            Vec3 right = Vec3(0,1,0).cross(fwd).normalize();
            Vec3 up    = fwd.cross(right).normalize();

            m_uniforms.max_depth     = 7;
            m_uniforms.tan_half_fov  = float(tan((60.0*M_PI/180.0) / 2.0));
            m_uniforms.aspect_ratio  = float(m_render_w) / float(m_render_h);
            m_uniforms.screen_width  = float(m_render_w);
            m_uniforms.screen_height = float(m_render_h);
            set_vec3(m_uniforms.ambient_light, {0.3, 0.4, 0.6});
            set_vec3(m_uniforms.camera_origin,  m_cam_pos);
            set_vec3(m_uniforms.camera_forward, fwd);
            set_vec3(m_uniforms.camera_right,   right);
            set_vec3(m_uniforms.camera_up,      up);
            m_uniforms.time = float(SDL_GetTicks() % 10000000) / 1000.0f;
            m_uniforms.enable_fog          = m_fog ? 1 : 0;
            m_uniforms.enable_jitter       = m_jitter ? 1 : 0;
            m_uniforms.samples_per_pixel   = m_samples;

            memcpy([m_buf_uniforms contents], &m_uniforms, sizeof(GPUUniforms));

            id<MTLCommandBuffer> cmd = [m_queue commandBuffer];

            // --- Compute pass (ray tracing)
            id<MTLComputePipelineState> ps = (m_version == 0) ? m_pipeline02 : m_pipeline03;
            id<MTLComputeCommandEncoder> ce = [cmd computeCommandEncoder];
            [ce setComputePipelineState:ps];
            [ce setTexture:drawable.texture atIndex:0];
            [ce setBuffer:m_buf_mats     offset:0 atIndex:0];
            [ce setBuffer:m_buf_spheres  offset:0 atIndex:1];
            [ce setBuffer:m_buf_planes   offset:0 atIndex:2];
            [ce setBuffer:m_buf_cubes    offset:0 atIndex:3];
            // atIndex:4 reserved for octahedrons
            [ce setBuffer:m_buf_lights   offset:0 atIndex:5];
            [ce setBuffer:m_buf_uniforms offset:0 atIndex:6];
            if (m_mesh_loaded && m_buf_triangles) {
                [ce setBuffer:m_buf_triangles offset:0 atIndex:7];
                [ce setBuffer:m_buf_bvh       offset:0 atIndex:8];
                [ce setBuffer:m_buf_mesh_mats offset:0 atIndex:9];
            }
            [ce dispatchThreads:MTLSizeMake(m_render_w, m_render_h, 1)
             threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
            [ce endEncoding];

            // --- Render pass (ImGui overlay)
            m_rpdesc.colorAttachments[0].texture     = drawable.texture;
            m_rpdesc.colorAttachments[0].loadAction  = MTLLoadActionLoad;
            m_rpdesc.colorAttachments[0].storeAction = MTLStoreActionStore;

            id<MTLRenderCommandEncoder> re = [cmd renderCommandEncoderWithDescriptor:m_rpdesc];
            ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cmd, re);
            [re endEncoding];

            [cmd presentDrawable:drawable];
            [cmd commit];

            [m_drawable release];
            m_drawable = nil;
        }
    }

    // ------------------------------------------------- Stats
    void GetStats(float& ft, int& rays, int& tris, float& gpt) override {
        ft   = 0;
        rays = m_total_rays;
        tris = m_num_triangles;
        gpt  = 0;
    }

    // ------------------------------------------------- Cleanup
    void Cleanup() override {
        ImGui_ImplMetal_Shutdown();
        ImGui_ImplSDL2_Shutdown();
        if (m_metal_view) SDL_Metal_DestroyView(m_metal_view);
    }
};

IRenderer* CreateRendererMetal() { return new RendererMetal(); }
