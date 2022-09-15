const std = @import("std");
const meta = std.meta;
const testing = std.testing;
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const Archetype = @import("Archetype.zig");
const Bucket = @import("Bucket.zig");
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;
const Data = @import("Data.zig");
const BoundedArray = std.BoundedArray;
const Model = @This();
const Type = std.builtin.Type;
const SegmentedList = std.SegmentedList;

buckets: BucketMap = .{},
/// Map of entity identifiers to the bucket along with the index they're stored at.
entities: EntityMap = .{},
archetypes: ArchetypeMap = .{},
/// Stack of retired entity identifiers to be recycled for new entities.
dead_pool: SegmentedList(Data.Entity, 8) = .{},
/// Maximum entity count
count: u24 = 0,

pub const BucketIndex = packed struct(u16) {
    index: u16,
};

pub const EntityMap = SegmentedList(Pointer, 8);
pub const ArchetypeMap = AutoHashMapUnmanaged(Archetype, BucketIndex);
pub const BucketMap = SegmentedList(Bucket, 8);
pub const Pointer = struct {
    index: Bucket.Index,
    bucket: BucketIndex,
};

pub const Mode = enum {
    /// Insert the entity in the first hole found within the target bucket.
    /// If no hole is found, append the entity to the end of the bucket.
    insert,
    /// Append the entity to the end of the bucket.
    append,
};

pub fn deinit(self: *Model, gpa: Allocator) void {
    self.entities.deinit(gpa);
    self.dead_pool.deinit(gpa);
    self.archetypes.deinit(gpa);
    var it = self.buckets.iterator(0);
    while (it.next()) |value| value.deinit();
    self.buckets.deinit(gpa);
}

pub const Entry = struct {
    id: Data.Entity,
    index: Bucket.Index,
};

/// `new` creates a new entity of the given type and initializes it's components
/// with the given value.
pub fn new(
    self: *Model,
    gpa: Allocator,
    mode: Mode,
    comptime Spec: type,
    value: *const Spec,
) !Entry {
    var count = self.count;

    const archetype = comptime Archetype.fromType(Spec);
    comptime assert(archetype.count() > 0); // empty is used as the null set
    const target_index = self.archetypes.get(archetype) orelse return error.MissingBucket;
    const target = self.buckets.at(target_index.index);

    const id = blk: {
        if (self.dead_pool.pop()) |dead| {
            var id = dead;
            id.generation +%= 1;
            break :blk id;
        } else {
            const id = @bitCast(Data.Entity, @as(u32, count));

            count += 1;

            _ = try self.entities.addOne(gpa);
            assert(self.entities.len == count);

            break :blk id;
        }
    };

    const index = switch (mode) {
        .insert => try target.insert(id),
        .append => try target.append(id),
    };

    self.count = count;

    const pointer = self.entities.at(id.index);
    pointer.bucket = target_index;
    pointer.index = index;

    var it = target.iterate(index.chunk);
    inline for (Archetype.fields) |field| {
        if (@hasField(Spec, field.name)) {
            const tag = @field(Archetype.Tag, field.name);
            const component = it.find(tag).?.array(tag);
            component[index.slot] = @field(value, field.name);
        }
    }

    return .{ .id = id, .index = index };
}

/// `register` a new archetype by creating a new bucket for it. Returns a
/// pointer to the newly allocated bucket.
///
/// note: it's expected that this is called either when it's known which
///       archetypes will be in use or in response to `error.MissingBucket`
///       and `error.MissingTarget`.
pub fn register(self: *Model, gpa: Allocator, archetype: Archetype) !*Bucket {
    const entry = try self.archetypes.getOrPut(gpa, archetype);
    assert(!entry.found_existing);

    const index: BucketIndex = .{ .index = @intCast(u16, self.buckets.len) };
    const bucket = try self.buckets.addOne(gpa);
    errdefer _ = self.buckets.pop();

    bucket.* = try Bucket.init(archetype);
    entry.value_ptr.* = index;

    return bucket;
}

pub const Relocate = struct {
    map: *EntityMap,

    pub fn move(self: Relocate, id: Data.Entity, index: Bucket.Index) !void {
        self.map.at(id.index).index = index;
    }
};

/// `delete` an entity from the Model.
pub fn delete(self: *Model, gpa: Allocator, id: Data.Entity) error{OutOfMemory}!void {
    const pointer = self.entities.at(id.index); // use after free
    const bucket = self.buckets.at(pointer.bucket.index); // use after free

    bucket.remove(pointer.index);
    bucket.commit(Relocate{ .map = &self.entities }) catch unreachable;

    pointer.* = undefined;

    try self.dead_pool.append(gpa, id);
}

test "create a new entity then destroy it" {
    var model: Model = .{};
    defer model.deinit(testing.allocator);

    const Spec = struct {
        position_even: Data.Point3 = .{ .x = 1, .y = 2, .z = 3 },
        velocity: Data.Vec3 = .{ .x = 4, .y = 5, .z = 6 },
    };

    const spec = comptime Archetype.fromType(Spec);
    const bucket = try model.register(testing.allocator, spec);

    const entity = try model.new(testing.allocator, .insert, Spec, &.{});

    var it = bucket.iterate(entity.index.chunk);
    while (it.next()) |component| {
        switch (component.tag) {
            .position_even => try testing.expectEqual(
                Data.Point3{ .x = 1, .y = 2, .z = 3 },
                component.array(.position_even)[0],
            ),
            .velocity => try testing.expectEqual(
                Data.Vec3{ .x = 4, .y = 5, .z = 6 },
                component.array(.velocity)[0],
            ),
            else => unreachable,
        }
    }

    try model.delete(testing.allocator, entity.id);
    try testing.expectEqual(@as(u17, 0), bucket.data.len);
}

/// `update` an existing entity with the given components and moving the entity
/// if new components were added.
pub fn update(
    self: *Model,
    mode: Mode,
    id: Data.Entity,
    comptime Spec: type,
    value: *const Spec,
) error{ OutOfMemory, MissingBucket, MissingTarget }!void {
    const spec = comptime Archetype.fromType(Spec);
    const pointer = self.entities.at(id.index); // use after free

    var bucket = self.buckets.at(pointer.bucket.index);

    const different = !bucket.type.contains(&spec);
    var tmp = bucket.type;
    tmp.merge(&spec);

    const target_index = self.archetypes.get(tmp) orelse {
        return error.MissingTarget;
    };

    const index = if (different) blk: {
        const target = self.buckets.at(target_index.index);

        const index = switch (mode) {
            .insert => try target.insert(id),
            .append => try target.append(id),
        };

        var move = bucket.type;
        move.diff(&spec);

        target.move(index, pointer.index, bucket, &move);

        bucket = target;
        pointer.index = index;
        break :blk index;
    } else pointer.index;

    pointer.bucket = target_index;

    var it = bucket.iterate(index.chunk);

    inline for (Archetype.fields) |field| {
        if (@hasField(Spec, field.name) and @sizeOf(field.field_type) != 0) {
            const tag = @field(Archetype.Tag, field.name);
            const component = it.find(tag).?.array(tag);
            component[index.slot] = @field(value, field.name);
        }
    }
}

test "create a new entity, update it, and then destroy it" {
    var model: Model = .{};
    defer model.deinit(testing.allocator);

    const Spec = struct {
        position_even: Data.Point3 = .{ .x = 1, .y = 2, .z = 3 },
        velocity: Data.Vec3 = .{ .x = 4, .y = 5, .z = 6 },
    };

    const spec = comptime Archetype.fromType(Spec);
    const bucket = try model.register(testing.allocator, spec);

    const entity = try model.new(testing.allocator, .insert, Spec, &.{});

    try model.update(.insert, entity.id, Spec, &.{
        .position_even = .{ .x = 11, .y = 22, .z = 33 },
        .velocity = .{ .x = 44, .y = 55, .z = 66 },
    });

    var it = bucket.iterate(entity.index.chunk);
    while (it.next()) |component| {
        switch (component.tag) {
            .position_even => try testing.expectEqual(
                Data.Point3{ .x = 11, .y = 22, .z = 33 },
                component.array(.position_even)[0],
            ),
            .velocity => try testing.expectEqual(
                Data.Vec3{ .x = 44, .y = 55, .z = 66 },
                component.array(.velocity)[0],
            ),
            else => unreachable,
        }
    }

    try model.delete(testing.allocator, entity.id);
    try testing.expectEqual(@as(u17, 0), bucket.data.len);
}

test "create a new entity, move it, then destroy it" {
    var model: Model = .{};
    defer model.deinit(testing.allocator);

    const Spec = struct {
        position_even: Data.Point3 = .{ .x = 1, .y = 2, .z = 3 },
        velocity: Data.Vec3 = .{ .x = 4, .y = 5, .z = 6 },
    };

    var spec = comptime Archetype.fromType(Spec);
    const bucket = try model.register(testing.allocator, spec);

    spec.add(.unallocated_affinity);
    const new_bucket = try model.register(testing.allocator, spec);

    const entity = try model.new(testing.allocator, .insert, Spec, &.{});

    const Affinity = struct {
        unallocated_affinity: u16 = 0xffff,
    };

    try model.update(.insert, entity.id, Affinity, &.{
        .unallocated_affinity = 42,
    });

    var it = new_bucket.iterate(entity.index.chunk);
    while (it.next()) |component| {
        switch (component.tag) {
            .position_even => try testing.expectEqual(
                Data.Point3{ .x = 1, .y = 2, .z = 3 },
                component.array(.position_even)[0],
            ),

            .velocity => try testing.expectEqual(
                Data.Vec3{ .x = 4, .y = 5, .z = 6 },
                component.array(.velocity)[0],
            ),

            .unallocated_affinity => try testing.expectEqual(
                @as(u16, 42),
                component.array(.unallocated_affinity)[0],
            ),

            else => unreachable,
        }
    }

    _ = try model.new(testing.allocator, .insert, Spec, &.{
        .position_even = .{ .x = 43, .y = 1, .z = 2 },
    });
    try testing.expectEqual(@as(u17, 1), bucket.data.len);

    try model.delete(testing.allocator, entity.id);
    try testing.expectEqual(@as(u17, 0), new_bucket.data.len);
}

/// `remove` components from an entity and move the entity to a new bucket.
pub fn remove(
    self: *Model,
    mode: Mode,
    id: Data.Entity,
    comptime components: anytype,
) error{ OutOfMemory, MissingTarget }!void {
    const spec = comptime Archetype.fromList(components);
    const pointer = self.entities.at(id.index); // use after free
    const old_bucket = self.buckets.at(pointer.bucket.index); // use after free

    assert(old_bucket.type.contains(&spec));

    var tmp = old_bucket.type;
    tmp.diff(&spec);

    const bucket_index = self.archetypes.get(tmp) orelse {
        return error.MissingTarget;
    };
    const bucket = self.buckets.at(bucket_index.index);

    const index = switch (mode) {
        .insert => try bucket.insert(id),
        .append => try bucket.append(id),
    };

    bucket.move(index, pointer.index, old_bucket, &tmp);
    pointer.index = index;
    pointer.bucket = bucket_index;
}

test "create a new entity, remove a component, then destroy it" {
    var model: Model = .{};
    defer model.deinit(testing.allocator);

    const Spec = struct {
        position_even: Data.Point3 = .{ .x = 1, .y = 2, .z = 3 },
        velocity: Data.Vec3 = .{ .x = 4, .y = 5, .z = 6 },
    };

    var spec = comptime Archetype.fromType(Spec);
    _ = try model.register(testing.allocator, spec);

    spec.remove(.velocity);

    const bucket = try model.register(testing.allocator, spec);

    const entity = try model.new(testing.allocator, .insert, Spec, &.{});
    try model.remove(.insert, entity.id, .{.velocity});

    var it = bucket.iterate(entity.index.chunk);
    while (it.next()) |component| {
        switch (component.tag) {
            .position_even => try testing.expectEqual(
                Data.Point3{ .x = 1, .y = 2, .z = 3 },
                component.array(.position_even)[0],
            ),

            else => unreachable,
        }
    }

    try model.delete(testing.allocator, entity.id);
    try testing.expectEqual(@as(u17, 0), bucket.data.len);
}

pub fn search(self: *Model, archetype: Archetype) Search {
    return .{
        .type = archetype,
        .model = self,
        .buckets = self.buckets.iterator(0),
    };
}

pub const Search = struct {
    type: Archetype,
    model: *Model,
    buckets: BucketMap.Iterator,

    pub fn next(self: *Search) ?*Bucket {
        while (self.buckets.next()) |bucket| {
            if (bucket.type.contains(&self.type)) {
                bucket.commit(Relocate{
                    .map = &self.model.entities,
                }) catch unreachable;
                return bucket;
            }
        }

        return null;
    }
};

/// `query` bucket storage for all buckets which match the given
/// component specification.
pub fn query(self: *Model, comptime Spec: type) Query(
    Archetype.fromType(Spec),
    mut(Spec),
) {
    return .{ .search = self.search(Archetype.fromType(Spec)) };
}

fn mut(comptime Spec: type) Archetype {
    comptime {
        var tmp: Archetype = .{ .bitset = Archetype.empty };

        for (meta.fields(Spec)) |field| {
            const tag = @field(Archetype.Tag, field.name);
            const info = @typeInfo(field.field_type);
            const T = Archetype.TypeOf(tag);
            const name = @typeName(T);

            if (info != .Pointer or info.Pointer.child != T) @compileError( //
                "query parameter `" ++ field.name ++
                "` must be a slice of " ++ name);

            if (info.Pointer.size != .Slice) {
                @compileError("query parameter `" ++ field.name ++
                    "` can either be `[]" ++ name ++
                    "` or `[]const " ++ name ++
                    "` not " ++ @typeName(field.field_type));
            }

            if (info.Pointer.is_const) tmp.add(tag);
        }

        return tmp;
    }
}

pub fn Query(comptime archetype: Archetype, comptime mutable: Archetype) type {
    return struct {
        search: Search,

        const Self = @This();

        pub const Result = struct {
            bucket: *Bucket,
            offsets: [archetype.count()]u16,
            len: u17,

            fn offset(self: Result, comptime tag: Archetype.Tag) u16 {
                const index = comptime blk: {
                    var index: u16 = 0;

                    var it = archetype.iterator();
                    while (it.next()) |found| : (index += 1) {
                        if (found == tag) break :blk index;
                    }

                    @compileError("." ++ @tagName(tag) ++
                        " is missing from the query specification");
                };

                return self.offsets[index];
            }

            pub fn slice(self: Result, chunk: u10, comptime tag: Archetype.Tag) blk: {
                const T = Archetype.TypeOf(tag);
                break :blk if (mutable.have(tag)) []T else []const T;
            } {
                const T = Archetype.TypeOf(tag);

                const bytes = self.bucket.block(@intToEnum(Bucket.Index.Chunk, chunk));
                const base = bytes.ptr + self.offset(tag);

                return if (comptime mutable.have(tag))
                    @ptrCast([*]T, base)[0 .. self.len & Bucket.slot_mask]
                else
                    @ptrCast([*]const T, base)[0 .. self.len & Bucket.slot_mask];
            }
        };

        pub fn next(self: *Self) ?Result {
            const bucket = self.search.next() orelse return null;

            var offsets: [archetype.count()]u16 = undefined;
            var offset: u16 = 0;

            var it = bucket.type.iterator();
            var index: u16 = 0;

            while (it.next()) |tag| {
                if (archetype.have(tag)) {
                    offsets[index] = offset;
                    index += 1;
                }

                offset += @as(u16, Archetype.size[@enumToInt(tag)]) * 64;
            }

            return .{
                .offsets = offsets,
                .bucket = bucket,
                .len = bucket.data.len,
            };
        }
    };
}

test "create a new entity, search for it, then destroy it" {
    var model: Model = .{};
    defer model.deinit(testing.allocator);

    const Spec = struct {
        position_even: Data.Point3 = .{ .x = 1, .y = 2, .z = 3 },
        velocity: Data.Vec3 = .{ .x = 4, .y = 5, .z = 6 },
    };

    const spec = Archetype.fromType(Spec);
    const bucket = try model.register(testing.allocator, spec);

    const entity = try model.new(testing.allocator, .insert, Spec, &.{});

    var it = model.query(struct {
        position_even: []Data.Point3,
    });

    const result = it.next() orelse unreachable;
    {
        var chunk: u10 = 0;
        while (chunk <= result.len >> Bucket.slot_bits) : (chunk += 1) {
            const slice = result.slice(chunk, .position_even);
            try testing.expectEqual(@as(usize, 1), slice.len);
            try testing.expectEqual((Spec{}).position_even, slice[0]);
        }
    }

    try model.delete(testing.allocator, entity.id);
    try testing.expectEqual(@as(u17, 0), bucket.data.len);
}
