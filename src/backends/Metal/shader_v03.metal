#include <metal_stdlib>
using namespace metal;

struct Material { packed_float3 albedo; float roughness; packed_float3 emission; float metallic; packed_float3 albedo2; float refractive_index; int type; int pad1, pad2, pad3; };
struct Sphere { packed_float3 center; float radius; int mat_index; int pad1, pad2, pad3; };
struct Plane { packed_float3 normal; float d_offset; int mat_index; int pad1, pad2, pad3; };
struct Cube { packed_float3 center; float pad1; packed_float3 half_size; int mat_index; };
struct Light { packed_float3 position; float intensity; packed_float3 color; float radius; };

// Triangle for mesh rendering (Möller–Trumbore)
struct Triangle {
    float3 v0; float pad0;
    float3 v1; float pad1;
    float3 v2; float pad2;
    float3 n0; float pad3;
    float3 n1; float pad4;
    float3 n2; float pad5;
    float2 uv0;
    float2 uv1;
    float2 uv2;
    int mat_index; float pad6;
};

// Flat BVH node
struct BVHNode {
    float3 aabb_min; int left_or_tri;   // negative right_or_count => leaf
    float3 aabb_max; int right_or_count;
};

struct Uniforms {
    int num_spheres, num_planes, num_cubes, num_octahedrons;
    int num_lights,  max_depth,  num_triangles, enable_triangles;
    float tan_half_fov, aspect_ratio, screen_width, screen_height;
    packed_float3 ambient_light; float pad2;
    packed_float3 camera_origin; float pad3;
    packed_float3 camera_forward; float pad4;
    packed_float3 camera_right;   float pad5;
    packed_float3 camera_up;      float pad6;
    float time;
    int enable_fog;
    int enable_jitter;
    int samples_per_pixel;
    int pad_end;
};

constant float EPSILON = 1e-4;
constant float INF = 1e20;
constant int MAX_STACK = 12;
constant int DIFFUSE = 0, METAL = 1, GLASS = 2, EMISSIVE = 3, CHECKERBOARD = 4, WATER = 5, PBR = 6;

struct Ray { float3 origin; float3 direction; };
struct HitInfo { bool hit; float t; float3 point, normal; int mat_index; float2 uv; };

Ray make_ray(float3 o, float3 d) { return {o, normalize(d)}; }

// ---------------------------------------------------------------- Möller–Trumbore triangle intersection
HitInfo intersect_triangle(Ray ray, device const Triangle& tri) {
    HitInfo info; info.hit = false; info.t = INF;
    float3 e1 = tri.v1 - tri.v0;
    float3 e2 = tri.v2 - tri.v0;
    float3 h  = cross(ray.direction, e2);
    float  a  = dot(e1, h);
    if (abs(a) < EPSILON) return info;
    float  f = 1.0 / a;
    float3 s = ray.origin - tri.v0;
    float  u = f * dot(s, h);
    if (u < 0.0 || u > 1.0) return info;
    float3 q = cross(s, e1);
    float  v = f * dot(ray.direction, q);
    if (v < 0.0 || u + v > 1.0) return info;
    float  t = f * dot(e2, q);
    if (t < EPSILON) return info;
    float w = 1.0 - u - v;
    info.hit     = true;
    info.t       = t;
    info.point   = ray.origin + ray.direction * t;
    info.normal  = normalize(w * tri.n0 + u * tri.n1 + v * tri.n2);
    info.uv      = w * tri.uv0 + u * tri.uv1 + v * tri.uv2;
    info.mat_index = tri.mat_index;
    return info;
}

// ---------------------------------------------------------------- BVH traversal (iterative)
bool aabb_hit(float3 aabb_min, float3 aabb_max, Ray ray, float t_max) {
    float3 inv = 1.0 / ray.direction;
    float3 t0  = (aabb_min - ray.origin) * inv;
    float3 t1  = (aabb_max - ray.origin) * inv;
    float3 mn  = min(t0, t1);
    float3 mx  = max(t0, t1);
    float tenter = max(max(mn.x, mn.y), mn.z);
    float texit  = min(min(mx.x, mx.y), mx.z);
    return texit >= max(tenter, EPSILON) && tenter < t_max;
}

HitInfo intersect_bvh(Ray ray,
                      device const BVHNode* nodes,
                      device const Triangle* tris,
                      int node_count) {
    HitInfo best; best.hit = false; best.t = INF;
    if (node_count == 0) return best;

    int stack[32];
    int sp = 0;
    stack[sp++] = 0;

    while (sp > 0) {
        int idx = stack[--sp];
        if (idx < 0 || idx >= node_count) continue;
        BVHNode n = nodes[idx];

        if (!aabb_hit(n.aabb_min, n.aabb_max, ray, best.t)) continue;

        if (n.right_or_count <= 0) {
            // Leaf
            int start = n.left_or_tri;
            int cnt   = -n.right_or_count;
            for (int i = 0; i < cnt; i++) {
                HitInfo h = intersect_triangle(ray, tris[start + i]);
                if (h.hit && h.t < best.t) best = h;
            }
        } else {
            if (sp < 30) stack[sp++] = n.left_or_tri;
            if (sp < 30) stack[sp++] = n.right_or_count;
        }
    }
    return best;
}

// ---------------------------------------------------------------- hash / noise for jitter
float hash21(float2 p) {
    p = fract(p * float2(234.34, 435.345));
    p += dot(p, p + 34.23);
    return fract(p.x * p.y);
}


HitInfo intersect_sphere(Ray ray, device const Sphere& s) {
    HitInfo info; info.hit = false; info.t = INF;
    float3 oc = ray.origin - s.center;
    float a = dot(ray.direction, ray.direction);
    float b = 2.0 * dot(oc, ray.direction);
    float c = dot(oc, oc) - s.radius*s.radius;
    float disc = b*b - 4.0*a*c;
    if (disc >= 0.0) {
        float sd = sqrt(disc);
        float t1 = (-b - sd) / (2.0*a);
        float t2 = (-b + sd) / (2.0*a);
        float t = INF;
        if (t1 > EPSILON) t = t1; else if (t2 > EPSILON) t = t2;
        if (t < INF) {
            info.hit = true; info.t = t;
            info.point = ray.origin + ray.direction * t;
            info.normal = normalize(info.point - s.center);
            info.mat_index = s.mat_index;
            float3 pl = (info.point - s.center) / s.radius;
            info.uv = float2((atan2(pl.z, pl.x) + 3.14159) / (2.0 * 3.14159), (asin(clamp(pl.y, -1.0, 1.0)) + 1.5707) / 3.14159);
        }
    }
    return info;
}

HitInfo intersect_plane(Ray ray, device const Plane& p) {
    HitInfo info; info.hit = false; info.t = INF;
    float denom = dot(p.normal, ray.direction);
    if (abs(denom) > EPSILON) {
        float t = (p.d_offset - dot(ray.origin, p.normal)) / denom;
        if (t > EPSILON) {
            info.hit = true; info.t = t;
            info.point = ray.origin + ray.direction * t;
            info.normal = p.normal;
            info.mat_index = p.mat_index;
            float3 u_axis = abs(p.normal.y) > 0.9 ? float3(1,0,0) : normalize(cross(float3(0,1,0), p.normal));
            float3 v_axis = normalize(cross(p.normal, u_axis));
            info.uv = float2(dot(info.point, u_axis)*0.1, dot(info.point, v_axis)*0.1);
        }
    }
    return info;
}

HitInfo intersect_cube(Ray ray, device const Cube& c) {
    HitInfo info; info.hit = false; info.t = INF;
    float3 inv_dir = 1.0 / ray.direction;
    float3 t1 = (c.center - c.half_size - ray.origin) * inv_dir;
    float3 t2 = (c.center + c.half_size - ray.origin) * inv_dir;
    float3 tminv = min(t1, t2); float3 tmaxv = max(t1, t2);
    float t_enter = max(max(tminv.x, tminv.y), tminv.z);
    float t_exit  = min(min(tmaxv.x, tmaxv.y), tmaxv.z);
    if (t_exit < EPSILON || t_enter > t_exit) return info;
    float t = (t_enter > EPSILON) ? t_enter : t_exit;
    if (t > EPSILON) {
        info.hit = true; info.t = t;
        info.point = ray.origin + ray.direction * t;
        info.mat_index = c.mat_index;
        float3 hr = info.point - c.center;
        float3 n = float3(0.0);
        if (abs(abs(hr.x) - c.half_size.x) < EPSILON*10.0) n.x = sign(hr.x);
        else if (abs(abs(hr.y) - c.half_size.y) < EPSILON*10.0) n.y = sign(hr.y);
        else if (abs(abs(hr.z) - c.half_size.z) < EPSILON*10.0) n.z = sign(hr.z);
        info.normal = normalize(n);
        info.uv = float2(hr.x / c.half_size.x, hr.z / c.half_size.z);
    }
    return info;
}

HitInfo find_closest(Ray ray,
                     device const Sphere*   spheres,
                     device const Plane*    planes,
                     device const Cube*     cubes,
                     device const BVHNode*  bvh_nodes,
                     device const Triangle* triangles,
                     constant Uniforms&     u) {
    HitInfo closest; closest.hit = false; closest.t = INF;
    if (u.enable_triangles > 0) {
        HitInfo h = intersect_bvh(ray, bvh_nodes, triangles, u.num_triangles);
        if (h.hit && h.t < closest.t) closest = h;
    } else {
        for (int i = 0; i < u.num_spheres; i++) { HitInfo h = intersect_sphere(ray, spheres[i]); if (h.hit && h.t < closest.t) closest = h; }
        for (int i = 0; i < u.num_planes;  i++) { HitInfo h = intersect_plane(ray, planes[i]);   if (h.hit && h.t < closest.t) closest = h; }
        for (int i = 0; i < u.num_cubes;   i++) { HitInfo h = intersect_cube(ray, cubes[i]);     if (h.hit && h.t < closest.t) closest = h; }
    }
    // Always intersect planes when mesh is active (floor stays)
    if (u.enable_triangles > 0) {
        for (int i = 0; i < u.num_planes; i++) { HitInfo h = intersect_plane(ray, planes[i]); if (h.hit && h.t < closest.t) closest = h; }
    }
    return closest;
}

float cone_sphere_occlusion(float3 cone_o, float3 cone_d, float cone_angle, float3 s_center, float s_radius) {
    float3 L = s_center - cone_o;
    float dist = length(L);
    if (dist < s_radius) return 1.0; 
    L /= dist;
    float obj_angle = asin(s_radius / dist);
    float cos_diff = dot(cone_d, L);
    float angle_diff = acos(clamp(cos_diff, -1.0f, 1.0f));
    if (angle_diff > cone_angle + obj_angle) return 0.0;
    if (angle_diff + cone_angle <= obj_angle) return 1.0;
    float overlap = (cone_angle + obj_angle - angle_diff) / (2.0 * cone_angle);
    return smoothstep(0.0, 1.0, clamp(overlap, 0.0, 1.0));
}

bool point_in_cube(float3 p, device const Cube& c) {
    float3 d = abs(p - c.center);
    return d.x <= c.half_size.x && d.y <= c.half_size.y && d.z <= c.half_size.z;
}

float calc_analytic_shadow(float3 p, float3 n, float3 lpos, float lrad, device const Sphere* spheres, device const Plane* planes, device const Cube* cubes, constant Uniforms& u) {
    float3 L = lpos - p;
    float actual_dist = length(L);
    L /= actual_dist;
    float light_angle = atan(lrad / actual_dist);
    float occlusion = 0.0;
    float3 ro = p + n * 0.05;

    for(int i = 0; i < u.num_spheres; i++) {
        if (distance(spheres[i].center, lpos) < 1e-2) continue;
        occlusion += cone_sphere_occlusion(ro, L, light_angle, spheres[i].center, spheres[i].radius);
    }
    for(int i = 0; i < u.num_cubes; i++) {
        if (point_in_cube(ro, cubes[i])) continue;
        Ray shadow_ray = make_ray(ro, L);
        HitInfo h = intersect_cube(shadow_ray, cubes[i]);
        if (h.hit && h.t > 0.05 && h.t < actual_dist - 0.05) {
            occlusion = 1.0;
            break;
        }
    }
    return 1.0 - clamp(occlusion, 0.0, 1.0);
}

float calc_analytic_ao(float3 p, float3 n, device const Sphere* spheres, device const Cube* cubes, constant Uniforms& u) {
    float occlusion = 0.0;
    float3 ro = p + n * 0.05;
    float ao_cone_angle = 0.8;
    for(int i = 0; i < u.num_spheres; i++) {
        float3 L = spheres[i].center - ro;
        float dist = length(L);
        if(dist > 0.01 && dist < 3.0) {
            float occ = cone_sphere_occlusion(ro, n, ao_cone_angle, spheres[i].center, spheres[i].radius);
            occlusion += occ * (1.0 - dist / 3.0);
        }
    }
    for(int i = 0; i < u.num_cubes; i++) {
        float3 L = cubes[i].center - ro;
        float dist = length(L);
        if(dist > 0.01 && dist < 3.0) {
            float occ = cone_sphere_occlusion(ro, n, ao_cone_angle, cubes[i].center, length(cubes[i].half_size)) * 0.5;
            occlusion += occ * (1.0 - dist / 3.0);
        }
    }
    return 1.0 - clamp(occlusion, 0.0, 1.0);
}

float3 schlick(float cos_theta, float n1, float n2) {
    float r0 = (n1 - n2) / (n1 + n2); r0 *= r0;
    float x = 1.0 - cos_theta;
    return float3(r0 + (1.0 - r0) * pow(x, 5.0));
}

float3 sky_color(float3 dir) {
    float t = 0.5 * (dir.y + 1.0);
    return mix(float3(0.7, 0.8, 0.9), float3(0.1, 0.3, 0.6), t); 
}

float3 calc_gi(float3 p, float3 n, device const Material* materials, device const Sphere* spheres, device const Plane* planes, device const Cube* cubes, constant Uniforms& u) {
    float3 gi = float3(0.0);
    for (int i = 0; i < u.num_planes; i++) {
        if (planes[i].normal.y > 0.9) {
            Material fm = materials[planes[i].mat_index];
            float3 fcol = fm.albedo;
            if (fm.type == CHECKERBOARD) {
                int cs = 4;
                bool white = (int(floor(p.x * 0.1 * float(cs))) + int(floor(p.z * 0.1 * float(cs)))) % 2 == 0;
                fcol = white ? fm.albedo : fm.albedo2;
            }
            gi += fcol * max(0.0, n.y) * 0.5;
        }
    }
    for (int i = 0; i < u.num_spheres; i++) {
        float3 to_obj = spheres[i].center - p;
        float dist = length(to_obj);
        if (dist < 0.1 || dist > 6.0) continue;
        float3 L = to_obj / dist;
        float NdotL = max(0.0, dot(n, L));
        if (NdotL <= 0.0) continue;
        Material om = materials[spheres[i].mat_index];
        if (om.type == EMISSIVE || om.type == GLASS) continue;
        float atten = 1.0 / (dist * dist + 0.1);
        gi += om.albedo * NdotL * atten * 1.5;
    }
    for (int i = 0; i < u.num_cubes; i++) {
        float3 to_obj = cubes[i].center - p;
        float dist = length(to_obj);
        if (dist < 0.1 || dist > 6.0) continue;
        float3 L = to_obj / dist;
        float NdotL = max(0.0, dot(n, L));
        if (NdotL <= 0.0) continue;
        Material om = materials[cubes[i].mat_index];
        if (om.type == EMISSIVE || om.type == GLASS) continue;
        float atten = 1.0 / (dist * dist + 0.1);
        gi += om.albedo * NdotL * atten * 1.5;
    }
    return gi;
}

float3 trace_ray(Ray ray, device const Material* materials, device const Sphere* spheres,
                 device const Plane* planes, device const Cube* cubes, device const Light* lights,
                 device const BVHNode* bvh_nodes, device const Triangle* triangles,
                 constant Uniforms& u, thread float& first_dist) {

    first_dist = 60.0;
    HitInfo first = find_closest(ray, spheres, planes, cubes, bvh_nodes, triangles, u);
    if (first.hit) first_dist = first.t;

    float3 result = float3(0.0);
    Ray stack_ray[MAX_STACK];
    float3 stack_contrib[MAX_STACK];
    int stack_depth[MAX_STACK];
    int sp = 0;

    stack_ray[0] = ray;
    stack_contrib[0] = float3(1.0);
    stack_depth[0] = u.max_depth;
    sp = 1;

    while (sp > 0) {
        sp--;
        Ray cur = stack_ray[sp];
        float3 contrib = stack_contrib[sp];
        int depth = stack_depth[sp];
        if (depth <= 0) continue;

        HitInfo hit = find_closest(cur, spheres, planes, cubes, bvh_nodes, triangles, u);

        if (!hit.hit) {
            result += contrib * sky_color(cur.direction);
            continue;
        }

        Material mat = materials[hit.mat_index];
        result += contrib * mat.emission;
        if (mat.type == EMISSIVE) continue;

        float3 N = hit.normal;
        float3 V = normalize(cur.origin - hit.point);
        float3 alb = mat.albedo;

        if (mat.type == CHECKERBOARD) {
            int cs = 4;
            bool white = (int(floor(hit.uv.x * float(cs))) + int(floor(hit.uv.y * float(cs)))) % 2 == 0;
            alb = white ? mat.albedo : mat.albedo2;
        }

        if (mat.type == WATER) {
            float3 wp = hit.point;
            float tm = u.time;

            float w1 = sin(wp.x * 8.0 + tm * 2.0) * 0.012;
            float w2 = cos(wp.z * 7.0 + tm * 2.5) * 0.012;
            float w3 = sin((wp.x * 0.7 + wp.z * 0.9) * 14.0 + tm * 3.5) * 0.006;
            float w4 = cos(wp.x * 3.0 - wp.z * 4.0 + tm * 1.8) * 0.008;
            float wave_h = w1 + w2 + w3 + w4;

            float dx = 8.0 * cos(wp.x * 8.0 + tm * 2.0) * 0.012
                     + 14.0 * 0.7 * cos((wp.x * 0.7 + wp.z * 0.9) * 14.0 + tm * 3.5) * 0.006
                     + 3.0 * -sin(wp.x * 3.0 - wp.z * 4.0 + tm * 1.8) * 0.008;
            float dz = 7.0 * -sin(wp.z * 7.0 + tm * 2.5) * 0.012
                     + 14.0 * 0.9 * cos((wp.x * 0.7 + wp.z * 0.9) * 14.0 + tm * 3.5) * 0.006
                     + 4.0 * sin(wp.x * 3.0 - wp.z * 4.0 + tm * 1.8) * 0.008;

            float3 water_n = normalize(float3(-dx, 1.0, -dz));

            float cos_theta = max(0.0, dot(water_n, V));
            float R0 = 0.02;
            float fresnel = R0 + (1.0 - R0) * pow(1.0 - cos_theta, 5.0);
            fresnel = clamp(fresnel, 0.0, 1.0);

            if (fresnel > EPSILON && sp < MAX_STACK) {
                float3 R = reflect(cur.direction, water_n);
                stack_ray[sp] = make_ray(hit.point + water_n * 0.02, R);
                stack_contrib[sp] = contrib * fresnel;
                stack_depth[sp] = depth - 1;
                sp++;
            }

            if ((1.0 - fresnel) > EPSILON && sp < MAX_STACK) {
                float n1 = 1.0, n2 = 1.33;
                float3 Nf = water_n; 
                float cos_i = -dot(cur.direction, Nf);
                if (cos_i < 0.0) { float tmp = n1; n1 = n2; n2 = tmp; Nf = -Nf; cos_i = -dot(cur.direction, Nf); }
                float eta = n1 / n2;
                float k = 1.0 - eta * eta * (1.0 - cos_i * cos_i);
                if (k >= 0.0) {
                    float3 T = eta * cur.direction + (eta * cos_i - sqrt(k)) * Nf;
                    float view_depth = 1.0 / max(dot(Nf, -T), 0.15);
                    float3 water_absorb = float3(0.25, 0.18, 0.08); 
                    float3 absorption = exp(-water_absorb * view_depth * 1.2);

                    stack_ray[sp] = make_ray(hit.point - Nf * 0.05, T);
                    stack_contrib[sp] = contrib * (1.0 - fresnel) * absorption;
                    stack_depth[sp] = depth - 1;
                    sp++;
                }
            }

            float3 spec = float3(0.0);
            for (int i = 0; i < u.num_lights; i++) {
                float3 to_light = lights[i].position - hit.point;
                float dist = length(to_light);
                float3 L = to_light / dist;
                float3 H = normalize(L + V);
                float NdotH = max(0.0, dot(water_n, H));
                float sh = calc_analytic_shadow(hit.point, water_n, lights[i].position, lights[i].radius, spheres, planes, cubes, u);
                spec += lights[i].color * pow(NdotH, 800.0) * lights[i].intensity * sh * fresnel / (dist * dist + 0.1);
            }
            result += contrib * spec;

            float foam = smoothstep(0.025, 0.032, wave_h) * 0.08;
            float3 foam_col = float3(0.97, 0.98, 1.0);
            result += contrib * foam_col * foam * (1.0 - fresnel);

            continue;
        }

        if (mat.type != GLASS) {
            float3 direct = float3(0.0);

            for (int i = 0; i < u.num_lights; i++) {
                float3 to_light = lights[i].position - hit.point;
                float dist_sq = dot(to_light, to_light);
                float dist = sqrt(dist_sq);
                float3 L = to_light / dist;
                float NdotL = max(0.0, dot(N, L));

                if (NdotL > 0.0) {
                    float sh = calc_analytic_shadow(hit.point, N, lights[i].position, lights[i].radius, spheres, planes, cubes, u);
                    if (sh > 0.0) {
                        float atten = lights[i].intensity / max(dist_sq, 0.01f);
                        float3 H = normalize(L + V);
                        float NdotH = max(0.0, dot(N, H));
                        float shininess = pow(2.0, (1.0 - mat.roughness) * 10.0);

                        if (mat.type == METAL) {
                            float3 spec = alb * lights[i].color * pow(NdotH, shininess) * atten;
                            direct += spec * sh;
                        } else {
                            float3 diff = alb * lights[i].color * NdotL * atten;
                            float3 spec = float3(1.0) * lights[i].color * pow(NdotH, shininess) * atten * 0.25 * (1.0 - mat.roughness);
                            direct += (diff + spec) * sh;
                        }
                    }
                }
            }

            float ao = calc_analytic_ao(hit.point, N, spheres, cubes, u);
            float3 sky_ambient = sky_color(N) * u.ambient_light * 0.5;
            float3 gi = calc_gi(hit.point, N, materials, spheres, planes, cubes, u);

            float3 indirect = (sky_ambient + gi) * ao;
            direct += indirect * alb;
            result += contrib * direct;
        }

        if (mat.type == METAL && sp < MAX_STACK) {
            float3 R = reflect(cur.direction, N);
            float refl = 1.0 - mat.roughness * 0.3;
            if (refl > EPSILON) {
                stack_ray[sp] = make_ray(hit.point + N * 3e-3, R);
                stack_contrib[sp] = contrib * alb * refl;
                stack_depth[sp] = depth - 1;
                sp++;
            }
        }
        else if (mat.type == GLASS && sp < MAX_STACK) {
            float n1 = 1.0, n2 = mat.refractive_index;
            float3 Nf = N; float cos_i = -dot(cur.direction, Nf);
            if (cos_i < 0.0) { float tmp = n1; n1 = n2; n2 = tmp; Nf = -Nf; cos_i = -dot(cur.direction, Nf); }
            float3 F = schlick(cos_i, n1, n2);
            float fresnel_r = F.x;

            if (fresnel_r > EPSILON && sp < MAX_STACK) {
                stack_ray[sp] = make_ray(hit.point + N * 3e-3, reflect(cur.direction, N));
                stack_contrib[sp] = contrib * fresnel_r;
                stack_depth[sp] = depth - 1;
                sp++;
            }
            if ((1.0 - fresnel_r) > EPSILON && sp < MAX_STACK) {
                float eta = n1 / n2;
                float k = 1.0 - eta * eta * (1.0 - cos_i * cos_i);
                if (k >= 0.0) {
                    float3 T = eta * cur.direction + (eta * cos_i - sqrt(k)) * Nf;
                    stack_ray[sp] = make_ray(hit.point - Nf * 5e-3, T);
                    stack_contrib[sp] = contrib * (1.0 - fresnel_r);
                    stack_depth[sp] = depth - 1;
                    sp++;
                }
            }
        }
    }

    return clamp(result, float3(0.0), float3(100.0));
}

kernel void raytrace_kernel(texture2d<float, access::write> outTexture [[texture(0)]],
                            device const Material* materials [[buffer(0)]],
                            device const Sphere*   spheres   [[buffer(1)]],
                            device const Plane*    planes    [[buffer(2)]],
                            device const Cube*     cubes     [[buffer(3)]],
                            device const Light*    lights    [[buffer(5)]],
                            constant Uniforms&     u         [[buffer(6)]],
                            device const Triangle* triangles [[buffer(7)]],
                            device const BVHNode*  bvh_nodes [[buffer(8)]],
                            uint2 gid [[thread_position_in_grid]]) {

    if (gid.x >= uint(u.screen_width) || gid.y >= uint(u.screen_height)) return;

    float2 px     = float2(gid);
    float  py_inv = u.screen_height - px.y;

    // Sub-pixel jitter offset
    float2 jitter = float2(0.5, 0.5);
    if (u.enable_jitter > 0) {
        float jx = hash21(float2(gid) + float2(u.time * 37.1, 13.7));
        float jy = hash21(float2(gid) + float2(u.time * 19.3, 71.3));
        jitter = float2(jx, jy);
    }

    float3 color      = float3(0.0);
    float3 center_dir = float3(0.0);
    float  center_fd  = 60.0;
    int    SAMPLES    = u.samples_per_pixel;
    if (SAMPLES < 1) SAMPLES = 1;
    if (SAMPLES > 4) SAMPLES = 4;

    for (int dy = 0; dy < SAMPLES; dy++) {
        for (int dx = 0; dx < SAMPLES; dx++) {
            float2 offset = float2(float(dx) + jitter.x, float(dy) + jitter.y) / float(SAMPLES);
            float  nx = (2.0 * (px.x + offset.x) / u.screen_width  - 1.0) * u.aspect_ratio * u.tan_half_fov;
            float  ny = (2.0 * (py_inv + offset.y) / u.screen_height - 1.0) * u.tan_half_fov;

            float3 dir = normalize(u.camera_forward + nx * u.camera_right + ny * u.camera_up);
            Ray r = make_ray(u.camera_origin, dir);

            float fd = 60.0;
            color += trace_ray(r, materials, spheres, planes, cubes, lights, bvh_nodes, triangles, u, fd);
            if (dx == 0 && dy == 0) { center_dir = dir; center_fd = fd; }
        }
    }
    color /= float(SAMPLES * SAMPLES);

    if (u.enable_fog > 0) {
        float3 fog_col = float3(0.55, 0.62, 0.72);
        float3 mid     = u.camera_origin + center_dir * center_fd * 0.5;
        float  h       = mid.y + 1.0;
        float  density = 0.06 * exp(-h * 2.0) + 0.015;
        float  fog_f   = 1.0 - exp(-center_fd * density);
        float  horizon = smoothstep(25.0, 65.0, center_fd) * 0.5;
        fog_f = clamp(fog_f + horizon, 0.0, 0.92f);
        color = mix(color, fog_col, fog_f);
    }

    float3 mapped = color / (color + float3(1.0));
    mapped = pow(clamp(mapped, float3(0.0), float3(1.0)), float3(1.0/2.2));
    outTexture.write(float4(mapped, 1.0), gid);
}
