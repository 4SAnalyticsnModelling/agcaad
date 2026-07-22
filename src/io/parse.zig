const std = @import("std");
const builtin = @import("builtin");

pub fn integer(comptime T: type, path: []const u8, row_number: usize, column_name: []const u8, text: []const u8) !T {
    return std.fmt.parseInt(T, text, 10) catch |err| {
        if (!builtin.is_test) std.debug.print("Invalid integer in '{s}' at row {d}, column '{s}': '{s}' ({s})\n", .{ path, row_number, column_name, text, @errorName(err) });
        return error.InvalidIntegerValue;
    };
}

pub fn float(comptime T: type, path: []const u8, row_number: usize, column_name: []const u8, text: []const u8) !T {
    const value = std.fmt.parseFloat(T, text) catch |err| {
        if (!builtin.is_test) std.debug.print("Invalid number in '{s}' at row {d}, column '{s}': '{s}' ({s})\n", .{ path, row_number, column_name, text, @errorName(err) });
        return error.InvalidFloatValue;
    };
    if (!std.math.isFinite(value)) {
        if (!builtin.is_test) std.debug.print("Non-finite number in '{s}' at row {d}, column '{s}': '{s}'\n", .{ path, row_number, column_name, text });
        return error.NonFiniteValue;
    }
    return value;
}

test "rejects invalid and non-finite numeric input" {
    try std.testing.expectError(error.InvalidIntegerValue, integer(i32, "fixture.txt", 2, "count", "1.5"));
    try std.testing.expectError(error.InvalidFloatValue, float(f32, "fixture.txt", 3, "score", "bad"));
    try std.testing.expectError(error.NonFiniteValue, float(f32, "fixture.txt", 4, "score", "nan"));
    try std.testing.expectError(error.NonFiniteValue, float(f32, "fixture.txt", 5, "score", "inf"));
}
