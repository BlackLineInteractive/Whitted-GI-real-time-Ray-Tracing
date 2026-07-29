#import  <Metal/Metal.h>
#import  <QuartzCore/CAMetalLayer.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_metal.h>
#include <iostream>
#include <fstream>
#include <sstream>
#include <algorithm>
#include <atomic>
#include <cmath>
#include "Renderer.h"
#include "imgui.h"
#include "backends/imgui_impl_metal.h"
#include "backends/imgui_impl_sdl2.h"

// MetalFX only available on macOS 13+
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 130000
#import <MetalFX/MetalFX.h>
#endif

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

    // Triple-buffered uniforms to avoid CPU/GPU races on in-flight frames
    static constexpr int kMaxFramesInFlight = 3;
    id<MTLBuffer>       m_buf_uniforms[kMaxFramesInFlight] = { nil, nil, nil };
    int                m_frame_index = 0;
    dispatch_semaphore_t m_frame_sema = nil;

    // Mesh GPU buffers
    id<MTLBuffer> m_buf_triangles = nil;
    id<MTLBuffer> m_buf_bvh      = nil;
    id<MTLBuffer> m_buf_mesh_mats= nil;

    // ImGui render pass
    MTLRenderPassDescriptor* m_rpdesc    = nil;
    id<CAMetalDrawable>      m_drawable  = nil;

    // Render targets for Multi-pass & MetalFX
    id<MTLTexture>           m_tex_gbuffer = nil; // RGBA16F (half-res color)
    id<MTLTexture>           m_tex_depth   = nil; // R32F (half-res depth)
    id<MTLTexture>           m_tex_motion  = nil; // RG16F (half-res motion)
    id<MTLTexture>           m_tex_mesh_arrays = nil;

#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 130000
    id<MTLFXTemporalScaler>  m_temporal_scaler = nil;
#endif

    // State
    int   m_version          = 1;
    bool  m_fog              = true;
    bool  m_jitter           = false;
    int   m_samples          = 1;
    bool  m_mesh_loaded      = false;
    float m_render_scale     = 0.5f;
    bool  m_game_mode        = true;
    float m_cam_velocity_y   = 0.0f;
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

    // GPU timing (exponential moving average over completed command buffers)
    std::atomic<double> m_gpu_ms_ema{0.0};
    std::atomic<uint64_t> m_gpu_samples{0};

    // Upload `bytes` of `data` into a GPU-private (VRAM-resident) buffer.
    // On a discrete GPU, StorageModeShared buffers stay in host memory and every
    // read crosses PCIe — fatal for BVH/triangle traversal, which is nothing but
    // scattered reads. Private storage puts them in VRAM.
    id<MTLBuffer> MakePrivateBuffer(const void* data, size_t bytes) {
        bytes = std::max<size_t>(bytes, 16);
        id<MTLBuffer> dst = [m_device newBufferWithLength:bytes
                                                  options:MTLResourceStorageModePrivate];
        if (!data) return dst;

        id<MTLBuffer> staging = [m_device newBufferWithBytes:data length:bytes
                                                     options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cmd = [m_queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
        [blit copyFromBuffer:staging sourceOffset:0
                    toBuffer:dst destinationOffset:0 size:bytes];
        [blit endEncoding];
        [cmd commit];
        [cmd waitUntilCompleted];
        return dst;
    }

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
            return MakePrivateBuffer((n == 0) ? nullptr : data, bytes);
        };

        m_buf_mats    = mkbuf(mats.data(),    mats.size(),    sizeof(GPUMaterial));
        m_buf_spheres = mkbuf(spheres.data(), spheres.size(), sizeof(GPUSphere));
        m_buf_planes  = mkbuf(planes.data(),  planes.size(),  sizeof(GPUPlane));
        m_buf_cubes   = mkbuf(cubes.data(),   cubes.size(),   sizeof(GPUCube));
        m_buf_lights  = mkbuf(lights.data(),  lights.size(),  sizeof(GPULight));

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
        MTLCompileOptions* options = [[MTLCompileOptions alloc] init];
        options.fastMathEnabled = YES;
        id<MTLLibrary> lib = [m_device newLibraryWithSource:ns_src options:options error:err];
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
        
        // Render at scaled resolution
        int half_w = std::max(1, (int)(m_render_w * m_render_scale));
        int half_h = std::max(1, (int)(m_render_h * m_render_scale));
        
        auto mktex = [&](MTLPixelFormat fmt) -> id<MTLTexture> {
            MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
                                                                                            width:half_w
                                                                                           height:half_h
                                                                                        mipmapped:NO];
            desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
            desc.storageMode = MTLStorageModePrivate;
            return [m_device newTextureWithDescriptor:desc];
        };

        m_tex_gbuffer = mktex(MTLPixelFormatRGBA16Float);
        m_tex_depth   = mktex(MTLPixelFormatR32Float);
        m_tex_motion  = mktex(MTLPixelFormatRG16Float);

#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 130000
        if (@available(macOS 13.0, *)) {
            MTLFXTemporalScalerDescriptor* sdesc = [MTLFXTemporalScalerDescriptor new];
            sdesc.inputWidth = half_w;
            sdesc.inputHeight = half_h;
            sdesc.outputWidth = m_render_w;
            sdesc.outputHeight = m_render_h;
            sdesc.colorTextureFormat = MTLPixelFormatRGBA16Float;
            sdesc.depthTextureFormat = MTLPixelFormatR32Float;
            sdesc.motionTextureFormat = MTLPixelFormatRG16Float;
            sdesc.outputTextureFormat = m_layer.pixelFormat;
            sdesc.autoExposureEnabled = NO;
            m_temporal_scaler = [sdesc newTemporalScalerWithDevice:m_device];
        }
#endif
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

        for (int i = 0; i < kMaxFramesInFlight; i++) {
            m_buf_uniforms[i] = [m_device newBufferWithLength:sizeof(GPUUniforms)
                                                     options:MTLResourceStorageModeShared];
        }
        m_frame_sema = dispatch_semaphore_create(kMaxFramesInFlight);

        ImGui_ImplSDL2_InitForMetal(win);
        ImGui_ImplMetal_Init(m_device);
        return true;
    }

    // ------------------------------------------------- Input
    void ProcessInput(const Uint8* keys, int mx, int my, float dt) override {
        double old_yaw = m_yaw, old_pitch = m_pitch;
        Vec3 old_pos = m_cam_pos;

        m_yaw   -= mx * 0.003;
        m_pitch -= my * 0.003;
        m_pitch  = std::clamp(m_pitch, -1.5, 1.5);

        Vec3 fwd(cos(m_yaw)*cos(m_pitch), sin(m_pitch), sin(m_yaw)*cos(m_pitch));
        Vec3 right = glm::normalize(glm::cross(Vec3(0,1,0), fwd));
        Vec3 flat  = glm::normalize(glm::cross(Vec3(0,1,0), right));

        float spd = 3.0f * dt;
        if (keys[SDL_SCANCODE_W]) m_cam_pos = m_cam_pos - flat  * spd;
        if (keys[SDL_SCANCODE_S]) m_cam_pos = m_cam_pos + flat  * spd;
        if (keys[SDL_SCANCODE_A]) m_cam_pos = m_cam_pos - right * spd;
        if (keys[SDL_SCANCODE_D]) m_cam_pos = m_cam_pos + right * spd;
        
        if (m_game_mode) {
            // Apply gravity
            m_cam_velocity_y -= 9.8f * dt;
            m_cam_pos.y += m_cam_velocity_y * dt;
            
            // Floor collision
            float floor_y = 1.0f; // Eye height above the floor plane
            if (m_cam_pos.y <= floor_y) {
                m_cam_pos.y = floor_y;
                m_cam_velocity_y = 0.0f;
                // Jump
                if (keys[SDL_SCANCODE_SPACE]) {
                    m_cam_velocity_y = 4.0f;
                }
            }
        } else {
            if (keys[SDL_SCANCODE_Q]) m_cam_pos.y -= spd;
            if (keys[SDL_SCANCODE_E]) m_cam_pos.y += spd;
        }

#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 130000
        if (@available(macOS 13.0, *)) {
            if (m_temporal_scaler) {
                if (old_yaw != m_yaw || old_pitch != m_pitch || old_pos.x != m_cam_pos.x || old_pos.y != m_cam_pos.y || old_pos.z != m_cam_pos.z) {
                    m_temporal_scaler.reset = YES;
                } else {
                    m_temporal_scaler.reset = NO;
                }
            }
        }
#endif
    }

    void ToggleFog()     override { m_fog    = !m_fog; }

    void SetSamples(int samples) override {
        m_samples = samples;
    }

    void SetMaxDepth(int depth) override {
        m_uniforms.max_depth = depth;
    }

    void SetGameMode(bool enabled) override {
        m_game_mode = enabled;
        if (enabled && m_cam_pos.y < 1.0f) {
            m_cam_pos.y = 1.0f;
            m_cam_velocity_y = 0.0f;
        }
    }

    void SetRenderScale(float scale) override {
        if (std::abs(m_render_scale - scale) > 0.01f) {
            m_render_scale = scale;
            CreateRenderTargets();
        }
    }

    float GetRenderScale() const override { return m_render_scale; }

    void SwitchDemo(int version) override {
        m_version = version;
        SetupScene(version);
    }

    // ------------------------------------------------- Mesh loading
    void LoadMesh(const MeshData& mesh) override {
        if (!mesh.valid || mesh.triangles.empty()) return;

        auto mkbuf = [&](const void* data, size_t bytes) -> id<MTLBuffer> {
            return MakePrivateBuffer(data, bytes);
        };

        m_buf_triangles = mkbuf(mesh.triangles.data(),
                                mesh.triangles.size() * sizeof(GPUTriangle));
        m_buf_bvh       = mkbuf(mesh.bvh_nodes.data(),
                                mesh.bvh_nodes.size() * sizeof(GPUBVHNode));
        m_buf_mesh_mats = mkbuf(mesh.materials.data(),
                                mesh.materials.size() * sizeof(GPUMaterial));

        if (!mesh.texture_array_data.empty()) {
            MTLTextureDescriptor* tdesc = [MTLTextureDescriptor new];
            tdesc.textureType = MTLTextureType2DArray;
            tdesc.pixelFormat = MTLPixelFormatRGBA8Unorm;
            tdesc.width = 512;
            tdesc.height = 512;
            tdesc.arrayLength = mesh.materials.size();
            tdesc.usage = MTLTextureUsageShaderRead;
            
            m_tex_mesh_arrays = [m_device newTextureWithDescriptor:tdesc];
            for (size_t i = 0; i < mesh.materials.size(); i++) {
                MTLRegion region = MTLRegionMake2D(0, 0, 512, 512);
                [m_tex_mesh_arrays replaceRegion:region
                                     mipmapLevel:0
                                           slice:i
                                       withBytes:mesh.texture_array_data.data() + i * 512 * 512 * 4
                                     bytesPerRow:512 * 4
                                   bytesPerImage:512 * 512 * 4];
            }
        } else {
            m_tex_mesh_arrays = nil;
        }

        m_num_triangles  = int(mesh.triangles.size());
        m_num_bvh_nodes  = int(mesh.bvh_nodes.size());
        m_num_mesh_mats  = int(mesh.materials.size());
        m_mesh_loaded    = true;
        m_uniforms.enable_triangles = 1;

        m_uniforms.enable_triangles = 1;
        m_uniforms.num_triangles    = m_num_triangles;
        m_uniforms.num_bvh_nodes    = m_num_bvh_nodes;
        m_uniforms.num_spheres      = 0;
        m_uniforms.num_cubes        = 0;
        set_vec3(m_uniforms.model_pos, mesh.origin);
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

    void SetMeshOrigin(float x, float y, float z) override {
        set_vec3(m_uniforms.model_pos, Vec3(x, y, z));
    }

    // ------------------------------------------------- OnResize
    void OnResize(int w, int h) override {
        m_render_w = w;
        m_render_h = h;
        SyncLayerSize();
    }

    // ------------------------------------------------- BeginImGuiFrame
    void BeginImGuiFrame() override {
        m_drawable = [m_layer nextDrawable];
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

            // Block until a uniform buffer slot is free (max frames in flight).
            dispatch_semaphore_wait(m_frame_sema, DISPATCH_TIME_FOREVER);
            m_frame_index = (m_frame_index + 1) % kMaxFramesInFlight;
            id<MTLBuffer> uniforms_buf = m_buf_uniforms[m_frame_index];

            // Update uniforms
            Vec3 fwd(cos(m_yaw)*cos(m_pitch), sin(m_pitch), sin(m_yaw)*cos(m_pitch));
            Vec3 right = glm::normalize(glm::cross(Vec3(0,1,0), fwd));
            Vec3 up    = glm::normalize(glm::cross(fwd, right));

            
            m_uniforms.tan_half_fov  = float(tan((60.0*M_PI/180.0) / 2.0));
            m_uniforms.aspect_ratio  = float(m_render_w) / float(m_render_h);
            m_uniforms.screen_width  = float(std::max(1, m_render_w / 2));
            m_uniforms.screen_height = float(std::max(1, m_render_h / 2));
            set_vec3(m_uniforms.ambient_light, {0.3, 0.4, 0.6});
            set_vec3(m_uniforms.camera_origin,  m_cam_pos);
            set_vec3(m_uniforms.camera_forward, fwd);
            set_vec3(m_uniforms.camera_right,   right);
            set_vec3(m_uniforms.camera_up,      up);
            m_uniforms.time = float(SDL_GetTicks() % 10000000) / 1000.0f;
            m_uniforms.enable_fog          = m_fog ? 1 : 0;
            m_uniforms.enable_jitter       = m_jitter ? 1 : 0;
            m_uniforms.samples_per_pixel   = m_samples;

            memcpy([uniforms_buf contents], &m_uniforms, sizeof(GPUUniforms));

            id<MTLCommandBuffer> cmd = [m_queue commandBuffer];

            // --- Compute pass (ray tracing)
            id<MTLComputeCommandEncoder> ce = [cmd computeCommandEncoder];
            [ce setComputePipelineState:(m_version == 1 ? m_pipeline03 : m_pipeline02)];
            [ce setTexture:m_tex_gbuffer atIndex:0];
            if (m_tex_mesh_arrays) {
                [ce setTexture:m_tex_mesh_arrays atIndex:1];
            } else {
                [ce setTexture:m_tex_gbuffer atIndex:1]; // dummy bind
            }
            [ce setTexture:m_tex_depth atIndex:2];
            [ce setTexture:m_tex_motion atIndex:3];

            [ce setBuffer:m_buf_mats       offset:0 atIndex:0];
            [ce setBuffer:m_buf_spheres    offset:0 atIndex:1];
            [ce setBuffer:m_buf_planes     offset:0 atIndex:2];
            [ce setBuffer:m_buf_cubes      offset:0 atIndex:3];
            // atIndex:4 reserved for octahedrons
            [ce setBuffer:m_buf_lights     offset:0 atIndex:5];
            [ce setBuffer:uniforms_buf     offset:0 atIndex:6];
            if (m_mesh_loaded && m_buf_triangles) {
                [ce setBuffer:m_buf_triangles offset:0 atIndex:7];
                [ce setBuffer:m_buf_bvh       offset:0 atIndex:8];
                [ce setBuffer:m_buf_mesh_mats offset:0 atIndex:9];
            }
            [ce dispatchThreads:MTLSizeMake(m_render_w/2, m_render_h/2, 1)
             threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
            [ce endEncoding];

#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 130000
            if (@available(macOS 13.0, *)) {
                if (m_temporal_scaler) {
                    m_temporal_scaler.colorTexture = m_tex_gbuffer;
                    m_temporal_scaler.depthTexture = m_tex_depth;
                    m_temporal_scaler.motionTexture = m_tex_motion;
                    m_temporal_scaler.outputTexture = drawable.texture;
                    [m_temporal_scaler encodeToCommandBuffer:cmd];
                }
            }
#endif

            // --- Render pass (ImGui overlay)
            m_rpdesc.colorAttachments[0].texture     = drawable.texture;
            m_rpdesc.colorAttachments[0].loadAction  = MTLLoadActionLoad;
            m_rpdesc.colorAttachments[0].storeAction = MTLStoreActionStore;

            id<MTLRenderCommandEncoder> re = [cmd renderCommandEncoderWithDescriptor:m_rpdesc];
            ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cmd, re);
            [re endEncoding];

            // Release the uniform-buffer slot once the GPU is done with this frame.
            __block dispatch_semaphore_t sema = m_frame_sema;
            __block std::atomic<double>* ema  = &m_gpu_ms_ema;
            __block std::atomic<uint64_t>* nsamp = &m_gpu_samples;
            [cmd addCompletedHandler:^(id<MTLCommandBuffer> cb) {
                double ms = (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;
                if (ms > 0.0) {
                    double prev = ema->load(std::memory_order_relaxed);
                    ema->store(prev <= 0.0 ? ms : prev * 0.9 + ms * 0.1,
                               std::memory_order_relaxed);
                    nsamp->fetch_add(1, std::memory_order_relaxed);
                }
                dispatch_semaphore_signal(sema);
            }];

            [cmd presentDrawable:drawable];
            [cmd commit];
            m_drawable = nil;
        }
    }

    // ------------------------------------------------- Stats
    void GetStats(float& ft, int& rays, int& tris, float& gpt) override {
        ft   = 0;
        rays = m_total_rays;
        tris = m_num_triangles;
        gpt  = float(m_gpu_ms_ema.load(std::memory_order_relaxed));
    }

    void SetVSync(bool enabled) override {
        if (m_layer) m_layer.displaySyncEnabled = enabled ? YES : NO;
    }

    // ------------------------------------------------- Cleanup
    void Cleanup() override {
        ImGui_ImplMetal_Shutdown();
        ImGui_ImplSDL2_Shutdown();
        if (m_metal_view) SDL_Metal_DestroyView(m_metal_view);
    }
};

IRenderer* CreateRendererMetal() { return new RendererMetal(); }
