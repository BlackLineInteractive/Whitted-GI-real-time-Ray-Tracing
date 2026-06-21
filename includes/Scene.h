#pragma once
#include <cmath>
#include <cstring>
#include <vector>
#include <limits>

const double PI      = acos(-1.0);
const double INF     = std::numeric_limits<double>::infinity();
const double EPSILON = 1e-7;

struct Vec3 {
    double x, y, z;
    Vec3(double x = 0, double y = 0, double z = 0) : x(x), y(y), z(z) {}
    Vec3 operator+(const Vec3& b) const { return {x+b.x, y+b.y, z+b.z}; }
    Vec3 operator-(const Vec3& b) const { return {x-b.x, y-b.y, z-b.z}; }
    Vec3 operator-()              const { return {-x, -y, -z}; }
    Vec3 operator*(double s)      const { return {x*s, y*s, z*s}; }
    Vec3 operator/(double s)      const { return {x/s, y/s, z/s}; }
    double dot(const Vec3& b)     const { return x*b.x + y*b.y + z*b.z; }
    Vec3 cross(const Vec3& b)     const { return {y*b.z-z*b.y, z*b.x-x*b.z, x*b.y-y*b.x}; }
    double length_sq()            const { return x*x + y*y + z*z; }
    double length()               const { return std::sqrt(length_sq()); }
    Vec3   normalize()            const { double l = length(); return (l > EPSILON) ? (*this/l) : Vec3(0,0,0); }
};
inline Vec3 operator*(double s, const Vec3& v) { return v * s; }
inline void set_vec3(float* dst, const Vec3& v) {
    dst[0] = float(v.x); dst[1] = float(v.y); dst[2] = float(v.z);
}

enum MaterialType { DIFFUSE = 0, METAL = 1, GLASS = 2, EMISSIVE = 3, CHECKERBOARD = 4, WATER = 5, PBR = 6 };

struct Material {
    Vec3 albedo, emission, albedo2;
    double roughness, metallic, refractive_index;
    MaterialType type;
    Material(MaterialType t = DIFFUSE, Vec3 alb = {0.8,0.8,0.8}, Vec3 emiss = {0,0,0},
             double rough = 0.5, double metal = 0.0, double ri = 1.5, Vec3 alb2 = {0.1,0.1,0.1})
        : albedo(alb), emission(emiss), roughness(rough), metallic(metal),
          refractive_index(ri), type(t), albedo2(alb2) {}
};

// 16-byte aligned GPU structs
struct GPUMaterial {
    float albedo[3];       float roughness;
    float emission[3];     float metallic;
    float albedo2[3];      float refractive_index;
    int   type;            int pad1, pad2, pad3;
};
struct GPUSphere   { float center[3]; float radius;    int mat_index; int pad1, pad2, pad3; };
struct GPUPlane    { float normal[3]; float d_offset;  int mat_index; int pad1, pad2, pad3; };
struct GPUCube     { float center[3]; float pad1; float half_size[3]; int mat_index; };
struct GPULight    { float position[3]; float intensity; float color[3]; float radius; };

// Triangle for mesh rendering
struct GPUTriangle {
    float v0[3], pad0;
    float v1[3], pad1;
    float v2[3], pad2;
    float n0[3], pad3;   // per-vertex normals
    float n1[3], pad4;
    float n2[3], pad5;
    float uv0[2], uv1[2];
    float uv2[2]; int mat_index; float pad6;
};

// Flat BVH node for GPU traversal
struct GPUBVHNode {
    float aabb_min[3]; int left_or_tri;   // leaf: index into triangle buffer
    float aabb_max[3]; int right_or_count; // leaf: triangle count (negative = leaf)
};

// GI Needle/Surfel
struct GPUNeedle {
    float position[3]; float radius; // Falloff radius
    float normal[3];   int   object_id;
    float radiance[3]; int   pad;    // Accumulated indirect light
};

struct GPUUniforms {
    int   num_spheres, num_planes, num_cubes, num_bvh_nodes;
    int   num_lights,  max_depth,  num_triangles, enable_triangles;
    float tan_half_fov, aspect_ratio, screen_width, screen_height;
    float ambient_light[3]; float pad2;
    float camera_origin[3]; float pad3;
    float camera_forward[3]; float pad4;
    float camera_right[3];   float pad5;
    float camera_up[3];      float pad6;
    float time;
    int   enable_fog;
    int   enable_jitter;
    int   samples_per_pixel;
    int   debug_mode; // 0=None, 1=GBuffer(Roughness), 2=GBuffer(Depth), 3=GBuffer(MatID), 4=Needles, 5=BVH/AABB
    float model_pos[3]; float pad7;
    int   pad_end;
};
