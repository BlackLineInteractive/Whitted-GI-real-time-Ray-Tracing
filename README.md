# Whitted Global Illuminated Real-Time Ray Tracer

A unified compute-shader ray tracer based on Turner Whitted's 1980 recursive ray tracing algorithm.
Renders analytical primitives (spheres, planes, cubes) and 3D mesh models in real time using 
per-frame GPU compute passes — no rasterization, no path tracing noise.

Supports **Metal** (macOS), **OpenGL 4.3** (cross-platform), and **Vulkan** (stub, requires SDK).

---

## Screenshots

| Demo 0.2 | Demo 0.3 (water + fog) |
|:---:|:---:|
| ![demo02](screenshot/2.png) | ![demo03](screenshot/3.5.png) |

---

## Features

| Feature | Status |
|---|---|
| Whitted recursive ray tracing | ✅ |
| Analytical soft shadows (cone-sphere) | ✅ |
| Analytical ambient occlusion | ✅ |
| Analytical global illumination (form factors) | ✅ |
| Procedural water + Fresnel | ✅ |
| Atmospheric fog (height-based) | ✅ |
| 4× SSAA anti-aliasing | ✅ |
| Sub-pixel jitter (temporal noise) | ✅ |
| Checkerboard rendering (alternate pixels per frame) | ✅ |
| GLB / glTF 2.0 mesh loading (PBR materials) | ✅ |
| OBJ mesh loading | ✅ |
| BVH acceleration for meshes (CPU-built, GPU-traversed) | ✅ |
| Möller–Trumbore triangle intersection | ✅ |
| Analytic rigid-body physics (gravity, bounce, collision) | ✅ |
| Real-time config (resolution, features, model path) | ✅ |
| Fullscreen toggle (F11 / button) | ✅ |
| ImGui HUD with file browser | ✅ |
| Metal backend | ✅ |
| OpenGL 4.3 backend | ✅ |
| Vulkan backend | 🚧 stub |

---

## Algorithm — How It Works

The renderer is based on **Turner Whitted's 1980** paper *"An Improved Illumination Model for Shaded Display"*.

### Ray tracing loop (per pixel, per frame)

1. **Primary ray** is cast from the camera through the pixel.
2. On hit, three sub-rays may be spawned recursively (stack-based, no actual recursion):
   - **Shadow rays** — one per light source, checking if the hit point is lit.
   - **Reflection ray** — for metallic or glossy surfaces.
   - **Refraction ray** — for glass/water using Snell's law + Schlick Fresnel.
3. **Soft shadows** are computed analytically via a cone-sphere overlap test (no shadow sampling noise).
4. **Ambient occlusion** is computed analytically via form-factor integration over nearby spheres.
5. **Global illumination** approximates inter-object bounce using distance-weighted albedo transfer.
6. **Tone mapping** — Reinhard operator + gamma 2.2 correction applied in-shader.

### Mesh support

When a 3D model is loaded (GLB / OBJ):
- **Assimp** decodes geometry and PBR materials (base color, metallic, roughness).
- The mesh is auto-scaled to fit within 2 world units and centred at origin.
- A flat **BVH** (bounding volume hierarchy) is built on the CPU using midpoint splits.
- BVH nodes and triangles are uploaded to GPU as structured buffers.
- The shader traverses the BVH iteratively using a thread-local stack (no recursion).
- Each leaf tests triangles via **Möller–Trumbore** intersection.

---

## Dependencies

All dependencies download automatically at CMake configure time — **nothing to install manually** except the base system libs.

| Library | Source | Purpose |
|---|---|---|
| SDL2 | System (Homebrew: `brew install sdl2`) | Window, input, Metal/OpenGL context |
| Assimp 6.x | System (Homebrew: `brew install assimp`) | GLB/glTF/OBJ loading |
| Bullet 3.25 | System (Homebrew: `brew install bullet`) | Physics math (linked but sim is custom) |
| Dear ImGui | Auto-fetched (GitHub) | HUD, file dialog |
| ImGuiFileDialog | Auto-fetched (GitHub) | In-app file browser |
| stb_image, stb_image_write | Auto-downloaded (single headers) | Image utilities |
| svenstaro/bvh | Auto-fetched (GitHub) | Header-only BVH reference |

**Author credits:**
- **Turner Whitted** — original ray tracing algorithm (1980)
- **Omar Cornut** — [Dear ImGui](https://github.com/ocornut/imgui)
- **Sean Barrett** — [stb](https://github.com/nothings/stb)
- **Sven-Hendrik Haase (svenstaro)** — [bvh](https://github.com/svenstaro/bvh)
- **aiekick** — [ImGuiFileDialog](https://github.com/aiekick/ImGuiFileDialog)
- **The Assimp Authors** — [Open Asset Import Library](https://github.com/assimp/assimp)

---

## Build

### Requirements

- macOS 13+ (Metal), or Linux/Windows with OpenGL 4.3
- CMake 3.15+
- Xcode Command Line Tools (macOS)
- Homebrew packages: `brew install sdl2 assimp bullet`

### Metal (macOS — recommended)

```bash
cmake -B build_metal -DUSE_METAL=ON -DUSE_VULKAN=OFF -DUSE_OPENGL=OFF
cmake --build build_metal -j$(nproc)
./build_metal/Whitted_GI_RayTracer
```

### OpenGL (macOS / Linux)

```bash
cmake -B build_gl -DUSE_METAL=OFF -DUSE_VULKAN=OFF -DUSE_OPENGL=ON
cmake --build build_gl -j$(nproc)
./build_gl/Whitted_GI_RayTracer
```

### Vulkan (requires Vulkan SDK)

```bash
# Install Vulkan SDK: https://vulkan.lunarg.com/
cmake -B build_vk -DUSE_METAL=OFF -DUSE_VULKAN=ON -DUSE_OPENGL=OFF
cmake --build build_vk -j$(nproc)
```

---

## Configuration (`config.txt`)

A `config.txt` file is created automatically next to the executable on first launch.
You can edit it manually or change everything in the ImGui panel at runtime.

```ini
width=1280
height=720
fullscreen=0
enable_physics=1
enable_jitter=0
enable_checkerboard=0
show_primitives=1
model_path=
model_x=0
model_y=0
model_z=-3
```

| Key | Description |
|---|---|
| `width` / `height` | Initial render resolution |
| `fullscreen` | `1` = launch in fullscreen |
| `enable_physics` | `1` = objects fall under gravity |
| `enable_jitter` | `1` = sub-pixel jitter (smooths aliasing over time) |
| `enable_checkerboard` | `1` = render every other pixel per frame (cost ÷2) |
| `model_path` | Absolute path to GLB/GLTF/OBJ (leave empty for primitive scene) |
| `model_x/y/z` | World position of the loaded model |

---

## Controls

| Key | Action |
|---|---|
| `W A S D` | Move camera |
| `Q` / `E` | Move camera down / up |
| `Mouse` | Look around |
| `M` | Toggle mouse capture |
| `V` | Toggle volumetric fog |
| `F11` | Toggle fullscreen |
| `Esc` | Quit |

---

## Loading 3D Models (GLB / OBJ)

1. Click **"..."** in the ImGui panel to open the file browser.
2. Navigate to your `.glb`, `.gltf`, or `.obj` file and select it.
3. Set the **X / Y / Z** position.
4. Click **"Load Model"**.

The model is automatically scaled to fit within 2 units and centred.
All primitives (spheres, cubes) are hidden while a mesh is loaded.
Click **"Remove Model"** to restore the primitive scene.

> **Tip:** The floor plane always remains visible regardless of whether a mesh or primitives are active.

---

## Render Modes

### Jitter
Randomises the sub-pixel sample offset each frame using a hash function seeded by `time`.
Smooths aliasing edges without reducing performance, but introduces slight temporal shimmer.

### Checkerboard
Renders only half the pixels per frame (alternating checkerboard pattern).
Cuts GPU work roughly in half at the cost of slight image ghosting during fast camera movement.
Both modes can be combined.

---

## Test Hardware

Performance figures measured on:

| Component | Spec |
|---|---|
| Machine | MacBook Pro 16,1 (2019) |
| CPU | Intel Core i7-9750H (6-core, 2.6 GHz) |
| GPU | AMD Radeon Pro 5300M (4 GB GDDR6) |
| RAM | 16 GB DDR4 |
| OS | macOS 26.5.1 (Sequoia) |
| API | Metal (compute shaders) |

**Typical performance (1280×720, Demo 0.3, depth 7):** ~60 FPS on the above hardware.
Checkerboard mode pushes this to ~110 FPS with acceptable quality.

---

## Project Structure

```
RayTracer_Unified/
├── CMakeLists.txt
├── README.md
├── config.txt              (auto-generated)
├── includes/
│   ├── Scene.h             (GPU structs, Vec3, materials)
│   ├── Renderer.h          (IRenderer interface)
│   ├── ModelLoader.h       (Assimp loader API)
│   └── Physics.h           (PhysicsWorld API)
├── src/
│   ├── main.cpp            (SDL loop, ImGui, config)
│   ├── ModelLoader.cpp     (Assimp + BVH builder)
│   ├── Physics.cpp         (Analytic rigid body sim)
│   └── backends/
│       ├── Metal/
│       │   ├── RendererMetal.mm
│       │   ├── shader_v02.metal
│       │   └── shader_v03.metal
│       ├── OpenGL/
│       │   ├── RendererGL.cpp
│       │   ├── shader_v02.comp
│       │   └── shader_v03.comp
│       └── Vulkan/
│           ├── RendererVK.cpp
│           ├── shader_v02.comp
│           └── shader_v03.comp
└── screenshot/
```
