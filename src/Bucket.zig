//! `Bucket` maintains a hybrid SoA layout for entity components consisting of
//! N component chunks of M elements each. Memory is requested upfront for
//! the maximum size of the structure relying on virtual memory support where
//! pages are only assigned physical memory when touched.
//!
//! The general structure can be thought of as follows but with the components
//! present decided at runtime:
//!
//! ```
//! const Chunk = [N]struct {
//!     position: [M]Data.Point3,
//!     velocity: [M]Data.Vec3,
//!     health: [M]u32,
//! };
//! ```
//! An additional [M]Data.Entity is appended to each chunk such that it's
//! possible to track entities inline rather than having to maintain
//! separate storage.
//!
//! Hybrid SoA was chosen for better memory locality and lower implementation
//! complexity compared to plain SoA and as a performance improvement over AoS.

const std = @import("std");
const os = std.os;
const mem = std.mem;
const testing = std.testing;
const assert = std.debug.assert;

const Bucket = @This();
const Data = @import("Data.zig");
const Archetype = @import("Archetype.zig");

type: Archetype,
bytes: [*]align(mem.page_size) u8,
free: Free = .{},
data: Meta,

pub const Meta = packed struct(u64) {
    /// Size of chunks in bytes
    size: u32,
    /// Number of slots used within the bucket
    len: u17 = 0,
    /// Number of slots within each chunk as a power of two starting from 1
    slots: u4,
    /// Free space for sale
    padding: u11 = 0,
};

pub const Free = extern struct {
    head: Index = tail_end,
    tail: Index = head_end,

    const head_end: Index = @intToEnum(Index, 0);
    const tail_end: Index = @intToEnum(Index, 0xffff);

    pub const Node = extern struct {
        next: Index,
        prev: Index,
    };

    pub fn isEmpty(self: Free) bool {
        return @enumToInt(self.head) > @enumToInt(self.tail);
    }
};

pub const Index = enum(u16) {
    _,

    pub inline fn chunk(self: Index, slots: u4) u16 {
        return @enumToInt(self) >> slots;
    }

    pub inline fn slot(self: Index, slots: u4) u16 {
        return @enumToInt(self) & ((@as(u16, 1) << slots) - 1);
    }

    pub inline fn eql(self: Index, other: Index) bool {
        return self == other;
    }
};

pub const slot_bits = 6;
pub const slot_mask = 0b11_1111;

const entity_column = @sizeOf(Data.Entity) * 64;

/// `init` reserves all memory the bucket would need upfront thus relying on
/// the properties of virtual memory to avoid paying the cost of such in
/// addition to a guard page at the end to catch out of bound writes.
///
/// Since all chunks are aligned by 64 bytes and there are 1024 chunks the
/// guard page is guaranteed to be aligned to 4096 bytes.
/// ```
///               data                 guard page
/// ,---------------------------------,----------,
/// | 1024 * 64 * @sizeOf(components) |   4096   |
/// '---------------------------------'----------'
/// ```
pub fn init(archetype: Archetype, slots: u4) !Bucket {
    const size = chunkSize(&archetype, slots);
    const chunks = @as(u32, 1) << (16 - @as(u5, slots));
    const bytes = size * chunks;

    // memory + guard page
    const memory = try os.mmap(
        null,
        bytes + mem.page_size,
        os.PROT.NONE,
        os.MAP.ANONYMOUS | os.MAP.PRIVATE,
        -1,
        0,
    );
    errdefer os.munmap(memory);

    // ensure memory is writable
    _ = try os.mmap(
        memory.ptr,
        bytes,
        os.PROT.READ | os.PROT.WRITE,
        os.MAP.FIXED | os.MAP.PRIVATE | os.MAP.ANONYMOUS,
        -1,
        0,
    );

    return .{
        .type = archetype,
        .bytes = memory.ptr,
        .data = .{
            .size = @intCast(u32, size),
            .slots = slots,
        },
    };
}

/// Release memory associated with the bucket.
///
/// safety: ensure the entities contained within the bucket have all
///         either moved or been removed before calling `deinit`.
pub fn deinit(self: *Bucket) void {
    const chunks = @as(u32, 1) << (16 - @as(u5, self.data.slots));
    os.munmap(self.bytes[0 .. @as(usize, self.data.size) * chunks + mem.page_size]);
    self.* = undefined;
}

test "guard page" {
    var bucket = try Bucket.init(Archetype.fromList(.{
        .position_even,
        .velocity,
    }), 6);
    defer bucket.deinit();

    _ = try bucket.insert(@bitCast(Data.Entity, @as(u32, 42)));

    const chunks = @as(u32, 1) << (16 - @as(u5, bucket.data.slots));
    const last_byte = chunks * @as(usize, bucket.data.size) - 1;
    bucket.bytes[last_byte] = 1; // below guard page

    bucket.remove(@intToEnum(Index, 0));
    try bucket.commit(struct {
        pub fn move(_: Data.Entity, _: Index) !void {}
    });

    try testing.expectEqual(@as(u17, 0), bucket.data.len);
}

pub const ComponentIterator = struct {
    type: Archetype.Iterator,
    slots: u16,
    bytes: [*]u8,

    pub const Component = struct {
        tag: Archetype.Tag,
        slots: u16,
        ptr: [*]u8,

        pub fn array(
            self: Component,
            comptime tag: Archetype.Tag,
        ) []Archetype.TypeOf(tag) {
            assert(@field(Archetype.Tag, @tagName(tag)) == self.tag);
            return @ptrCast([*]Archetype.TypeOf(tag), self.ptr)[0..self.slots];
        }
    };

    pub fn next(self: *ComponentIterator) ?Component {
        const tag = self.type.next() orelse return null;
        const index = @enumToInt(tag);
        const size: usize = Archetype.size[index];
        if (size == 0) return null;

        defer self.bytes += self.slots * size;

        return .{ .tag = tag, .ptr = self.bytes, .slots = self.slots };
    }

    pub fn find(self: *ComponentIterator, tag: Archetype.Tag) ?Component {
        while (self.next()) |pair| {
            if (pair.tag == tag) return pair;
        }

        return null;
    }
};

/// `iterate` over the components within a chunk at the given index.
pub fn iterate(self: *const Bucket, chunk: u16) ComponentIterator {
    assert(chunk <= self.data.len >> self.data.slots); // use after free
    return .{
        .type = self.type.iterator(),
        .bytes = self.block(chunk).ptr,
        .slots = @as(u16, 1) << self.data.slots,
    };
}

/// `insert` the entity by filling the first hole found within the
/// bucket or by appending to the end of the bucket if no holes are
/// present.
///
/// ```
/// E E N N E E E N E E E N N N |
///     ^                     ^
///     H                     T
///
///     +
/// E E E N E E E N E E E N N N |
///       ^                   ^
///       H                   T
/// ```
///
/// safety: it's not safe to call this method while iterating over the bucket
///         using the bucket.len field.
pub fn insert(self: *Bucket, id: Data.Entity) error{OutOfMemory}!Index {
    assert(self.data.len <= 0x1_0000);
    if (self.free.isEmpty()) {
        return try self.append(id);
    } else {
        const next_chunk = self.free.head.chunk(self.data.slots);
        const next_slot = self.free.head.slot(self.data.slots);
        const next = self.nodes(next_chunk)[next_slot].next;

        defer {
            if (self.free.head.eql(next)) {
                self.free = .{};
            } else {
                self.free.head = next;
            }
        }

        const index = self.free.head;
        const index_chunk = index.chunk(self.data.slots);
        const index_slot = index.slot(self.data.slots);
        self.entities(index_chunk)[index_slot] = id;

        return index;
    }
}

/// `append` space for a new entity to the end of the bucket.
///
/// ```
/// E E N N E E E N E E E N N N |
///     ^                     ^
///     H                     T
///
///                             +
/// E E N N E E E N E E E N N N E |
///     ^                     ^
///     H                     T
/// ```
///
/// safety: it's safe to call this method while iterating over the bucket.
pub fn append(self: *Bucket, id: Data.Entity) error{OutOfMemory}!Index {
    assert(self.data.len <= 0x1_0000);
    if (self.data.len == 0x1_0000) return error.OutOfMemory;

    const index = @intToEnum(Index, @intCast(u16, self.data.len));
    self.data.len += 1;
    self.entities(index.chunk(self.data.slots))[index.slot(self.data.slots)] = id;

    return index;
}

/// `remove` marks an entity for removal from the bucket by constructing
/// a linked list of items to be removed within the entity id list.
/// ```
/// --------head-------------->
///     ,-,       ,-------, ,-,
///     | |       |       | | |
/// E E N N E E E N E E E N N N
///     ^ |       |       | | ^
///     H '-------'       '-' T
/// <----------------tail------
/// ```
pub fn remove(self: *Bucket, index: Index) void {
    assert(@enumToInt(index) < self.data.len); // out of bounds
    const item = self.nodes(index.chunk(self.data.slots));

    if (!self.free.isEmpty()) {
        assert(@enumToInt(self.free.tail) < @enumToInt(index));
        const tail = self.nodes(self.free.tail.chunk(self.data.slots));
        tail[self.free.tail.slot(self.data.slots)].next = index;
        item[index.slot(self.data.slots)] = .{
            .next = index,
            .prev = self.free.tail,
        };
        self.free.tail = index;
    } else {
        item[index.slot(self.data.slots)] = .{
            .next = index,
            .prev = index,
        };

        self.free = .{
            .head = index,
            .tail = index,
        };
    }
}

/// `commit` changes to the bucket by removing marked entities from the
/// the end decrementing the length and performing a swap removal of
/// entities between unmarked entities.
///
/// `commit` starts with an id list similar to the example below:
/// ```
/// E E N E E E E N E E E N N N |
///     ^                     ^
///     H                     T
/// ```
/// where the *H*ead and *T*ail indices point to the first and last
/// marked items. From there the length is decremented and the tail
/// index moved until either the list is empty or the tail points to
/// a node between unmarked nodes.
/// ```
/// E E N E E E E N E E E | N N N
///     ^         ^
///     H         T
/// ```
/// Now that the tail index is no longer at the last entity of the
/// list is moved to the position of the head index and the head
/// moves to the next node.
/// ```
/// E E N E E E E N E E E | N N N
///     ^         ^     |
///     H         T     |
///               ,-----'
///               v
/// E E N E E E E E E E | e N N N
/// ```
/// The process ends when both head and tail indices are equivalent
/// after the last swap removal / decrement.
/// ```
/// E E N E E E E E E E | e N N N
///     ^             |
///     H             |
///     T             |
///     ,-------------'
///     v
/// E E E E E E E E E | e e N N N
/// ```
pub fn commit(self: *Bucket, closure: anytype) !void {
    if (self.free.isEmpty()) return;

    var len = self.data.len;
    var list = self.free;

    defer self.data.len = len;

    self.free = .{};

    loop: while (true) {
        while (@enumToInt(list.tail) == len - 1) {
            len -= 1;
            if (len == 0) break :loop;

            const slot = list.tail.slot(self.data.slots);
            const chunk = list.tail.chunk(self.data.slots);
            const prev = self.nodes(chunk)[slot].prev;

            if (list.tail.eql(prev)) break :loop;
            self.nodes(chunk)[slot].next = list.tail;
            list.tail = prev;
        }

        while (@enumToInt(list.tail) != len - 1 and @enumToInt(list.head) < len) {
            len -= 1;

            const old = @intToEnum(Index, @intCast(u16, len));

            const next_chunk = list.head.chunk(self.data.slots);
            const next_slot = list.head.slot(self.data.slots);
            const old_chunk = old.chunk(self.data.slots);
            const old_slot = old.slot(self.data.slots);

            const next = self.nodes(next_chunk)[next_slot].next;
            const entity = self.entities(old_chunk)[old_slot];

            self.relocate(list.head, old);

            try closure.move(entity, list.head);

            if (list.head.eql(next)) break :loop;
            list.head = next;
        }

        if (@enumToInt(list.head) >= len) break;
    }
}

/// `move` entity components from one bucket to another while marking
/// the entity in the src bucket as removed.
pub fn move(
    dst: *Bucket,
    dst_index: Index,
    src_index: Index,
    src: *Bucket,
    spec: *const Archetype,
) void {
    assert(dst != src); // invalid move source, use relocate
    assert(dst.type.contains(spec)); // invalid move target
    assert(src.type.contains(spec)); // invalid move source
    assert( // invalid entity id
        dst.entities(dst_index.chunk(dst.data.slots))[dst_index.slot(dst.data.slots)].eql(
        src.entities(src_index.chunk(src.data.slots))[src_index.slot(src.data.slots)],
    ));

    var dst_it = dst.iterate(dst_index.chunk(dst.data.slots));
    var src_it = src.iterate(src_index.chunk(src.data.slots));
    var spec_it = spec.iterator();

    while (spec_it.next()) |tag| {
        const size = Archetype.size[@enumToInt(tag)];

        const dst_offset = size * @as(usize, dst_index.slot(dst.data.slots));
        const src_offset = size * @as(usize, src_index.slot(src.data.slots));

        const dst_ptr = dst_it.find(tag).?.ptr + dst_offset;
        const src_ptr = src_it.find(tag).?.ptr + src_offset;

        @memcpy(dst_ptr, src_ptr, size);
    }

    src.remove(dst_index);
}

/// `relocate` an entity within the bucket.
///
/// safety: this method is not safe as it doesn't update any external references
///         to the entity nor does it care if another entity is overwritten.
pub fn relocate(self: *Bucket, dst: Index, src: Index) void {
    const dst_chunk = dst.chunk(self.data.slots);
    const src_chunk = src.chunk(self.data.slots);
    const dst_slot = dst.slot(self.data.slots);
    const src_slot = src.slot(self.data.slots);

    const dst_base = self.block(dst_chunk).ptr;
    const src_base = self.block(src_chunk).ptr;
    const slots = @as(u16, 1) << self.data.slots;

    var offset: usize = 0;
    var it = self.type.iterator();

    while (it.next()) |tag| {
        const size = Archetype.size[@enumToInt(tag)];

        const dst_slot_off = size * @as(usize, dst_slot);
        const src_slot_off = size * @as(usize, src_slot);

        const dst_ptr = dst_base + offset + dst_slot_off;
        const src_ptr = src_base + offset + src_slot_off;

        offset += @as(usize, size) * slots;

        @memcpy(dst_ptr, src_ptr, size);
    }

    self.entities(dst_chunk)[dst_slot] = self.entities(src_chunk)[src_slot];
}

/// `collect` tells the kernel that any of the pages above the current index
/// are not in use thus the resources associatd with it can be removed. This
/// method only exists to release memory pressure and doesn't affect the
/// semantics of the other bucket methods.
pub fn collect(self: *Bucket) !void {
    const offset = (self.data.len >> slot_bits) * @as(usize, self.data.size);
    const aligned = offset + ((offset + mem.page_size) & mem.page_size);
    const chunks = @as(u32, 1) << (16 - @as(u5, self.data.slots));
    const memory = @as(usize, self.size) * chunks;
    try os.madvise(self.bytes + aligned, memory - aligned, os.MADV.DONTNEED);
}

const TestMove = struct {
    id: []const u32,
    index: u16 = 0,

    pub fn move(self: *TestMove, entity: Data.Entity, _: Index) !void {
        try testing.expectEqual(@bitCast(Data.Entity, self.id[self.index]), entity);
        self.index += 1;
    }

    pub fn set(self: *TestMove, id: []const u32) void {
        self.* = .{ .id = id };
    }
};

fn testBucket(entries: u16, slots: u4, comptime list: anytype) !Bucket {
    var bucket = try Bucket.init(Archetype.fromList(list), slots);
    errdefer bucket.deinit();

    var count: u16 = 0;
    while (count < entries) : (count += 1) {
        _ = try bucket.insert(@bitCast(Data.Entity, @as(u32, 0xffff - count)));
    }

    return bucket;
}

test "removing entries from the start" {
    var slots: u4 = 2;
    while (true) {
        var bucket = try testBucket(3, slots, .{ .position_even, .velocity });
        defer bucket.deinit();

        var context: TestMove = .{ .id = undefined };
        for ([_]u6{ 2, 1, 0 }) |entry| {
            context.set(&.{0xffff - @as(u32, entry)});
            bucket.remove(@intToEnum(Index, 0));
            try bucket.commit(&context);
            try testing.expectEqual(@as(u17, entry), bucket.data.len);
        }

        slots +%= 1;
        if (slots == 0) break;
    }
}

test "removing entries from the end" {
    var slots: u4 = 2;
    while (true) {
        var bucket = try testBucket(3, slots, .{ .position_even, .velocity });
        defer bucket.deinit();

        var context: TestMove = .{ .id = undefined };
        for ([_]u6{ 2, 1, 0 }) |index| {
            bucket.remove(@intToEnum(Index, index));
            try bucket.commit(&context);
            try testing.expectEqual(@as(u17, index), bucket.data.len);
        }

        slots +%= 1;
        if (slots == 0) break;
    }
}

test "removing entries from the middle" {
    var slots: u4 = 2;
    while (true) {
        var bucket = try testBucket(5, slots, .{ .position_even, .velocity });
        defer bucket.deinit();

        var context: TestMove = .{ .id = undefined };
        context.set(&.{});
        const expected = [_]u6{ 4, 3, 3, 4, 0 };
        for ([_]u6{ 1, 2, 0, 0, 0 }) |entry, index| {
            context.set(&.{0xffff - @as(u32, expected[index])}); // nothing moves
            bucket.remove(@intToEnum(Index, entry));
            try bucket.commit(&context);
            try testing.expectEqual(4 - index, bucket.data.len);
        }

        slots +%= 1;
        if (slots == 0) break;
    }
}

test "removing entries from the ends" {
    var slots: u4 = 2;
    while (true) {
        var bucket = try testBucket(5, slots, .{ .position_even, .velocity });
        defer bucket.deinit();

        var context: TestMove = .{ .id = undefined };
        context.set(&.{ 0xffff - 3, 0xffff - 2 });
        bucket.remove(@intToEnum(Index, 0));
        bucket.remove(@intToEnum(Index, 4));
        try bucket.commit(&context);
        try testing.expectEqual(@as(u17, 3), bucket.data.len);

        context.set(&.{ 0xffff - 1, 0xffff - 2 });
        bucket.remove(@intToEnum(Index, 0));
        bucket.remove(@intToEnum(Index, 2));
        try bucket.commit(&context);
        try testing.expectEqual(@as(u17, 1), bucket.data.len);

        context.set(&.{});
        bucket.remove(@intToEnum(Index, 0));
        try bucket.commit(&context);
        try testing.expectEqual(@as(u17, 0), bucket.data.len);

        slots +%= 1;
        if (slots == 0) break;
    }
}

/// Calculate the size of a chunk for a given archetype
pub fn chunkSize(archetype: *const Archetype, chunk_slots: u4) usize {
    const slots = @as(u16, 1) << chunk_slots;
    var it = archetype.iterator();

    var bytes: usize = 0;

    while (it.next()) |tag| {
        const index = @enumToInt(tag);
        bytes += @as(usize, Archetype.size[index]) * slots;
        assert(Archetype.alignment[index] <= slots); // padding required
    }

    return bytes + @sizeOf(Data.Entity) * @as(usize, slots);
}

/// Returns a slice of component memory within a chunk used to
/// compute the direct pointer to a component array.
pub fn block(self: *const Bucket, chunk: u16) []u8 {
    const slots = @as(u16, 1) << self.data.slots;
    const start = self.data.size * @as(usize, chunk);
    const end = start + self.data.size - @sizeOf(Data.Entity) * @as(usize, slots);
    return self.bytes[start..end];
}

/// `nodes` return a slice of the entity ID array with each element
/// interpreted as a node in the free list.
fn nodes(self: *const Bucket, index: u16) []Free.Node {
    const es = self.entities(index);
    return @ptrCast([*]Free.Node, es.ptr)[0..es.len];
}

/// `entities` returns a slice of the entity ID array for the given
/// chunk index.
pub fn entities(self: *const Bucket, chunk: u16) []Data.Entity {
    const slots = @as(u16, 1) << self.data.slots;
    const offset = //
        self.data.size * chunk +
        (self.data.size - @sizeOf(Data.Entity) * @as(usize, self.data.slots));

    const len = blk: {
        const len = self.data.len - (@as(usize, chunk) << self.data.slots);
        break :blk if (len >= slots) slots else len;
    };

    return @ptrCast([*]Data.Entity, self.bytes + offset)[0..len];
}
