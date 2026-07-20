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
    growth_habit_id: u32,
    absolute_maximum_temperature: f32,
    absolute_minimum_temperature: f32,
    optimum_maximum_temperature: f32,
    optimum_minimum_temperature: f32,
};

const ScoreAccumulator = struct {
    score_sum: f64 = 0,
    score_count: u64 = 0,
};

const Result = struct { crop_name_id: u32, township_id: u32, temperature_score: f32 };

pub fn run(allocator: std.mem.Allocator, io: std.Io, input_root_path: []const u8, output_root_path: []const u8) !void {
    const input_paths = paths_mod.Paths.init(input_root_path);
    const output_paths = paths_mod.Paths.init(output_root_path);
    const hourly_txt = try input_paths.join(allocator, &.{"historical_hourly_temperature_by_township_day_hour.txt"});
    defer allocator.free(hourly_txt);
    const other_days_txt = try input_paths.join(allocator, &.{"temperature_suitability_days_for_non_winter_crops.txt"});
    defer allocator.free(other_days_txt);
    const winter_days_txt = try input_paths.join(allocator, &.{"temperature_suitability_days_for_winter_crops.txt"});
    defer allocator.free(winter_days_txt);
    const crop_txt = try input_paths.join(allocator, &.{"crop_suitability_requirements.txt"});
    defer allocator.free(crop_txt);
    const daily_txt = try input_paths.join(allocator, &.{"historical_daily_temperature_normals_by_township.txt"});
    defer allocator.free(daily_txt);
    const output_path = try output_paths.join(allocator, &.{"temperature_suitability_scores_by_crop_township.txt"});
    defer allocator.free(output_path);

    const hourly_path = try paths_mod.existingInputPath(allocator, io, hourly_txt);
    defer allocator.free(hourly_path);
    const other_days_path = try paths_mod.existingInputPath(allocator, io, other_days_txt);
    defer allocator.free(other_days_path);
    const winter_days_path = try paths_mod.existingInputPath(allocator, io, winter_days_txt);
    defer allocator.free(winter_days_path);
    const crop_path = try paths_mod.existingInputPath(allocator, io, crop_txt);
    defer allocator.free(crop_path);
    const daily_path = try paths_mod.existingInputPath(allocator, io, daily_txt);
    defer allocator.free(daily_path);

    try runWithPaths(allocator, io, hourly_path, other_days_path, winter_days_path, crop_path, daily_path, output_path);
}

pub fn runWithPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    hourly_path: []const u8,
    other_days_path: []const u8,
    winter_days_path: []const u8,
    crop_path: []const u8,
    daily_path: []const u8,
    output_path: []const u8,
) !void {
    var strings = array_store.StringInterner.init(allocator);
    defer strings.deinit();
    const crops = try loadCropTemperatures(allocator, io, &strings, crop_path);
    defer allocator.free(crops);
    var crop_index_by_name_id = std.AutoHashMap(u32, usize).init(allocator);
    defer crop_index_by_name_id.deinit();
    for (crops, 0..) |crop, crop_index| {
        try crop_index_by_name_id.put(crop.crop_name_id, @intCast(crop_index));
    }

    var crop_mask_by_township_day = std.AutoHashMap(u64, []u64).init(allocator);
    defer {
        var masks = crop_mask_by_township_day.valueIterator();
        while (masks.next()) |mask| allocator.free(mask.*);
        crop_mask_by_township_day.deinit();
    }
    const crops_with_days = try allocator.alloc(bool, crops.len);
    defer allocator.free(crops_with_days);
    @memset(crops_with_days, false);
    try loadCropDayMasks(allocator, io, &strings, crop_index_by_name_id, crops.len, crops_with_days, &crop_mask_by_township_day, other_days_path);
    try loadCropDayMasks(allocator, io, &strings, crop_index_by_name_id, crops.len, crops_with_days, &crop_mask_by_township_day, winter_days_path);
    try loadMissingCropDayMasks(allocator, io, &strings, crops, crops_with_days, &crop_mask_by_township_day, daily_path);

    var score_by_crop_township = std.AutoHashMap(u64, ScoreAccumulator).init(allocator);
    defer score_by_crop_township.deinit();
    try streamHourlyScores(allocator, io, &strings, crops, crop_mask_by_township_day, &score_by_crop_township, hourly_path);
    try writeTemperatureScores(allocator, io, strings, score_by_crop_township, output_path);
}

pub fn addToFinalAccumulator(allocator: std.mem.Allocator, io: std.Io, input_root_path: []const u8, final_scores: *final_rating.Accumulator) !void {
    const input_paths = paths_mod.Paths.init(input_root_path);
    const hourly_txt = try input_paths.join(allocator, &.{"historical_hourly_temperature_by_township_day_hour.txt"});
    defer allocator.free(hourly_txt);
    const other_days_txt = try input_paths.join(allocator, &.{"temperature_suitability_days_for_non_winter_crops.txt"});
    defer allocator.free(other_days_txt);
    const winter_days_txt = try input_paths.join(allocator, &.{"temperature_suitability_days_for_winter_crops.txt"});
    defer allocator.free(winter_days_txt);
    const crop_txt = try input_paths.join(allocator, &.{"crop_suitability_requirements.txt"});
    defer allocator.free(crop_txt);
    const daily_txt = try input_paths.join(allocator, &.{"historical_daily_temperature_normals_by_township.txt"});
    defer allocator.free(daily_txt);

    const hourly_path = try paths_mod.existingInputPath(allocator, io, hourly_txt);
    defer allocator.free(hourly_path);
    const other_days_path = try paths_mod.existingInputPath(allocator, io, other_days_txt);
    defer allocator.free(other_days_path);
    const winter_days_path = try paths_mod.existingInputPath(allocator, io, winter_days_txt);
    defer allocator.free(winter_days_path);
    const crop_path = try paths_mod.existingInputPath(allocator, io, crop_txt);
    defer allocator.free(crop_path);
    const daily_path = try paths_mod.existingInputPath(allocator, io, daily_txt);
    defer allocator.free(daily_path);

    var strings = array_store.StringInterner.init(allocator);
    defer strings.deinit();
    const crops = try loadCropTemperatures(allocator, io, &strings, crop_path);
    defer allocator.free(crops);
    var crop_index_by_name_id = std.AutoHashMap(u32, usize).init(allocator);
    defer crop_index_by_name_id.deinit();
    for (crops, 0..) |crop, crop_index| {
        try crop_index_by_name_id.put(crop.crop_name_id, @intCast(crop_index));
    }

    var crop_mask_by_township_day = std.AutoHashMap(u64, []u64).init(allocator);
    defer {
        var masks = crop_mask_by_township_day.valueIterator();
        while (masks.next()) |mask| allocator.free(mask.*);
        crop_mask_by_township_day.deinit();
    }
    const crops_with_days = try allocator.alloc(bool, crops.len);
    defer allocator.free(crops_with_days);
    @memset(crops_with_days, false);
    try loadCropDayMasks(allocator, io, &strings, crop_index_by_name_id, crops.len, crops_with_days, &crop_mask_by_township_day, other_days_path);
    try loadCropDayMasks(allocator, io, &strings, crop_index_by_name_id, crops.len, crops_with_days, &crop_mask_by_township_day, winter_days_path);
    try loadMissingCropDayMasks(allocator, io, &strings, crops, crops_with_days, &crop_mask_by_township_day, daily_path);

    var score_by_crop_township = std.AutoHashMap(u64, ScoreAccumulator).init(allocator);
    defer score_by_crop_township.deinit();
    try streamHourlyScores(allocator, io, &strings, crops, crop_mask_by_township_day, &score_by_crop_township, hourly_path);

    var it = score_by_crop_township.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.score_count == 0) continue;
        const ids = unpackCropTownship(entry.key_ptr.*);
        const mean_score = entry.value_ptr.score_sum / @as(f64, @floatFromInt(entry.value_ptr.score_count));
        try final_scores.addScore(
            strings.get(ids.crop_name_id),
            strings.get(ids.township_id),
            .temperature,
            math.roundToOneDecimal(@floatCast(mean_score)),
        );
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
        try crops.append(allocator, .{
            .crop_name_id = try strings.intern(try row.cell(crop_i)),
            .growth_habit_id = try strings.intern(try row.cell(habit_i)),
            .absolute_maximum_temperature = try std.fmt.parseFloat(f32, try row.cell(abs_max_i)),
            .absolute_minimum_temperature = try std.fmt.parseFloat(f32, try row.cell(abs_min_i)),
            .optimum_maximum_temperature = try std.fmt.parseFloat(f32, try row.cell(opt_max_i)),
            .optimum_minimum_temperature = try std.fmt.parseFloat(f32, try row.cell(opt_min_i)),
        });
    }
    return crops.toOwnedSlice(allocator);
}

fn loadCropDayMasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    strings: *array_store.StringInterner,
    crop_index_by_name_id: std.AutoHashMap(u32, usize),
    crop_count: usize,
    crops_with_days: []bool,
    crop_mask_by_township_day: *std.AutoHashMap(u64, []u64),
    path: []const u8,
) !void {
    var reader = try stream_reader_mod.Reader.open(allocator, io, path);
    defer reader.close();
    const crop_i = try reader.columnIndex("crop_common_name");
    const township_i = try reader.columnIndex("township_id");
    const jd_i = try reader.columnIndex("julian_day");

    while (try reader.nextLine()) |line| {
        const crop_name_id = try strings.intern(try reader.cell(line, crop_i));
        const crop_index = crop_index_by_name_id.get(crop_name_id) orelse continue;
        crops_with_days[crop_index] = true;
        const township_id = try strings.intern(try reader.cell(line, township_i));
        const julian_day = try std.fmt.parseInt(u32, try reader.cell(line, jd_i), 10);
        const day_key = packTownshipDay(township_id, julian_day);
        const entry = try crop_mask_by_township_day.getOrPut(day_key);
        if (!entry.found_existing) {
            entry.value_ptr.* = try allocator.alloc(u64, (crop_count + 63) / 64);
            @memset(entry.value_ptr.*, 0);
        }
        entry.value_ptr.*[crop_index / 64] |= @as(u64, 1) << @intCast(crop_index % 64);
    }
}

fn loadMissingCropDayMasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    strings: *array_store.StringInterner,
    crops: []const CropTemperature,
    crops_with_days: []const bool,
    crop_mask_by_township_day: *std.AutoHashMap(u64, []u64),
    path: []const u8,
) !void {
    if (std.mem.allEqual(bool, crops_with_days, true)) return;

    var reader = try stream_reader_mod.Reader.open(allocator, io, path);
    defer reader.close();
    const township_i = try reader.columnIndex("township_id");
    const jd_i = try reader.columnIndex("julian_day");
    const max_i = try reader.columnIndex("maximum_temperature_quantile_75_celsius");
    const min_i = try reader.columnIndex("minimum_temperature_quantile_25_celsius");
    const started = try allocator.alloc(bool, crops.len);
    defer allocator.free(started);
    @memset(started, false);
    var previous_township_id: ?u32 = null;

    while (try reader.nextLine()) |line| {
        const township_id = try strings.intern(try reader.cell(line, township_i));
        if (previous_township_id == null or previous_township_id.? != township_id) {
            @memset(started, false);
            previous_township_id = township_id;
        }
        const julian_day = try std.fmt.parseInt(u32, try reader.cell(line, jd_i), 10);
        const maximum_temperature = try std.fmt.parseFloat(f32, try reader.cell(line, max_i));
        const minimum_temperature = try std.fmt.parseFloat(f32, try reader.cell(line, min_i));

        for (crops, 0..) |crop, crop_index| {
            if (crops_with_days[crop_index]) continue;
            const is_winter_annual = std.mem.eql(u8, strings.get(crop.growth_habit_id), "Winter Annual");
            if (is_winter_annual or (maximum_temperature > crop.absolute_minimum_temperature and minimum_temperature > 0)) {
                started[crop_index] = true;
            }
            if (!started[crop_index] or minimum_temperature <= 0) continue;

            const entry = try crop_mask_by_township_day.getOrPut(packTownshipDay(township_id, julian_day));
            if (!entry.found_existing) {
                entry.value_ptr.* = try allocator.alloc(u64, (crops.len + 63) / 64);
                @memset(entry.value_ptr.*, 0);
            }
            entry.value_ptr.*[crop_index / 64] |= @as(u64, 1) << @intCast(crop_index % 64);
        }
    }
}

fn streamHourlyScores(
    allocator: std.mem.Allocator,
    io: std.Io,
    strings: *array_store.StringInterner,
    crops: []const CropTemperature,
    crop_mask_by_township_day: std.AutoHashMap(u64, []u64),
    score_by_crop_township: *std.AutoHashMap(u64, ScoreAccumulator),
    hourly_path: []const u8,
) !void {
    var reader = try stream_reader_mod.Reader.open(allocator, io, hourly_path);
    defer reader.close();
    const township_i = try reader.columnIndex("township_id");
    const jd_i = try reader.columnIndex("julian_day");
    const temp_i = try reader.columnIndex("hourly_temperature_celsius");

    while (try reader.nextLine()) |line| {
        const township_id = try strings.intern(try reader.cell(line, township_i));
        const julian_day = try std.fmt.parseInt(u32, try reader.cell(line, jd_i), 10);
        const crop_mask = crop_mask_by_township_day.get(packTownshipDay(township_id, julian_day)) orelse continue;
        const hourly_temperature = try std.fmt.parseFloat(f32, try reader.cell(line, temp_i));

        for (crop_mask, 0..) |mask_word, word_index| {
            var remaining_mask = mask_word;
            while (remaining_mask != 0) {
                const bit_index: u6 = @intCast(@ctz(remaining_mask));
                remaining_mask &= remaining_mask - 1;
                const crop = crops[word_index * 64 + bit_index];
                const score = hourlyTemperatureScore(hourly_temperature, crop);
                const key = packCropTownship(crop.crop_name_id, township_id);
                const entry = try score_by_crop_township.getOrPut(key);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                entry.value_ptr.score_sum += @floatFromInt(score);
                entry.value_ptr.score_count += 1;
            }
        }
    }
}

fn hourlyTemperatureScore(hourly_temperature: f32, crop: CropTemperature) i32 {
    if (hourly_temperature < crop.absolute_minimum_temperature) return 0;
    if (hourly_temperature < crop.optimum_minimum_temperature) return 3;
    if (hourly_temperature <= crop.optimum_maximum_temperature) return 4;
    if (hourly_temperature <= crop.absolute_maximum_temperature) return 3;
    return 0;
}

fn writeTemperatureScores(
    allocator: std.mem.Allocator,
    io: std.Io,
    strings: array_store.StringInterner,
    score_by_crop_township: std.AutoHashMap(u64, ScoreAccumulator),
    output_path: []const u8,
) !void {
    var rows: std.ArrayList(Result) = .empty;
    defer rows.deinit(allocator);
    var it = score_by_crop_township.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.score_count == 0) continue;
        const ids = unpackCropTownship(entry.key_ptr.*);
        const mean_score = entry.value_ptr.score_sum / @as(f64, @floatFromInt(entry.value_ptr.score_count));
        try rows.append(allocator, .{
            .crop_name_id = ids.crop_name_id,
            .township_id = ids.township_id,
            .temperature_score = math.roundToOneDecimal(@floatCast(mean_score)),
        });
    }
    std.mem.sort(Result, rows.items, {}, sortRows);
    var output = writer_mod.Writer.create(allocator, io, output_path);
    defer output.close();
    try output.writeAll("crop_common_name\ttownship_id\ttemperature_suitability_score\n");
    for (rows.items) |row| {
        try output.print("{s}\t{s}\t{d:.1}\n", .{ strings.get(row.crop_name_id), strings.get(row.township_id), row.temperature_score });
    }
    try output.flush();
}

fn packTownshipDay(township_id: u32, julian_day: u32) u64 {
    return packed_key.pack(township_id, julian_day);
}

fn packCropTownship(crop_name_id: u32, township_id: u32) u64 {
    return packed_key.pack(crop_name_id, township_id);
}

fn unpackCropTownship(value: u64) struct { crop_name_id: u32, township_id: u32 } {
    const unpacked = packed_key.unpack(value);
    return .{ .crop_name_id = unpacked.first, .township_id = unpacked.second };
}

fn sortRows(_: void, a: Result, b: Result) bool {
    if (a.crop_name_id == b.crop_name_id) return a.township_id < b.township_id;
    return a.crop_name_id < b.crop_name_id;
}
