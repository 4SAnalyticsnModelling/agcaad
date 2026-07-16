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

pub fn high(value: u64) u32 {
    return @intCast(value >> 32);
}
