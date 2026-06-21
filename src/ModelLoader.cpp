#include "ModelLoader.h"
#include <assimp/Importer.hpp>
#include <assimp/scene.h>
#include <assimp/postprocess.h>
#include <iostream>
#include <algorithm>
#include <algorithm>
#include <cassert>
#include <filesystem>

#define STB_IMAGE_IMPLEMENTATION
#include <stb/stb_image.h>

// ------------------------------------------------------------------ helpers --

static void ResizeBilinear(const uint8_t* src, int sw, int sh, uint8_t* dst, int dw, int dh) {
    for (int y = 0; y < dh; y++) {
        float v = (dh > 1) ? ((float)y / (dh - 1)) : 0.0f;
        int sy = std::clamp((int)(v * (sh - 1)), 0, std::max(0, sh - 2));
        float fy = v * (sh - 1) - sy;
        for (int x = 0; x < dw; x++) {
            float u = (dw > 1) ? ((float)x / (dw - 1)) : 0.0f;
            int sx = std::clamp((int)(u * (sw - 1)), 0, std::max(0, sw - 2));
            float fx = u * (sw - 1) - sx;

            for (int c = 0; c < 4; c++) {
                float c00 = src[(sy * sw + sx) * 4 + c];
                float c10 = (sx + 1 < sw) ? src[(sy * sw + sx + 1) * 4 + c] : c00;
                float c01 = (sy + 1 < sh) ? src[((sy + 1) * sw + sx) * 4 + c] : c00;
                float c11 = (sx + 1 < sw && sy + 1 < sh) ? src[((sy + 1) * sw + sx + 1) * 4 + c] : c00;

                float c0 = c00 * (1.0f - fx) + c10 * fx;
                float c1 = c01 * (1.0f - fx) + c11 * fx;
                dst[(y * dw + x) * 4 + c] = (uint8_t)(c0 * (1.0f - fy) + c1 * fy);
            }
        }
    }
}

static GPUMaterial ConvertMaterial(const aiMaterial* ai_mat) {
    GPUMaterial m{};
    aiColor4D   col;
    float       fval;

    // Base color / albedo
    if (AI_SUCCESS == ai_mat->Get(AI_MATKEY_BASE_COLOR, col)) {
        m.albedo[0] = col.r; m.albedo[1] = col.g; m.albedo[2] = col.b;
    } else if (AI_SUCCESS == ai_mat->Get(AI_MATKEY_COLOR_DIFFUSE, col)) {
        m.albedo[0] = col.r; m.albedo[1] = col.g; m.albedo[2] = col.b;
    } else {
        // Fallback
        m.albedo[0] = 0.8f; m.albedo[1] = 0.8f; m.albedo[2] = 0.8f;
    }

    // If it's pure white/gray/black (often means texture is missing), make it colorful!
    if (abs(m.albedo[0] - m.albedo[1]) < 0.05f && abs(m.albedo[1] - m.albedo[2]) < 0.05f) {
        float h = fmod((float)(reinterpret_cast<uintptr_t>(ai_mat) * 137), 360.0f) / 360.0f;
        float r=0, g=0, b=0;
        int i = int(h * 6);
        float f = h * 6 - i;
        float q = 1 - f;
        switch(i % 6) {
            case 0: r = 1, g = f, b = 0; break;
            case 1: r = q, g = 1, b = 0; break;
            case 2: r = 0, g = 1, b = f; break;
            case 3: r = 0, g = q, b = 1; break;
            case 4: r = f, g = 0, b = 1; break;
            case 5: r = 1, g = 0, b = q; break;
        }
        m.albedo[0] = r * 0.8f + 0.2f;
        m.albedo[1] = g * 0.8f + 0.2f;
        m.albedo[2] = b * 0.8f + 0.2f;
    }

    // Emissive
    if (AI_SUCCESS == ai_mat->Get(AI_MATKEY_COLOR_EMISSIVE, col) &&
        (col.r + col.g + col.b) > 0.01f) {
        m.emission[0] = col.r; m.emission[1] = col.g; m.emission[2] = col.b;
        m.type = 3; // EMISSIVE
    }

    // Metallic / roughness (glTF PBR)
    m.metallic  = 0.0f;
    m.roughness = 0.5f;
    if (AI_SUCCESS == ai_mat->Get(AI_MATKEY_METALLIC_FACTOR,  fval)) m.metallic  = fval;
    if (AI_SUCCESS == ai_mat->Get(AI_MATKEY_ROUGHNESS_FACTOR, fval)) m.roughness = fval;

    // Choose type
    if (m.metallic > 0.5f && m.type != 3)  m.type = 1; // METAL
    else if (m.type != 3)                   m.type = 6; // PBR diffuse

    m.refractive_index = 1.5f;
    m.albedo2[0] = m.albedo2[1] = m.albedo2[2] = 0.1f;
    return m;
}

#include <bvh/v2/bvh.h>
#include <bvh/v2/vec.h>
#include <bvh/v2/tri.h>
#include <bvh/v2/default_builder.h>

static void BuildBVH(std::vector<GPUTriangle>& tris,
                     std::vector<GPUBVHNode>&  nodes,
                     int start, int count, int depth = 0) {
    using Scalar = float;
    using Vec3 = bvh::v2::Vec<Scalar, 3>;
    using Bbox = bvh::v2::BBox<Scalar, 3>;
    using Tri = bvh::v2::Tri<Scalar, 3>;

    std::vector<Tri> bvh_tris;
    std::vector<Bbox> bboxes;
    std::vector<Vec3> centers;
    bvh_tris.reserve(count);
    bboxes.reserve(count);
    centers.reserve(count);

    for (int i = start; i < start + count; i++) {
        const auto& t = tris[i];
        Vec3 v0(t.v0[0], t.v0[1], t.v0[2]);
        Vec3 v1(t.v1[0], t.v1[1], t.v1[2]);
        Vec3 v2(t.v2[0], t.v2[1], t.v2[2]);
        bvh_tris.emplace_back(v0, v1, v2);
        
        Bbox bbox(v0);
        bbox.extend(v1);
        bbox.extend(v2);
        bboxes.push_back(bbox);
        centers.push_back(bbox.get_center());
    }

    bvh::v2::Bvh<bvh::v2::Node<Scalar, 3>> bvh = bvh::v2::DefaultBuilder<bvh::v2::Node<Scalar, 3>>::build(bboxes, centers);

    // Convert to GPU format
    std::vector<GPUTriangle> ordered_tris;
    ordered_tris.reserve(count);
    for (size_t i = 0; i < count; i++) {
        ordered_tris.push_back(tris[start + bvh.prim_ids[i]]);
    }
    for (size_t i = 0; i < count; i++) {
        tris[start + i] = ordered_tris[i];
    }

    nodes.resize(bvh.nodes.size());
    for (size_t i = 0; i < bvh.nodes.size(); i++) {
        const auto& n = bvh.nodes[i];
        GPUBVHNode gn;
        gn.aabb_min[0] = n.bounds[0];
        gn.aabb_min[1] = n.bounds[2];
        gn.aabb_min[2] = n.bounds[4];
        gn.aabb_max[0] = n.bounds[1];
        gn.aabb_max[1] = n.bounds[3];
        gn.aabb_max[2] = n.bounds[5];
        
        if (n.is_leaf()) {
            gn.left_or_tri = start + n.index.first_id();
            gn.right_or_count = -((int)n.index.prim_count());
        } else {
            gn.left_or_tri = n.index.first_id();
            gn.right_or_count = n.index.first_id() + 1; // Assuming contiguous children
        }
        nodes[i] = gn;
    }
}

// --------------------------------------------------------------- public API --

MeshData LoadModel(const std::string& path, float target_size) {
    MeshData result;

    Assimp::Importer importer;
    const aiScene* scene = importer.ReadFile(path,
        aiProcess_Triangulate       |
        aiProcess_GenSmoothNormals  |
        aiProcess_CalcTangentSpace  |
        aiProcess_FlipUVs           |
        aiProcess_JoinIdenticalVertices |
        aiProcess_PreTransformVertices);

    if (!scene || !scene->mRootNode) {
        std::cerr << "[ModelLoader] Failed to load: " << path
                  << "\n  " << importer.GetErrorString() << std::endl;
        return result;
    }

    std::string base_dir = std::filesystem::path(path).parent_path().string();
    if (!base_dir.empty()) base_dir += "/";

    int tex_size = 512;
    size_t num_mats = scene->mNumMaterials;
    if (num_mats == 0) num_mats = 1;
    result.texture_array_data.resize(num_mats * tex_size * tex_size * 4, 255); // white default

    // Convert materials and load textures
    for (unsigned int mi = 0; mi < scene->mNumMaterials; mi++) {
        GPUMaterial gm = ConvertMaterial(scene->mMaterials[mi]);
        result.materials.push_back(gm);

        aiString tex_path;
        bool loaded_tex = false;
        if (scene->mMaterials[mi]->GetTexture(aiTextureType_DIFFUSE, 0, &tex_path) == AI_SUCCESS) {
            std::string full_path = base_dir + tex_path.C_Str();
            int tw, th, tc;
            uint8_t* pixels = stbi_load(full_path.c_str(), &tw, &th, &tc, 4);
            if (!pixels) {
                // Try embedded texture? (Assimp uses *0, *1 for embedded)
                if (tex_path.data[0] == '*') {
                    int idx = atoi(&tex_path.data[1]);
                    if (idx < scene->mNumTextures) {
                        aiTexture* tex = scene->mTextures[idx];
                        if (tex->mHeight == 0) { // compressed
                            pixels = stbi_load_from_memory((const stbi_uc*)tex->pcData, tex->mWidth, &tw, &th, &tc, 4);
                        }
                    }
                }
            }
            
            if (pixels) {
                ResizeBilinear(pixels, tw, th, result.texture_array_data.data() + mi * tex_size * tex_size * 4, tex_size, tex_size);
                stbi_image_free(pixels);
                loaded_tex = true;
                std::cout << "[ModelLoader] Loaded texture: " << tex_path.C_Str() << " (" << tw << "x" << th << ")\n";
            } else {
                std::cerr << "[ModelLoader] Warning: Failed to load texture: " << full_path << std::endl;
            }
        }

        if (!loaded_tex) {
            // Fill with albedo color
            uint8_t r = (uint8_t)(gm.albedo[0] * 255.0f);
            uint8_t g = (uint8_t)(gm.albedo[1] * 255.0f);
            uint8_t b = (uint8_t)(gm.albedo[2] * 255.0f);
            uint8_t* dst = result.texture_array_data.data() + mi * tex_size * tex_size * 4;
            for (int i = 0; i < tex_size * tex_size; i++) {
                dst[i*4+0] = r;
                dst[i*4+1] = g;
                dst[i*4+2] = b;
                dst[i*4+3] = 255;
            }
        }
    }

    // Ensure at least one material
    if (result.materials.empty()) {
        GPUMaterial def{}; def.albedo[0]=def.albedo[1]=def.albedo[2]=0.8f;
        def.roughness=0.5f; def.type=6; result.materials.push_back(def);
        
        uint8_t* dst = result.texture_array_data.data();
        for (int i = 0; i < tex_size * tex_size; i++) {
            dst[i*4+0] = dst[i*4+1] = dst[i*4+2] = 204;
            dst[i*4+3] = 255;
        }
    }

    // Traverse all meshes
    std::function<void(aiNode*)> traverse = [&](aiNode* node) {
        for (unsigned int i = 0; i < node->mNumMeshes; i++) {
            const aiMesh* mesh = scene->mMeshes[node->mMeshes[i]];
            int mat_idx = (int)mesh->mMaterialIndex;
            if (mat_idx >= (int)result.materials.size()) mat_idx = 0;

            for (unsigned int f = 0; f < mesh->mNumFaces; f++) {
                const aiFace& face = mesh->mFaces[f];
                if (face.mNumIndices != 3) continue;

                GPUTriangle tri{};
                for (int v = 0; v < 3; v++) {
                    unsigned int idx = face.mIndices[v];
                    float* dst_v = (v == 0) ? tri.v0 : (v == 1) ? tri.v1 : tri.v2;
                    float* dst_n = (v == 0) ? tri.n0 : (v == 1) ? tri.n1 : tri.n2;

                    dst_v[0] = mesh->mVertices[idx].x;
                    dst_v[1] = mesh->mVertices[idx].y;
                    dst_v[2] = mesh->mVertices[idx].z;

                    if (mesh->HasNormals()) {
                        dst_n[0] = mesh->mNormals[idx].x;
                        dst_n[1] = mesh->mNormals[idx].y;
                        dst_n[2] = mesh->mNormals[idx].z;
                    } else {
                        dst_n[0] = 0; dst_n[1] = 1; dst_n[2] = 0;
                    }

                    float* dst_uv = (v == 0) ? tri.uv0 : (v == 1) ? tri.uv1 : tri.uv2;
                    if (mesh->HasTextureCoords(0)) {
                        dst_uv[0] = mesh->mTextureCoords[0][idx].x;
                        dst_uv[1] = mesh->mTextureCoords[0][idx].y;
                    }
                }
                tri.mat_index = mat_idx;
                result.triangles.push_back(tri);
            }
        }
        for (unsigned int c = 0; c < node->mNumChildren; c++)
            traverse(node->mChildren[c]);
    };
    traverse(scene->mRootNode);

    if (result.triangles.empty()) {
        std::cerr << "[ModelLoader] No triangles found in: " << path << std::endl;
        return result;
    }

    // Compute mesh AABB
    float mn[3] = {1e30f, 1e30f, 1e30f};
    float mx[3] = {-1e30f,-1e30f,-1e30f};
    for (auto& t : result.triangles) {
        for (int k = 0; k < 3; k++) {
            mn[k] = std::min({mn[k], t.v0[k], t.v1[k], t.v2[k]});
            mx[k] = std::max({mx[k], t.v0[k], t.v1[k], t.v2[k]});
        }
    }

    float cx = (mn[0] + mx[0]) * 0.5f;
    float cy = (mn[1] + mx[1]) * 0.5f;
    float cz = (mn[2] + mx[2]) * 0.5f;
    float max_dim = std::max({mx[0]-mn[0], mx[1]-mn[1], mx[2]-mn[2]});
    float scale   = (max_dim > 1e-6f) ? (target_size / max_dim) : 1.0f;

    std::cout << "[ModelLoader] " << result.triangles.size() << " tris, "
              << result.materials.size() << " materials. "
              << "Scale: " << scale << std::endl;

    // Centre and scale
    for (auto& t : result.triangles) {
        for (int k = 0; k < 3; k++) {
            t.v0[k] = (t.v0[k] - (k==0?cx:k==1?cy:cz)) * scale;
            t.v1[k] = (t.v1[k] - (k==0?cx:k==1?cy:cz)) * scale;
            t.v2[k] = (t.v2[k] - (k==0?cx:k==1?cy:cz)) * scale;
        }
    }

    // Build flat BVH
    BuildBVH(result.triangles, result.bvh_nodes, 0, (int)result.triangles.size());
    std::cout << "[ModelLoader] BVH: " << result.bvh_nodes.size() << " nodes" << std::endl;

    result.valid = true;
    return result;
}
