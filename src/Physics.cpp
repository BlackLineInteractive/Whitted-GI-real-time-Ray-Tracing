#include "Physics.h"
#include <cmath>

// Lightweight analytic rigid body simulation using Bullet libraries
// for math helpers but our own integration loop.
// This avoids the need for a full btDiscreteDynamicsWorld setup,
// keeping the dependency purely at link level (bullet libs in Homebrew).

static const float GRAVITY    = -9.81f;
static const float RESTITUTION = 0.45f;   // bounciness
static const float FRICTION    = 0.92f;   // lateral damping per frame

PhysicsWorld::PhysicsWorld()  = default;
PhysicsWorld::~PhysicsWorld() = default;

void PhysicsWorld::SetFloor(float plane_y) {
    m_floor_y  = plane_y;
    m_has_floor = true;
}

int PhysicsWorld::AddSphere(Vec3 pos, float radius, float mass) {
    PhysicsBody b;
    b.position  = pos;
    b.velocity  = {0, 0, 0};
    b.mass      = mass;
    b.radius    = radius;
    b.is_static = (mass <= 0.0f);
    m_bodies.push_back(b);
    return (int)m_bodies.size() - 1;
}

Vec3 PhysicsWorld::GetPosition(int handle) const {
    if (handle < 0 || handle >= (int)m_bodies.size()) return {0,0,0};
    return m_bodies[handle].position;
}

void PhysicsWorld::Clear() { m_bodies.clear(); }

void PhysicsWorld::Step(float dt) {
    const float MAX_DT = 1.0f / 30.0f;
    if (dt > MAX_DT) dt = MAX_DT;

    for (auto& b : m_bodies) {
        if (b.is_static) continue;

        // Gravity
        b.velocity.y += GRAVITY * dt;

        // Integrate position
        b.position = b.position + b.velocity * dt;

        // Floor collision
        if (m_has_floor && b.position.y - b.radius < m_floor_y) {
            b.position.y = m_floor_y + b.radius;
            b.velocity.y = -b.velocity.y * RESTITUTION;
            // Lateral friction
            b.velocity.x *= FRICTION;
            b.velocity.z *= FRICTION;
        }
    }

    // Sphere-sphere collisions (O(n²), fine for <20 objects)
    for (int i = 0; i < (int)m_bodies.size(); i++) {
        for (int j = i + 1; j < (int)m_bodies.size(); j++) {
            auto& a = m_bodies[i];
            auto& b = m_bodies[j];
            Vec3  delta = b.position - a.position;
            float dist  = delta.length();
            float min_d = a.radius + b.radius;
            if (dist < min_d && dist > 1e-6f) {
                Vec3 n = delta / dist;
                float overlap = (min_d - dist) * 0.5f;
                if (!a.is_static) a.position = a.position - n * overlap;
                if (!b.is_static) b.position = b.position + n * overlap;

                // Impulse exchange
                Vec3 rel_vel = b.velocity - a.velocity;
                float vn = rel_vel.dot(n);
                if (vn < 0) {
                    float j_imp = -(1 + RESTITUTION) * vn /
                                  (1.0f/a.mass + 1.0f/b.mass + 1e-9f);
                    Vec3 impulse = n * j_imp;
                    if (!a.is_static) a.velocity = a.velocity - impulse * (1.0f/a.mass);
                    if (!b.is_static) b.velocity = b.velocity + impulse * (1.0f/b.mass);
                }
            }
        }
    }
}
