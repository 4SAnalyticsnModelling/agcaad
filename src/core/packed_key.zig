pub const Pair = struct {
    first: u32,
    second: u32,
};

pub fn pack(first: u32, second: u32) u64 {
    return (@as(u64, first) << 32) | @as(u64, second);
}

pub fn unpack(value: u64) Pair {
    return .{
        .first = @intCast(value >> 32),
        .second = @intCast(value & 0xffffffff),
    };
}

test "packed keys preserve both full-width identifiers" {
    const first = std.math.maxInt(u32);
    const second: u32 = 0x89abcdef;
    const value = pack(first, second);
    try std.testing.expectEqual(first, unpack(value).first);
    try std.testing.expectEqual(second, unpack(value).second);
}

const std = @import("std");
