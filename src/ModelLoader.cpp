#include "ModelLoader.h"
#include <assimp/Importer.hpp>
#include <assimp/scene.h>
#include <assimp/postprocess.h>
#include <iostream>
#include <algorithm>
#include <cassert>

// ------------------------------------------------------------------ helpers --

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
        m.albedo[0] = m.albedo[1] = m.albedo[2] = 0.8f;
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
        aiProcess_JoinIdenticalVertices);

    if (!scene || !scene->mRootNode) {
        std::cerr << "[ModelLoader] Failed to load: " << path
                  << "\n  " << importer.GetErrorString() << std::endl;
        return result;
    }

    // Convert materials
    for (unsigned int mi = 0; mi < scene->mNumMaterials; mi++)
        result.materials.push_back(ConvertMaterial(scene->mMaterials[mi]));

    // Ensure at least one material
    if (result.materials.empty()) {
        GPUMaterial def{}; def.albedo[0]=def.albedo[1]=def.albedo[2]=0.8f;
        def.roughness=0.5f; def.type=6; result.materials.push_back(def);
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
