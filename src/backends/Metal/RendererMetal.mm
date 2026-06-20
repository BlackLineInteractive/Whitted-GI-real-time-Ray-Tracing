#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <SDL2/SDL.h>
#include <iostream>
#include <fstream>
#include <sstream>
#include <algorithm>
#include "Renderer.h"
#include "imgui.h"
#include "backends/imgui_impl_metal.h"
#include "backends/imgui_impl_sdl2.h"

std::string ReadShader(const std::string& path) {
    char* basePathStr = SDL_GetBasePath();
    std::string basePath = basePathStr ? basePathStr : "";
    if (basePathStr) SDL_free(basePathStr);

    std::string fullPath = basePath + path;
    std::ifstream f(fullPath);
    if (!f.is_open()) {
        fullPath = basePath + "../" + path;
        f.open(fullPath);
    }
    if (!f.is_open()) {
        std::cerr << "Failed to find shader file: " << path << std::endl;
        return "";
    }
    std::stringstream buffer;
    buffer << f.rdbuf();
    return buffer.str();
}

class RendererMetal : public IRenderer {
    SDL_Window* window = nullptr;
    CAMetalLayer* metalLayer = nullptr;
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> commandQueue = nil;
    
    id<MTLComputePipelineState> pipelineState02 = nil;
    id<MTLComputePipelineState> pipelineState03 = nil;
    
    id<MTLBuffer> buf_mats = nil;
    id<MTLBuffer> buf_spheres = nil;
    id<MTLBuffer> buf_planes = nil;
    id<MTLBuffer> buf_cubes = nil;
    id<MTLBuffer> buf_lights = nil;
    id<MTLBuffer> buf_uniforms = nil;

    MTLRenderPassDescriptor* renderPassDescriptor = nil;
    id<CAMetalDrawable> currentDrawable = nil;
    
    int current_version = 1;
    bool fog_enabled = true;
    Vec3 cam_pos;
    double cam_yaw = 0.0, cam_pitch = 0.0;
    
    int render_width, render_height;
    
    GPUUniforms uniforms = {};
    int total_rays = 0;
    int total_tris = 0;

    void SetupScene(int version) {
        std::vector<GPUMaterial> gpu_mats;
        auto add_mat = [&](const Material& m)->int {
            GPUMaterial gm;
            set_vec3(gm.albedo, m.albedo); gm.roughness = (float)m.roughness;
            set_vec3(gm.emission, m.emission); gm.metallic = (float)m.metallic;
            set_vec3(gm.albedo2, m.albedo2); gm.refractive_index = (float)m.refractive_index;
            gm.type = m.type; gm.pad1=gm.pad2=gm.pad3=0;
            gpu_mats.push_back(gm); return (int)gpu_mats.size()-1;
        };

        Material floor_mat(CHECKERBOARD, {0.8,0.8,0.8}, {0,0,0}, 0.8, 0.0, 1.0, {0.2,0.2,0.2});
        Material chrome_mat(METAL, {0.9,0.9,0.95}, {0,0,0}, 0.05, 1.0);
        Material glass_mat(GLASS, {0.98,0.99,1.0}, {0,0,0}, 0.0, 0.0, 1.5);
        Material red_mat(DIFFUSE, {0.8,0.15,0.1}, {0,0,0}, 0.9, 0.0);
        Material blue_emit(EMISSIVE, {0,0,0}, {0.3,0.5,2.0}, 1.0, 0.0);
        Material water_mat(WATER, {0.0, 0.3, 0.4}, {0,0,0}, 0.0, 0.0, 1.33, {0,0,0});

        int i_floor = add_mat(floor_mat); int i_chrome = add_mat(chrome_mat);
        int i_glass = add_mat(glass_mat); int i_red = add_mat(red_mat); 
        int i_blue = add_mat(blue_emit); int i_water = add_mat(water_mat);

        std::vector<GPUPlane> gpu_planes;
        if (version == 1) {
            gpu_planes = {{{0,1,0}, -1.0f, i_floor, 0,0,0}, {{0,1,0}, -0.85f, i_water, 0,0,0}};
        } else {
            gpu_planes = {{{0,1,0}, -1.0f, i_floor, 0,0,0}};
        }

        std::vector<GPUSphere> gpu_spheres = {
            {{-2.0f, 0.0f, -5.0f}, 1.0f, i_chrome, 0,0,0},
            {{ 0.0f, 0.2f, -4.5f}, 1.2f, i_glass, 0,0,0},
            {{ 1.5f, 0.5f, -3.5f}, 0.3f, i_blue, 0,0,0}
        };
        std::vector<GPUCube> gpu_cubes = {{{1.5f, -0.5f, -6.0f}, 0, {0.5f,0.5f,0.5f}, i_red}};
        std::vector<GPULight> gpu_lights = {
            {{-5.0f, 8.0f, -2.0f}, 50.0f, {1.0f, 0.95f, 0.9f}, 2.0f},
            {{ 1.5f, 0.5f, -3.5f}, 15.0f, {0.3f, 0.5f, 1.0f}, 0.2f}
        };

        auto createBuf = [&](const void* data, size_t count, size_t elem_size) {
            size_t bytes = std::max(count * elem_size, elem_size);
            if (data == nullptr || count == 0) return [device newBufferWithLength:bytes options:MTLResourceStorageModeManaged];
            return [device newBufferWithBytes:data length:bytes options:MTLResourceStorageModeManaged];
        };

        buf_mats    = createBuf(gpu_mats.data(), gpu_mats.size(), sizeof(GPUMaterial));
        buf_spheres = createBuf(gpu_spheres.data(), gpu_spheres.size(), sizeof(GPUSphere));
        buf_planes  = createBuf(gpu_planes.data(), gpu_planes.size(), sizeof(GPUPlane));
        buf_cubes   = createBuf(gpu_cubes.data(), gpu_cubes.size(), sizeof(GPUCube));
        buf_lights  = createBuf(gpu_lights.data(), gpu_lights.size(), sizeof(GPULight));
        
        uniforms.num_spheres = gpu_spheres.size();
        uniforms.num_planes = gpu_planes.size();
        uniforms.num_cubes = gpu_cubes.size();
        uniforms.num_octahedrons = 0;
        uniforms.num_lights = gpu_lights.size();
        
        total_rays = render_width * render_height * 4 * 7; // Approx SSAAx4 * Depth
        total_tris = 0; // Analytic!
    }

public:
    bool Init(SDL_Window* win, int width, int height) override {
        window = win;
        render_width = width;
        render_height = height;

        device = MTLCreateSystemDefaultDevice();
        if (!device) return false;

        metalLayer = (__bridge CAMetalLayer*)SDL_Metal_GetLayer(SDL_Metal_CreateView(window));
        metalLayer.device = device;
        metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        metalLayer.framebufferOnly = NO; // Needed for compute shader write

        commandQueue = [device newCommandQueue];
        
        renderPassDescriptor = [MTLRenderPassDescriptor new];

        // Compile shaders
        NSError* error = nil;
        NSString* src02 = [NSString stringWithUTF8String:ReadShader("src/backends/Metal/shader_v02.metal").c_str()];
        id<MTLLibrary> lib02 = [device newLibraryWithSource:src02 options:nil error:&error];
        if (!lib02) { std::cerr << "Shader 0.2 Error: " << [[error localizedDescription] UTF8String] << std::endl; return false; }
        pipelineState02 = [device newComputePipelineStateWithFunction:[lib02 newFunctionWithName:@"raytrace_kernel"] error:&error];

        NSString* src03 = [NSString stringWithUTF8String:ReadShader("src/backends/Metal/shader_v03.metal").c_str()];
        id<MTLLibrary> lib03 = [device newLibraryWithSource:src03 options:nil error:&error];
        if (!lib03) { std::cerr << "Shader 0.3 Error: " << [[error localizedDescription] UTF8String] << std::endl; return false; }
        pipelineState03 = [device newComputePipelineStateWithFunction:[lib03 newFunctionWithName:@"raytrace_kernel"] error:&error];

        buf_uniforms = [device newBufferWithLength:sizeof(GPUUniforms) options:MTLResourceStorageModeManaged];

        ImGui_ImplSDL2_InitForMetal(window);
        ImGui_ImplMetal_Init(device);
        cam_pos = Vec3(0, 1.0, 2.0);

        return true;
    }

    void ProcessInput(const Uint8* keys, int mx, int my, float dt) override {
        cam_yaw -= mx * 0.003; 
        cam_pitch -= my * 0.003;
        cam_pitch = std::clamp(cam_pitch, -1.5, 1.5);
        
        Vec3 fwd(cos(cam_yaw)*cos(cam_pitch), sin(cam_pitch), sin(cam_yaw)*cos(cam_pitch));
        Vec3 right = Vec3(0,1,0).cross(fwd).normalize(); 
        Vec3 flat_fwd = Vec3(0,1,0).cross(right).normalize(); // Fixed WASD by negating cross result or using it correctly
        
        // Corrected WASD
        float speed = 3.0 * dt;
        if (keys[SDL_SCANCODE_W]) cam_pos = cam_pos - flat_fwd * speed; // Was inverted (+), now correctly minus flat_fwd (assuming -Z is forward)
        if (keys[SDL_SCANCODE_S]) cam_pos = cam_pos + flat_fwd * speed;
        if (keys[SDL_SCANCODE_A]) cam_pos = cam_pos - right * speed; // Left is -X
        if (keys[SDL_SCANCODE_D]) cam_pos = cam_pos + right * speed; // Right is +X
    }

    void ToggleFog() override { fog_enabled = !fog_enabled; }
    
    void SwitchDemo(int version) override {
        current_version = version;
        SetupScene(version);
    }

    void BeginImGuiFrame() override {
        @autoreleasepool {
            currentDrawable = [metalLayer nextDrawable];
            if (!currentDrawable) return;

            renderPassDescriptor.colorAttachments[0].texture = currentDrawable.texture;
            renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionLoad;
            renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;

            ImGui_ImplMetal_NewFrame(renderPassDescriptor);
        }
    }

    void Render(float dt) override {
        @autoreleasepool {
            if (!currentDrawable) return;
            id<CAMetalDrawable> drawable = currentDrawable;


            // Update Uniforms
            Vec3 fwd(cos(cam_yaw)*cos(cam_pitch), sin(cam_pitch), sin(cam_yaw)*cos(cam_pitch));
            Vec3 right = Vec3(0,1,0).cross(fwd).normalize(); 
            Vec3 up = fwd.cross(right).normalize();

            uniforms.max_depth = 7;
            uniforms.tan_half_fov = std::tan((60.0*PI/180.0) / 2.0);
            uniforms.aspect_ratio = (float)render_width / render_height;
            uniforms.screen_width = render_width; 
            uniforms.screen_height = render_height;
            set_vec3(uniforms.ambient_light, {0.3, 0.4, 0.6}); 
            
            uniforms.camera_origin[0] = cam_pos.x; uniforms.camera_origin[1] = cam_pos.y; uniforms.camera_origin[2] = cam_pos.z;
            uniforms.camera_forward[0] = fwd.x; uniforms.camera_forward[1] = fwd.y; uniforms.camera_forward[2] = fwd.z;
            uniforms.camera_right[0] = right.x; uniforms.camera_right[1] = right.y; uniforms.camera_right[2] = right.z;
            uniforms.camera_up[0] = up.x; uniforms.camera_up[1] = up.y; uniforms.camera_up[2] = up.z;
            uniforms.time = (float)(SDL_GetTicks() % 10000000) / 1000.0f;
            uniforms.enable_fog = fog_enabled ? 1 : 0;

            memcpy([buf_uniforms contents], &uniforms, sizeof(GPUUniforms));
            [buf_uniforms didModifyRange:NSMakeRange(0, buf_uniforms.length)];

            id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
            
            // Compute Pass
            id<MTLComputeCommandEncoder> computeEncoder = [commandBuffer computeCommandEncoder];
            [computeEncoder setComputePipelineState:(current_version == 0 ? pipelineState02 : pipelineState03)];
            [computeEncoder setTexture:drawable.texture atIndex:0];
            [computeEncoder setBuffer:buf_mats offset:0 atIndex:0]; 
            [computeEncoder setBuffer:buf_spheres offset:0 atIndex:1];
            [computeEncoder setBuffer:buf_planes offset:0 atIndex:2]; 
            [computeEncoder setBuffer:buf_cubes offset:0 atIndex:3];
            [computeEncoder setBuffer:buf_lights offset:0 atIndex:5];
            [computeEncoder setBuffer:buf_uniforms offset:0 atIndex:6];
            [computeEncoder dispatchThreads:MTLSizeMake(render_width, render_height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
            [computeEncoder endEncoding];

            // Render Pass (ImGui)
            renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
            renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionLoad;
            renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
            
            id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
            ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), commandBuffer, renderEncoder);
            [renderEncoder endEncoding];

            [commandBuffer presentDrawable:drawable];
            [commandBuffer commit];
            currentDrawable = nil;
        }
    }

    void GetStats(float& outFrameTimeMs, int& outRayCount, int& outTriCount, float& outGpuTimeMs) override {
        outRayCount = total_rays;
        outTriCount = total_tris;
        outGpuTimeMs = 0.0f; // Approx or unmeasured for now
    }

    void Cleanup() override {
        ImGui_ImplMetal_Shutdown();
        ImGui_ImplSDL2_Shutdown();
    }
};

IRenderer* CreateRendererMetal() {
    return new RendererMetal();
}
