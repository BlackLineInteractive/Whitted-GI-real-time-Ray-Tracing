#pragma once
#include "Scene.h"
#include <vector>

// Simple Bullet physics wrapper.
// Objects are tracked as opaque integer handles.
// Call Step(dt) each frame; then GetPosition(handle) for updated positions.

struct PhysicsBody {
    Vec3 position;
    Vec3 velocity;
    float mass;
    float radius;   // sphere collider
    bool  is_static;
};

class PhysicsWorld {
public:
    PhysicsWorld();
    ~PhysicsWorld();

    void Step(float dt);

    // Add a falling sphere; returns handle (index into internal array)
    int AddSphere(Vec3 pos, float radius, float mass = 1.0f);

    // Add a static floor plane at y = plane_y
    void SetFloor(float plane_y);

    // Get current position
    Vec3 GetPosition(int handle) const;

    // Remove all bodies
    void Clear();

private:
    std::vector<PhysicsBody> m_bodies;
    float m_floor_y = -1.0f;
    bool  m_has_floor = false;
};
