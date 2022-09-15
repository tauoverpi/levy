const std = @import("std");
const mem = std.mem;
const meta = std.meta;

const Type = std.builtin.Type;

bitset: Set = empty,

const Archetype = @This();
const Data = @import("Data.zig");

/// Fields in the same order as the data model but with zero-sized fields moved to
/// the end such that they can be skipped during iteration. This means that fields
/// that are close in the struct definition will be close within memory thus field
/// order can have an impact on performance.
pub const fields = blk: {
    const order = meta.fields(Data);
    var tmp = order[0..order.len].*;

    var index: u16 = 0;
    for (order) |field| {
        if (@sizeOf(field.field_type) != 0) {
            tmp[index] = field;
            index += 1;
        }
    }

    for (order) |field| {
        if (@sizeOf(field.field_type) == 0) {
            tmp[index] = field;
            index += 1;
        }
    }

    break :blk tmp;
};

pub const Int = u32;
pub const Set = [slots]u32;
pub const Shift = u5;

pub const Tag = blk: {
    var tmp: [fields.len]Type.EnumField = undefined;
    for (fields) |field, index| {
        tmp[index] = .{
            .name = field.name,
            .value = index,
        };
    }

    break :blk @Type(.{ .Enum = .{
        .layout = .Auto,
        .fields = &tmp,
        .decls = &.{},
        .is_exhaustive = true,
        .tag_type = std.math.IntFittingRange(0, tmp.len - 1),
    } });
};

pub const alignment = blk: {
    var tmp: [fields.len]u8 = undefined;
    for (fields) |field, index| {
        const max = @maximum(field.alignment, @alignOf(field.field_type));
        if (max > 64) @compileError("alignment must be less or equal to than 64 bytes");
        tmp[index] = @intCast(u8, max);
    }

    break :blk tmp;
};

pub const split = for (fields) |field, index|
{
    if (@sizeOf(field.field_type) == 0) break index;
} else fields.len;

pub const size = blk: {
    var tmp: [fields.len]u8 = undefined;
    for (fields) |field, index| {
        tmp[index] = @intCast(u8, @sizeOf(field.field_type));
    }

    break :blk tmp;
};

pub const empty = mem.zeroes(Set);
pub const slots = (fields.len >> 5) + 1;

fn bit(tag: Tag) u32 {
    return @as(Int, 1) << @truncate(Shift, @as(u32, @enumToInt(tag)));
}

fn slot(tag: Tag) u32 {
    return @as(u32, @enumToInt(tag)) >> @bitSizeOf(Shift);
}

pub fn add(set: *Archetype, tag: Tag) void {
    set.bitset[slot(tag)] |= bit(tag);
}

pub fn remove(set: *Archetype, tag: Tag) void {
    set.bitset[slot(tag)] &= ~bit(tag);
}

pub fn have(set: *const Archetype, tag: Tag) bool {
    return set.bitset[slot(tag)] & bit(tag) == bit(tag);
}

pub fn merge(set: *Archetype, other: *const Archetype) void {
    for (other.bitset) |cell, index| {
        set.bitset[index] |= cell;
    }
}

pub fn diff(set: *Archetype, other: *const Archetype) void {
    for (other.bitset) |cell, index| {
        set.bitset[index] &= ~cell;
    }
}

pub fn xor(set: *Archetype, other: *const Archetype) void {
    for (other.bitset) |cell, index| {
        set.bitset[index] ^= cell;
    }
}

pub fn count(set: *const Archetype) u16 {
    var total: u16 = 0;
    for (set.bitset) |cell| total += @popCount(cell);
    return total;
}

pub fn contains(set: *const Archetype, other: *const Archetype) bool {
    for (other.bitset) |cell, index| {
        if (set.bitset[index] & cell != cell) {
            return false;
        }
    }

    return true;
}

pub fn fromList(set: anytype) Archetype {
    var tmp: Archetype = .{ .bitset = empty };

    for (@as(*const [set.len]Tag, &set)) |tag| tmp.add(tag);

    return tmp;
}

pub fn fromType(comptime set: type) Archetype {
    comptime {
        var tmp: Archetype = .{ .bitset = empty };

        for (meta.fields(set)) |field| tmp.add(@field(Tag, field.name));

        return tmp;
    }
}

pub fn TypeOf(comptime tag: Tag) type {
    return fields[@enumToInt(tag)].field_type;
}

pub fn iterator(set: *const Archetype) Iterator {
    return .{ .type = set };
}

pub const Iterator = struct {
    type: *const Archetype,
    offset: u4 = 0,
    mask: u32 = 0,

    pub fn next(it: *Iterator) ?Tag {
        for (it.type.bitset[it.offset..]) |cell| {
            const int = @ctz(cell & ~it.mask);
            if (int != 32) {
                const index = @shlExact(@as(u32, 1), @intCast(Shift, int));

                it.mask |= index;

                const bits = @intCast(meta.Tag(Tag), 32 * @as(u32, it.offset));
                const tag = @intToEnum(Tag, int + bits);

                return tag;
            }

            it.mask = 0;
            it.offset += 1;
        }

        return null;
    }
};
