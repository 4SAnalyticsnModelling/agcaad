const std = @import("std");
const array_store = @import("../core/array_store.zig");
const math = @import("../core/math.zig");
const packed_key = @import("../core/packed_key.zig");
const reader_mod = @import("../io/delimited_reader.zig");
const stream_reader_mod = @import("../io/streaming_line_reader.zig");
const writer_mod = @import("../io/tab_writer.zig");
const paths_mod = @import("../paths.zig");
const final_rating = @import("../suitability/final_rating.zig");

const CropTemperature = struct {
    crop_name_id: u32,
    is_winter_annual: bool,
    absolute_maximum_temperature: f32,
    absolute_minimum_temperature: f32,
    optimum_maximum_temperature: f32,
    optimum_minimum_temperature: f32,
};

const ScoreAccumulator = struct {
    score_sum: f64 = 0,
    score_count: u64 = 0,
};

const CropDayMasks = struct {
    allocator: std.mem.Allocator,
    word_count: usize,
    words: std.ArrayList(u64) = .empty,
    offset_by_township_day: std.AutoHashMap(u64, usize),
    township_ids: std.ArrayList(u32) = .empty,
    township_index_by_id: std.AutoHashMap(u32, usize),

    fn init(allocator: std.mem.Allocator, crop_count: usize) !CropDayMasks {
        const padded_count = std.math.add(usize, crop_count, 63) catch return error.InputTooLarge;
        return .{
            .allocator = allocator,
            .word_count = padded_count / 64,
            .offset_by_township_day = std.AutoHashMap(u64, usize).init(allocator),
            .township_index_by_id = std.AutoHashMap(u32, usize).init(allocator),
        };
    }

    fn deinit(self: *CropDayMasks) void {
        self.words.deinit(self.allocator);
        self.offset_by_township_day.deinit();
        self.township_ids.deinit(self.allocator);
        self.township_index_by_id.deinit();
    }

    fn getOrCreate(self: *CropDayMasks, key: u64) ![]u64 {
        const entry = try self.offset_by_township_day.getOrPut(key);
        if (!entry.found_existing) {
            entry.value_ptr.* = self.words.items.len;
            try self.words.appendNTimes(self.allocator, 0, self.word_count);
        }
        return self.words.items[entry.value_ptr.*..][0..self.word_count];
    }

    fn get(self: CropDayMasks, key: u64) ?[]const u64 {
        const offset = self.offset_by_township_day.get(key) orelse return null;
        return self.words.items[offset..][0..self.word_count];
    }

    fn ensureTownship(self: *CropDayMasks, township_id: u32) !usize {
        const entry = try self.township_index_by_id.getOrPut(township_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = self.township_ids.items.len;
            try self.township_ids.append(self.allocator, township_id);
        }
        return entry.value_ptr.*;
    }

    fn townshipIndex(self: CropDayMasks, township_id: u32) ?usize {
        return self.township_index_by_id.get(township_id);
    }
};

const ScoreGrid = struct {
    allocator: std.mem.Allocator,
    township_count: usize,
    values: []ScoreAccumulator,

    fn init(allocator: std.mem.Allocator, crop_count: usize, township_count: usize) !ScoreGrid {
        const value_count = std.math.mul(usize, crop_count, township_count) catch return error.InputTooLarge;
        const values = try allocator.alloc(ScoreAccumulator, value_count);
        @memset(values, .{});
        return .{ .allocator = allocator, .township_count = township_count, .values = values };
    }

    fn deinit(self: ScoreGrid) void {
        self.allocator.free(self.values);
    }

    fn get(self: ScoreGrid, crop_index: usize, township_index: usize) *ScoreAccumulator {
        return &self.values[crop_index * self.township_count + township_index];
    }
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, input_root_path: []const u8, output_root_path: []const u8) !void {
    const input_paths = paths_mod.Paths.init(input_root_path);
    const output_paths = paths_mod.Paths.init(output_root_path);
    const hourly_txt = try input_paths.join(allocator, &.{"historical_hourly_temperature_by_township_day_hour.txt"});
    defer allocator.free(hourly_txt);
    const crop_txt = try input_paths.join(allocator, &.{"crop_suitability_requirements.txt"});
    defer allocator.free(crop_txt);
    const daily_txt = try input_paths.join(allocator, &.{"historical_daily_temperature_normals_by_township.txt"});
    defer allocator.free(daily_txt);
    const output_path = try output_paths.join(allocator, &.{"temperature_suitability_scores_by_crop_township.txt"});
    defer allocator.free(output_path);

    const hourly_path = try paths_mod.existingInputPath(allocator, io, hourly_txt);
    defer allocator.free(hourly_path);
    const crop_path = try paths_mod.existingInputPath(allocator, io, crop_txt);
    defer allocator.free(crop_path);
    const daily_path = try paths_mod.existingInputPath(allocator, io, daily_txt);
    defer allocator.free(daily_path);

    try runWithPaths(allocator, io, hourly_path, crop_path, daily_path, output_path);
}

pub fn runWithPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    hourly_path: []const u8,
    crop_path: []const u8,
    daily_path: []const u8,
    output_path: []const u8,
) !void {
    var strings = array_store.StringInterner.init(allocator);
    defer strings.deinit();
    const crops = try loadCropTemperatures(allocator, io, &strings, crop_path);
    defer allocator.free(crops);
    var crop_mask_by_township_day = try CropDayMasks.init(allocator, crops.len);
    defer crop_mask_by_township_day.deinit();
    try loadCropDayMasks(allocator, io, &strings, crops, &crop_mask_by_township_day, daily_path);

    var scores = try ScoreGrid.init(allocator, crops.len, crop_mask_by_township_day.township_ids.items.len);
    defer scores.deinit();
    try streamHourlyScores(allocator, io, &strings, crops, crop_mask_by_township_day, scores, hourly_path);
    try writeTemperatureScores(allocator, io, strings, crops, crop_mask_by_township_day.township_ids.items, scores, output_path);
}

pub fn addToFinalAccumulator(allocator: std.mem.Allocator, io: std.Io, input_root_path: []const u8, final_scores: *final_rating.Accumulator) !void {
    const input_paths = paths_mod.Paths.init(input_root_path);
    const hourly_txt = try input_paths.join(allocator, &.{"historical_hourly_temperature_by_township_day_hour.txt"});
    defer allocator.free(hourly_txt);
    const crop_txt = try input_paths.join(allocator, &.{"crop_suitability_requirements.txt"});
    defer allocator.free(crop_txt);
    const daily_txt = try input_paths.join(allocator, &.{"historical_daily_temperature_normals_by_township.txt"});
    defer allocator.free(daily_txt);

    const hourly_path = try paths_mod.existingInputPath(allocator, io, hourly_txt);
    defer allocator.free(hourly_path);
    const crop_path = try paths_mod.existingInputPath(allocator, io, crop_txt);
    defer allocator.free(crop_path);
    const daily_path = try paths_mod.existingInputPath(allocator, io, daily_txt);
    defer allocator.free(daily_path);

    var strings = array_store.StringInterner.init(allocator);
    defer strings.deinit();
    const crops = try loadCropTemperatures(allocator, io, &strings, crop_path);
    defer allocator.free(crops);
    var crop_mask_by_township_day = try CropDayMasks.init(allocator, crops.len);
    defer crop_mask_by_township_day.deinit();
    try loadCropDayMasks(allocator, io, &strings, crops, &crop_mask_by_township_day, daily_path);

    var scores = try ScoreGrid.init(allocator, crops.len, crop_mask_by_township_day.township_ids.items.len);
    defer scores.deinit();
    try streamHourlyScores(allocator, io, &strings, crops, crop_mask_by_township_day, scores, hourly_path);

    for (crops, 0..) |crop, crop_index| {
        for (crop_mask_by_township_day.township_ids.items, 0..) |township_id, township_index| {
            const score = scores.get(crop_index, township_index);
            if (score.score_count == 0) continue;
            const mean_score = score.score_sum / @as(f64, @floatFromInt(score.score_count));
            try final_scores.addScore(strings.get(crop.crop_name_id), strings.get(township_id), .temperature, math.roundToOneDecimal(@floatCast(mean_score)));
        }
    }
}

fn loadCropTemperatures(allocator: std.mem.Allocator, io: std.Io, strings: *array_store.StringInterner, path: []const u8) ![]CropTemperature {
    var reader = try reader_mod.Reader.open(allocator, io, path);
    defer reader.close();
    const crop_i = try reader.header.columnIndex("crop_common_name");
    const habit_i = try reader.header.columnIndex("growth_habit");
    const abs_max_i = try reader.header.columnIndex("absolute_maximum_temperature_celsius");
    const abs_min_i = try reader.header.columnIndex("absolute_minimum_temperature_celsius");
    const opt_max_i = try reader.header.columnIndex("optimum_maximum_temperature_celsius");
    const opt_min_i = try reader.header.columnIndex("optimum_minimum_temperature_celsius");
    var crops: std.ArrayList(CropTemperature) = .empty;
    errdefer crops.deinit(allocator);
    while (reader.nextRow()) |row| {
        const absolute_maximum = try row.floatCell(f32, abs_max_i, "absolute_maximum_temperature_celsius");
        const absolute_minimum = try row.floatCell(f32, abs_min_i, "absolute_minimum_temperature_celsius");
        const optimum_maximum = try row.floatCell(f32, opt_max_i, "optimum_maximum_temperature_celsius");
        const optimum_minimum = try row.floatCell(f32, opt_min_i, "optimum_minimum_temperature_celsius");
        if (!(absolute_minimum <= optimum_minimum and optimum_minimum <= optimum_maximum and optimum_maximum <= absolute_maximum)) {
            std.debug.print("Invalid temperature thresholds in '{s}' at row {d}: expected absolute_minimum <= optimum_minimum <= optimum_maximum <= absolute_maximum\n", .{ row.path, row.row_number });
            return error.InvalidTemperatureRange;
        }
        try crops.append(allocator, .{
            .crop_name_id = try strings.intern(try row.cell(crop_i)),
            .is_winter_annual = std.mem.eql(u8, try row.cell(habit_i), "Winter Annual"),
            .absolute_maximum_temperature = absolute_maximum,
            .absolute_minimum_temperature = absolute_minimum,
            .optimum_maximum_temperature = optimum_maximum,
            .optimum_minimum_temperature = optimum_minimum,
        });
    }
    return crops.toOwnedSlice(allocator);
}

fn loadCropDayMasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    strings: *array_store.StringInterner,
    crops: []const CropTemperature,
    crop_mask_by_township_day: *CropDayMasks,
    path: []const u8,
) !void {
    var reader = try stream_reader_mod.Reader.open(allocator, io, path);
    defer reader.close();
    const township_i = try reader.columnIndex("township_id");
    const jd_i = try reader.columnIndex("julian_day");
    const max_25_i = try reader.columnIndex("maximum_temperature_quantile_25_celsius");
    const max_75_i = try reader.columnIndex("maximum_temperature_quantile_75_celsius");
    const min_i = try reader.columnIndex("minimum_temperature_quantile_25_celsius");
    // 0=not started, 1=active, 2=ended. Winter crops reuse these as
    // dormant/spring-active/harvested before midyear and waiting/active/ended
    // after midyear.
    const states = try allocator.alloc(u2, crops.len);
    defer allocator.free(states);
    @memset(states, 0);
    var previous_township_id: ?u32 = null;
    const parse = @import("../io/parse.zig");

    while (try reader.nextLine()) |line| {
        const fields = try reader.projectCells(5, line, .{ township_i, jd_i, max_25_i, max_75_i, min_i });
        const township_id = if (previous_township_id) |previous_id|
            if (std.mem.eql(u8, fields[0], strings.get(previous_id))) previous_id else try strings.intern(fields[0])
        else
            try strings.intern(fields[0]);
        if (previous_township_id == null or previous_township_id.? != township_id) {
            @memset(states, 0);
            previous_township_id = township_id;
            _ = try crop_mask_by_township_day.ensureTownship(township_id);
        }
        const julian_day = try parse.integer(u32, path, reader.row_number, "julian_day", fields[1]);
        const maximum_25 = try parse.float(f32, path, reader.row_number, "maximum_temperature_quantile_25_celsius", fields[2]);
        const maximum_75 = try parse.float(f32, path, reader.row_number, "maximum_temperature_quantile_75_celsius", fields[3]);
        const minimum_25 = try parse.float(f32, path, reader.row_number, "minimum_temperature_quantile_25_celsius", fields[4]);
        for (crops, 0..) |crop, crop_index| {
            const active = if (crop.is_winter_annual)
                winterAnnualDayIsActive(&states[crop_index], julian_day, maximum_25, maximum_75, minimum_25, crop)
            else
                annualDayIsActive(&states[crop_index], julian_day, maximum_75, minimum_25, crop.absolute_minimum_temperature);
            if (!active) continue;

            const mask = try crop_mask_by_township_day.getOrCreate(packTownshipDay(township_id, julian_day));
            mask[crop_index / 64] |= @as(u64, 1) << @intCast(crop_index % 64);
        }
    }
}

fn annualDayIsActive(state: *u2, julian_day: u32, maximum_75: f32, minimum_25: f32, absolute_minimum: f32) bool {
    if (state.* == 2) return false;
    const suitable = maximum_75 > absolute_minimum and minimum_25 > 0;
    if (state.* == 0) {
        if (!suitable) return false;
        state.* = 1;
    } else if (!suitable) {
        // Ignore short winter warm spells; only a failure after midyear closes
        // the crop's continuous frost-free growing period.
        state.* = if (julian_day <= 183) 0 else 2;
        return false;
    }
    return true;
}

fn winterAnnualDayIsActive(state: *u2, julian_day: u32, maximum_25: f32, maximum_75: f32, minimum_25: f32, crop: CropTemperature) bool {
    // Appendix D pp. 12-13: spring growth begins only after both dormancy-end
    // tests pass and ends at the 3-in-4 optimum-maximum harvest threshold.
    // Fall growth begins after the 1-in-4 planting threshold and ends when
    // either dormancy-start test is met.
    if (julian_day <= 183) {
        if (state.* == 2) return false;
        if (state.* == 0) {
            if (maximum_25 <= crop.absolute_minimum_temperature or minimum_25 <= 0) return false;
            state.* = 1;
        }
        if (maximum_25 > crop.optimum_maximum_temperature) {
            state.* = 2;
            return false;
        }
        return true;
    }
    if (julian_day == 184) state.* = 0;
    if (state.* == 2) return false;
    if (state.* == 0) {
        if (maximum_75 > crop.optimum_maximum_temperature) return false;
        state.* = 1;
    }
    if (maximum_75 <= crop.absolute_minimum_temperature or minimum_25 < 0) {
        state.* = 2;
        return false;
    }
    return true;
}

fn streamHourlyScores(
    allocator: std.mem.Allocator,
    io: std.Io,
    strings: *array_store.StringInterner,
    crops: []const CropTemperature,
    crop_mask_by_township_day: CropDayMasks,
    scores: ScoreGrid,
    hourly_path: []const u8,
) !void {
    var reader = try stream_reader_mod.Reader.open(allocator, io, hourly_path);
    defer reader.close();
    const township_i = try reader.columnIndex("township_id");
    const jd_i = try reader.columnIndex("julian_day");
    const temp_i = try reader.columnIndex("hourly_temperature_celsius");
    const parse = @import("../io/parse.zig");
    var previous_township_id: ?u32 = null;
    var previous_township_index: usize = undefined;

    while (try reader.nextLine()) |line| {
        const fields = try reader.projectCells(3, line, .{ township_i, jd_i, temp_i });
        var township_id: u32 = undefined;
        var township_index: usize = undefined;
        if (previous_township_id) |previous_id| {
            if (std.mem.eql(u8, fields[0], strings.get(previous_id))) {
                township_id = previous_id;
                township_index = previous_township_index;
            } else {
                township_id = try strings.intern(fields[0]);
                township_index = crop_mask_by_township_day.townshipIndex(township_id) orelse {
                    std.debug.print("Hourly temperature township '{s}' in '{s}' at row {d} has no daily-temperature record\n", .{ fields[0], hourly_path, reader.row_number });
                    return error.MissingDailyTemperature;
                };
                previous_township_id = township_id;
                previous_township_index = township_index;
            }
        } else {
            township_id = try strings.intern(fields[0]);
            township_index = crop_mask_by_township_day.townshipIndex(township_id) orelse {
                std.debug.print("Hourly temperature township '{s}' in '{s}' at row {d} has no daily-temperature record\n", .{ fields[0], hourly_path, reader.row_number });
                return error.MissingDailyTemperature;
            };
            previous_township_id = township_id;
            previous_township_index = township_index;
        }
        const julian_day = try parse.integer(u32, hourly_path, reader.row_number, "julian_day", fields[1]);
        const crop_mask = crop_mask_by_township_day.get(packTownshipDay(township_id, julian_day)) orelse continue;
        const hourly_temperature = try parse.float(f32, hourly_path, reader.row_number, "hourly_temperature_celsius", fields[2]);

        for (crop_mask, 0..) |mask_word, word_index| {
            var remaining_mask = mask_word;
            while (remaining_mask != 0) {
                const bit_index: u6 = @intCast(@ctz(remaining_mask));
                remaining_mask &= remaining_mask - 1;
                const crop_index = word_index * 64 + bit_index;
                const crop = crops[crop_index];
                const score = hourlyTemperatureScore(hourly_temperature, crop);
                const accumulator = scores.get(crop_index, township_index);
                accumulator.score_sum += @floatFromInt(score);
                accumulator.score_count += 1;
            }
        }
    }
}

fn hourlyTemperatureScore(hourly_temperature: f32, crop: CropTemperature) i32 {
    if (hourly_temperature < crop.absolute_minimum_temperature) return 0;
    if (hourly_temperature < crop.optimum_minimum_temperature) return 3;
    // Appendix D, equation 2: the optimum hourly-temperature class scores 5.
    if (hourly_temperature <= crop.optimum_maximum_temperature) return 5;
    if (hourly_temperature <= crop.absolute_maximum_temperature) return 3;
    return 0;
}

fn writeTemperatureScores(
    allocator: std.mem.Allocator,
    io: std.Io,
    strings: array_store.StringInterner,
    crops: []const CropTemperature,
    township_ids: []const u32,
    scores: ScoreGrid,
    output_path: []const u8,
) !void {
    var output = try writer_mod.Writer.create(allocator, io, output_path);
    defer output.close();
    try output.writeAll("crop_common_name\ttownship_id\ttemperature_suitability_score\n");
    for (crops, 0..) |crop, crop_index| {
        for (township_ids, 0..) |township_id, township_index| {
            const score = scores.get(crop_index, township_index);
            if (score.score_count == 0) continue;
            const mean_score = score.score_sum / @as(f64, @floatFromInt(score.score_count));
            try output.print("{s}\t{s}\t{d:.1}\n", .{ strings.get(crop.crop_name_id), strings.get(township_id), math.roundToOneDecimal(@floatCast(mean_score)) });
        }
    }
    try output.flush();
}

fn packTownshipDay(township_id: u32, julian_day: u32) u64 {
    return packed_key.pack(township_id, julian_day);
}

test "example-derived onion hourly temperature scoring" {
    const onion: CropTemperature = .{
        .crop_name_id = 0,
        .is_winter_annual = false,
        .absolute_maximum_temperature = 29,
        .absolute_minimum_temperature = 7,
        .optimum_maximum_temperature = 24,
        .optimum_minimum_temperature = 12,
    };
    try std.testing.expectEqual(@as(i32, 0), hourlyTemperatureScore(6.9, onion));
    try std.testing.expectEqual(@as(i32, 3), hourlyTemperatureScore(10, onion));
    try std.testing.expectEqual(@as(i32, 5), hourlyTemperatureScore(20, onion));
    try std.testing.expectEqual(@as(i32, 0), hourlyTemperatureScore(30, onion));
}

test "annual active period ignores winter thaw and closes in fall" {
    const onion: CropTemperature = .{ .crop_name_id = 0, .is_winter_annual = false, .absolute_maximum_temperature = 29, .absolute_minimum_temperature = 7, .optimum_maximum_temperature = 24, .optimum_minimum_temperature = 12 };
    var state: u2 = 0;
    try std.testing.expect(annualDayIsActive(&state, 20, 8, 1, onion.absolute_minimum_temperature));
    try std.testing.expect(!annualDayIsActive(&state, 21, 6, -1, onion.absolute_minimum_temperature));
    try std.testing.expectEqual(@as(u2, 0), state);
    try std.testing.expect(annualDayIsActive(&state, 120, 15, 5, onion.absolute_minimum_temperature));
    try std.testing.expect(!annualDayIsActive(&state, 250, 6, 4, onion.absolute_minimum_temperature));
    try std.testing.expectEqual(@as(u2, 2), state);
    try std.testing.expect(!annualDayIsActive(&state, 251, 15, 5, onion.absolute_minimum_temperature));
}

test "dense score grid and township mask indexes remain independent" {
    const allocator = std.testing.allocator;
    var grid = try ScoreGrid.init(allocator, 2, 3);
    defer grid.deinit();
    grid.get(0, 2).score_sum = 4;
    grid.get(0, 2).score_count = 1;
    grid.get(1, 0).score_sum = 3;
    grid.get(1, 0).score_count = 1;
    try std.testing.expectEqual(@as(f64, 4), grid.get(0, 2).score_sum);
    try std.testing.expectEqual(@as(f64, 3), grid.get(1, 0).score_sum);
    try std.testing.expectEqual(@as(u64, 0), grid.get(0, 0).score_count);

    var masks = try CropDayMasks.init(allocator, 140);
    defer masks.deinit();
    try std.testing.expectEqual(@as(usize, 0), try masks.ensureTownship(42));
    try std.testing.expectEqual(@as(usize, 0), try masks.ensureTownship(42));
    try std.testing.expectEqual(@as(usize, 1), try masks.ensureTownship(99));
    const mask = try masks.getOrCreate(packTownshipDay(42, 120));
    mask[2] = 1;
    try std.testing.expectEqual(@as(u64, 1), masks.get(packTownshipDay(42, 120)).?[2]);
}
