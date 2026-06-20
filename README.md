# Whitted Global Illuminated Real-Time Ray Tracer

This project is a unified framework combining multiple graphics API backends (Metal, OpenGL, Vulkan) into a single analytical ray tracer. The project aims to generate beautiful, noise-free scenes with global illumination, reflections, refraction, soft shadows, and procedural texturing entirely inside compute shaders.

## Principle of Operation

Unlike traditional Monte-Carlo path tracers that trace millions of random paths to resolve noise (which requires heavy denoising and TAA), this engine utilizes **Analytical Intersections**.

1. **Ray Tracing Foundation**: The core idea traces back to **Turner Whitted**, who in 1980 pioneered the concept of recursive ray tracing to render perfect reflections, refractions, and shadows. The architecture of this engine builds on the "Whitted-style" ray tracing but extends it heavily.
2. **Analytical Soft Shadows**: Instead of sampling multiple shadow rays, the engine uses mathematically derived cone-sphere and cone-cube intersections to calculate partial occlusion gradients, providing soft penumbras out-of-the-box with zero noise.
3. **Form-Factor Global Illumination**: Bounces from emissive materials and colored objects are computed using analytical solid angle approximations (form-factors) rather than random hemisphere sampling. This gives the visual richness of Path Tracing, but with the deterministic smoothness of rasterization.
4. **Procedural Geometry**: Everything from the water waves to the fog density is generated procedurally on the GPU. The scene does not rely on traditional polygon meshes (`Triangles: 0`), resulting in near-infinite detail.

## Backends Supported

- **Metal**: Fully implemented and tested. Uses the raw original Apple Metal compute shaders.
- **OpenGL**: Fully ported to GLSL Compute (`.comp`). Utilizes SSBOs for scene representation.
- **Vulkan**: Structural skeleton implemented with `SDL_vulkan`. Uses the same GLSL code compiled to SPIR-V.

## Build Instructions (CMake)

The project leverages CMake's `FetchContent` to dynamically download external dependencies during build time. You do not need to manually clone or include them.

```bash
mkdir build
cd build
cmake ..
make
```

### Dependencies Automatically Fetched

This project gracefully integrates several industry-standard open-source libraries:

- **[ImGui](https://github.com/ocornut/imgui)**: Authored by **Omar Cornut**. Used for the beautiful, hardware-accelerated statistics overlay.
- **[stb](https://github.com/nothings/stb)**: Authored by **Sean Barrett**. Used for single-file image and font processing algorithms.
- **[bvh](https://github.com/svenstaro/bvh)**: Authored by **Svenstaro**. Bounding Volume Hierarchy library, available to accelerate complex polygon mesh intersections in future updates.

## Socials

📱 Instagram: [Blackline Interactive](https://www.instagram.com/blacklineinteractive)
✈️ Telegram: [Blackline Interactive](https://t.me/blacklineinteractive)
📺 YouTube: [Blackline Interactive](https://youtube.com/@blacklineinteractive)
🧊 LinkedIn: [Blackline Interactive](http://linkedin.com/in/blacklineinteractive)
🎵 TikTok: [Blackline Interactive](https://www.tiktok.com/@blacklineinteractive)
