const std = @import("std");

pub fn roundToOneDecimal(value: f32) f32 {
    return @round(value * 10.0) / 10.0;
}

pub fn roundToTwoDecimals(value: f32) f32 {
    return @round(value * 100.0) / 100.0;
}

test "rounding helpers handle positive and negative values" {
    try std.testing.expectEqual(@as(f32, 1.3), roundToOneDecimal(1.25));
    try std.testing.expectEqual(@as(f32, -1.3), roundToOneDecimal(-1.25));
    try std.testing.expectEqual(@as(f32, 1.24), roundToTwoDecimals(1.235));
}
