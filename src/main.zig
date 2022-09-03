const std = @import("std");

pub const Bucket = @import("Bucket.zig");
pub const Archetype = @import("Archetype.zig");
pub const Data = @import("Data.zig");
pub const Model = @import("Model.zig");

comptime {
    _ = Bucket;
    _ = Archetype;
    _ = Data;
    _ = Model;
}

pub fn main() void {}
