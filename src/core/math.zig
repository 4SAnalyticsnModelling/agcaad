const std = @import("std");

pub fn roundToOneDecimal(value: f32) f32 {
    return @round(value * 10.0) / 10.0;
}

pub fn roundToTwoDecimals(value: f32) f32 {
    return @round(value * 100.0) / 100.0;
}

pub fn roundToNearestInteger(value: f32) i32 {
    return @intFromFloat(@round(value));
}
