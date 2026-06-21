#pragma once
#include "Scene.h"
#include <string>
#include <vector>

// Loaded mesh data ready for GPU upload
struct MeshData {
    std::vector<GPUTriangle>  triangles;
    std::vector<GPUMaterial>  materials;
    std::vector<GPUBVHNode>   bvh_nodes;
    std::vector<uint8_t>      texture_array_data;
    Vec3 origin = {0, 0, 0};
    bool valid  = false;
};

// Loads a 3D model from disk using Assimp (GLB, glTF 2.0, OBJ).
// Automatically scales and centres the mesh so its largest dimension fits
// within target_size world units.
MeshData LoadModel(const std::string& path, float target_size = 2.0f);
