pub const Entity = enum(u32) { _ };

position: Point3,
velocity: Vec3,
unallocated_affinity: u16,
affinity: Affinity,

pub const Point3 = extern struct { x: f32, y: f32, z: f32 };
pub const Vec3 = extern struct { x: f32, y: f32, z: f32 };
pub const Affinity = extern struct {
    flame: u16,
    gravity: u16,
    illusion: u16,
};
