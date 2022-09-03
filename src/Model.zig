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

entities: EntityMap = .{},
buckets: BucketMap = .{},
// TODO: dead entity stack
count: u32 = 0,

pub const EntityMap = AutoHashMapUnmanaged(Data.Entity, Pointer);
pub const BucketMap = AutoHashMapUnmanaged(Archetype, Bucket);
pub const Pointer = struct {
    index: Bucket.Index,
    type: Archetype,
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
    var it = self.buckets.valueIterator();
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
    var limit: u32 = 0xffff_ffff;
    var count = self.count;
    defer self.count = count;

    while (true) : (limit -= 1) {
        defer count +%= 1;

        const id = @intToEnum(Data.Entity, count);

        const entry = try self.entities.getOrPut(gpa, id);
        if (entry.found_existing) continue; // searching

        const archetype = Archetype.fromType(Spec);
        const target = self.buckets.getPtr(archetype) orelse return error.MissingBucket;

        const index = switch (mode) {
            .insert => try target.insert(id),
            .append => try target.append(id),
        };

        errdefer target.data.len -= 1;

        entry.value_ptr.* = .{
            .index = index,
            .type = archetype,
        };

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
}

pub const Relocate = struct {
    map: *EntityMap,

    pub fn move(self: Relocate, id: Data.Entity, index: Bucket.Index) !void {
        self.map.getPtr(id).?.index = index;
    }
};

/// `delete` an entity from the Model.
///
/// perf: this method is slow as it searches for the bucket containing
///       the entity's components each time it's called, it's better to
///       call `remove` from the bucket directly such that it may be
///       batch removed upon `commit`.
pub fn delete(self: *Model, id: Data.Entity) void {
    const pointer = self.entities.get(id).?; // use after free
    const bucket = self.buckets.getPtr(pointer.type).?; // use after free
    bucket.remove(pointer.index);
    bucket.commit(Relocate{ .map = &self.entities }) catch unreachable;
    _ = self.entities.remove(id);
}

test "create a new entity then destroy it" {
    var model: Model = .{};
    defer model.deinit(testing.allocator);

    const Spec = struct {
        position: Data.Point3 = .{ .x = 1, .y = 2, .z = 3 },
        velocity: Data.Vec3 = .{ .x = 4, .y = 5, .z = 6 },
    };

    const spec = Archetype.fromType(Spec);
    const entry = try model.buckets.getOrPutValue(
        testing.allocator,
        spec,
        try Bucket.init(spec),
    );

    const entity = try model.new(testing.allocator, .insert, Spec, &.{});

    var it = entry.value_ptr.iterate(entity.index.chunk);
    while (it.next()) |component| {
        switch (component.tag) {
            .position => try testing.expectEqual(
                Data.Point3{ .x = 1, .y = 2, .z = 3 },
                component.array(.position)[0],
            ),
            .velocity => try testing.expectEqual(
                Data.Vec3{ .x = 4, .y = 5, .z = 6 },
                component.array(.velocity)[0],
            ),
            else => unreachable,
        }
    }

    model.delete(entity.id);
    try testing.expectEqual(@as(u17, 0), entry.value_ptr.data.len);
}

/// `update` an existing entity with the given components and moving the entity
/// if new components were added.
pub fn update(
    self: *Model,
    mode: Mode,
    id: Data.Entity,
    comptime Spec: type,
    value: *const Spec,
) !void {
    const spec = Archetype.fromType(Spec);
    const pointer = self.entities.getPtr(id).?; // use after free
    var bucket = self.buckets.getPtr(pointer.type).?; // use after free
    const different = !pointer.type.contains(&spec);
    var tmp = pointer.type;
    tmp.merge(&spec);

    const index = if (different) blk: {
        const target = self.buckets.getPtr(tmp) orelse {
            return error.MissingTarget;
        };

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

    pointer.type = tmp;

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
        position: Data.Point3 = .{ .x = 1, .y = 2, .z = 3 },
        velocity: Data.Vec3 = .{ .x = 4, .y = 5, .z = 6 },
    };

    const spec = Archetype.fromType(Spec);
    const entry = try model.buckets.getOrPutValue(
        testing.allocator,
        spec,
        try Bucket.init(spec),
    );

    const entity = try model.new(testing.allocator, .insert, Spec, &.{});

    try model.update(.insert, entity.id, Spec, &.{
        .position = .{ .x = 11, .y = 22, .z = 33 },
        .velocity = .{ .x = 44, .y = 55, .z = 66 },
    });

    var it = entry.value_ptr.iterate(entity.index.chunk);
    while (it.next()) |component| {
        switch (component.tag) {
            .position => try testing.expectEqual(
                Data.Point3{ .x = 11, .y = 22, .z = 33 },
                component.array(.position)[0],
            ),
            .velocity => try testing.expectEqual(
                Data.Vec3{ .x = 44, .y = 55, .z = 66 },
                component.array(.velocity)[0],
            ),
            else => unreachable,
        }
    }

    model.delete(entity.id);
    try testing.expectEqual(@as(u17, 0), entry.value_ptr.data.len);
}

test "create a new entity, move it, then destroy it" {
    var model: Model = .{};
    defer model.deinit(testing.allocator);

    const Spec = struct {
        position: Data.Point3 = .{ .x = 1, .y = 2, .z = 3 },
        velocity: Data.Vec3 = .{ .x = 4, .y = 5, .z = 6 },
    };

    var spec = Archetype.fromType(Spec);
    const entry = try model.buckets.getOrPutValue(
        testing.allocator,
        spec,
        try Bucket.init(spec),
    );

    spec.add(.unallocated_affinity);
    const new_entry = try model.buckets.getOrPutValue(
        testing.allocator,
        spec,
        try Bucket.init(spec),
    );

    const entity = try model.new(testing.allocator, .insert, Spec, &.{});

    const Affinity = struct {
        unallocated_affinity: u16 = 0xffff,
    };

    try model.update(.insert, entity.id, Affinity, &.{
        .unallocated_affinity = 42,
    });

    var it = new_entry.value_ptr.iterate(entity.index.chunk);
    while (it.next()) |component| {
        switch (component.tag) {
            .position => try testing.expectEqual(
                Data.Point3{ .x = 1, .y = 2, .z = 3 },
                component.array(.position)[0],
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
        .position = .{ .x = 43, .y = 1, .z = 2 },
    });
    try testing.expectEqual(@as(u17, 1), entry.value_ptr.data.len);

    model.delete(entity.id);
    try testing.expectEqual(@as(u17, 0), new_entry.value_ptr.data.len);
}

/// `remove` components from an entity and move the entity to a new bucket.
pub fn remove(
    self: *Model,
    mode: Mode,
    id: Data.Entity,
    comptime components: anytype,
) !void {
    const spec = comptime Archetype.fromList(components);
    const pointer = self.entities.getPtr(id).?; // use after free
    assert(pointer.type.contains(&spec));

    const old_bucket = self.buckets.getPtr(pointer.type).?; // use after free

    pointer.type.diff(&spec);
    errdefer pointer.type.merge(&spec);

    const bucket = self.buckets.getPtr(pointer.type) orelse {
        return error.MissingBucket;
    };

    const index = switch (mode) {
        .insert => try bucket.insert(id),
        .append => try bucket.append(id),
    };

    bucket.move(index, pointer.index, old_bucket, &pointer.type);
    pointer.index = index;
}

test "create a new entity, remove a component, then destroy it" {
    var model: Model = .{};
    defer model.deinit(testing.allocator);

    const Spec = struct {
        position: Data.Point3 = .{ .x = 1, .y = 2, .z = 3 },
        velocity: Data.Vec3 = .{ .x = 4, .y = 5, .z = 6 },
    };

    var spec = Archetype.fromType(Spec);
    _ = try model.buckets.getOrPutValue(
        testing.allocator,
        spec,
        try Bucket.init(spec),
    );

    spec.remove(.velocity);

    const entry = try model.buckets.getOrPutValue(
        testing.allocator,
        spec,
        try Bucket.init(spec),
    );

    const entity = try model.new(testing.allocator, .insert, Spec, &.{});
    try model.remove(.insert, entity.id, .{.velocity});

    var it = entry.value_ptr.iterate(entity.index.chunk);
    while (it.next()) |component| {
        switch (component.tag) {
            .position => try testing.expectEqual(
                Data.Point3{ .x = 1, .y = 2, .z = 3 },
                component.array(.position)[0],
            ),

            else => unreachable,
        }
    }

    model.delete(entity.id);
    try testing.expectEqual(@as(u17, 0), entry.value_ptr.data.len);
}

pub fn search(self: *Model, archetype: Archetype) Search {
    return .{
        .type = archetype,
        .model = self,
        .buckets = self.buckets.iterator(),
    };
}

pub const Search = struct {
    type: Archetype,
    model: *Model,
    buckets: BucketMap.Iterator,

    pub fn next(self: *Search) ?*Bucket {
        while (self.buckets.next()) |entry| {
            if (entry.key_ptr.contains(&self.type)) {
                entry.value_ptr.commit(Relocate{
                    .map = &self.model.entities,
                }) catch unreachable;
                return entry.value_ptr;
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
        position: Data.Point3 = .{ .x = 1, .y = 2, .z = 3 },
        velocity: Data.Vec3 = .{ .x = 4, .y = 5, .z = 6 },
    };

    const spec = Archetype.fromType(Spec);
    const entry = try model.buckets.getOrPutValue(
        testing.allocator,
        spec,
        try Bucket.init(spec),
    );

    const entity = try model.new(testing.allocator, .insert, Spec, &.{});

    var it = model.query(struct {
        position: []Data.Point3,
    });

    const result = it.next() orelse unreachable;
    {
        var chunk: u10 = 0;
        while (chunk <= result.len >> Bucket.slot_bits) : (chunk += 1) {
            const slice = result.slice(chunk, .position);
            try testing.expectEqual(@as(usize, 1), slice.len);
            try testing.expectEqual((Spec{}).position, slice[0]);
        }
    }

    model.delete(entity.id);
    try testing.expectEqual(@as(u17, 0), entry.value_ptr.data.len);
}
