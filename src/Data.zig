const InfiniteAxisUtilitySystem = @import("InfiniteAxisUtilitySystem.zig");

pub const Entity = packed struct(u32) {
    index: u24,
    /// Incremented whenever the entity is recycled to catch bugs involving systems that hold
    /// on to the reference for too long.
    generation: u8,

    pub inline fn eql(self: Entity, other: Entity) bool {
        return @bitCast(u32, self) == @bitCast(u32, other);
    }
};

position_even: Point3,
position_odd: Point3,

velocity: Vec3,

unallocated_affinity: u16,
affinity: Affinity,
mana: u16,

health: u16,

pub const Point3 = extern struct { x: f32, y: f32, z: f32 };
pub const Vec3 = extern struct { x: f32, y: f32, z: f32 };
pub const Affinity = extern struct {
    flame: u16,
    gravity: u16,
    illusion: u16,
};
