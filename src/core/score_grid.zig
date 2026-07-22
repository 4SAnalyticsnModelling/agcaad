const std = @import("std");

pub const ScoreGrid = struct {
    allocator: std.mem.Allocator,
    crop_count: usize,
    township_ids: std.ArrayList(u32) = .empty,
    township_index_by_id: std.AutoHashMap(u32, usize),
    values: []f32,

    pub fn init(allocator: std.mem.Allocator, crop_count: usize, source_township_ids: []const u32) !ScoreGrid {
        var grid: ScoreGrid = .{
            .allocator = allocator,
            .crop_count = crop_count,
            .township_index_by_id = std.AutoHashMap(u32, usize).init(allocator),
            .values = &.{},
        };
        errdefer grid.deinit();
        for (source_township_ids) |township_id| {
            const entry = try grid.township_index_by_id.getOrPut(township_id);
            if (!entry.found_existing) {
                entry.value_ptr.* = grid.township_ids.items.len;
                try grid.township_ids.append(allocator, township_id);
            }
        }
        const value_count = std.math.mul(usize, crop_count, grid.township_ids.items.len) catch return error.InputTooLarge;
        grid.values = try allocator.alloc(f32, value_count);
        @memset(grid.values, 0);
        return grid;
    }

    pub fn deinit(self: *ScoreGrid) void {
        if (self.values.len != 0) self.allocator.free(self.values);
        self.township_ids.deinit(self.allocator);
        self.township_index_by_id.deinit();
    }

    pub fn add(self: *ScoreGrid, crop_index: usize, township_id: u32, value: f32) void {
        self.values[self.offset(crop_index, self.township_index_by_id.get(township_id).?)] += value;
    }

    pub fn get(self: ScoreGrid, crop_index: usize, township_index: usize) f32 {
        return self.values[self.offset(crop_index, township_index)];
    }

    fn offset(self: ScoreGrid, crop_index: usize, township_index: usize) usize {
        return crop_index * self.township_ids.items.len + township_index;
    }
};

test "dense score grid deduplicates townships and accumulates independently" {
    var grid = try ScoreGrid.init(std.testing.allocator, 2, &.{ 7, 7, 9 });
    defer grid.deinit();
    grid.add(0, 7, 1.2);
    grid.add(0, 7, 0.3);
    grid.add(1, 9, 4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), grid.get(0, 0), 0.0001);
    try std.testing.expectEqual(@as(f32, 0), grid.get(0, 1));
    try std.testing.expectEqual(@as(f32, 4), grid.get(1, 1));
}
