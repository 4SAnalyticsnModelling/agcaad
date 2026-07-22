const std = @import("std");
const array_store = @import("../core/array_store.zig");

const fraction_tolerance = 0.001;

pub fn validateAreaFractions(
    allocator: std.mem.Allocator,
    strings: array_store.StringInterner,
    township_ids: []const u32,
    fractions: []const f32,
    path: []const u8,
) !void {
    if (township_ids.len != fractions.len) return error.InvalidSoilComponents;
    var sums = std.AutoHashMap(u32, f64).init(allocator);
    defer sums.deinit();
    for (township_ids, fractions) |township_id, fraction| {
        const entry = try sums.getOrPut(township_id);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += fraction;
    }
    var iterator = sums.iterator();
    while (iterator.next()) |entry| {
        if (@abs(entry.value_ptr.* - 1.0) > fraction_tolerance) {
            std.debug.print("Invalid soil component area fractions in '{s}' for township '{s}': sum is {d:.9}, expected 1.0 +/- {d}\n", .{ path, strings.get(entry.key_ptr.*), entry.value_ptr.*, fraction_tolerance });
            return error.InvalidSoilComponentFractions;
        }
    }
}

test "soil component fractions must form a complete map unit" {
    const allocator = std.testing.allocator;
    var strings = array_store.StringInterner.init(allocator);
    defer strings.deinit();
    const first = try strings.intern("T001R01W4");
    const second = try strings.intern("T002R01W4");
    try validateAreaFractions(allocator, strings, &.{ first, first, second }, &.{ 0.4, 0.6, 1.0 }, "test.txt");
    try std.testing.expectError(error.InvalidSoilComponentFractions, validateAreaFractions(allocator, strings, &.{ first, first }, &.{ 0.4, 0.5 }, "test.txt"));
}
