const std = @import("std");
const array_store = @import("../core/array_store.zig");
const parallel = @import("../core/parallel.zig");
const reader_mod = @import("../io/delimited_reader.zig");
const writer_mod = @import("../io/tab_writer.zig");
const paths_mod = @import("../paths.zig");
const final_rating = @import("../suitability/final_rating.zig");

const DailyNormal = struct { township_id: u32, julian_day: i32, max_temperature_quantile_75: f32, min_temperature_quantile_25: f32 };
const TownshipNormalRange = struct { township_id: u32, start: usize, end: usize };
const Crop = struct { crop_name_id: u32, is_winter_annual: bool, absolute_minimum_temperature: i32, grow_day_minimum: i32, grow_day_range: i32 };
const Accumulator = struct { previous_positive_flag_seen: bool = false, growing_season_days: i32 = 0 };
const Result = struct { crop_name_id: u32, township_id: u32, score: i32 };

pub fn run(allocator: std.mem.Allocator, io: std.Io, input_root_path: []const u8, output_root_path: []const u8) !void {
    const input_paths = paths_mod.Paths.init(input_root_path);
    const output_paths = paths_mod.Paths.init(output_root_path);
    const normals_txt = try input_paths.join(allocator, &.{"historical_daily_temperature_normals_by_township.txt"});
    defer allocator.free(normals_txt);
    const crop_txt = try input_paths.join(allocator, &.{"crop_suitability_requirements.txt"});
    defer allocator.free(crop_txt);
    const output_path = try output_paths.join(allocator, &.{"growing_season_suitability_scores_by_crop_township.txt"});
    defer allocator.free(output_path);
    const normals_path = try paths_mod.existingInputPath(allocator, io, normals_txt);
    defer allocator.free(normals_path);
    const crop_path = try paths_mod.existingInputPath(allocator, io, crop_txt);
    defer allocator.free(crop_path);
    try runWithPaths(allocator, io, normals_path, crop_path, output_path);
}

pub fn runWithPaths(allocator: std.mem.Allocator, io: std.Io, normals_path: []const u8, crop_path: []const u8, output_path: []const u8) !void {
    var strings = array_store.StringInterner.init(allocator);
    defer strings.deinit();
    const normals = try loadNormals(allocator, io, &strings, normals_path);
    defer allocator.free(normals);
    const crops = try loadCrops(allocator, io, &strings, crop_path);
    defer allocator.free(crops);
    const rows = try calculateScoresParallel(allocator, normals, crops);
    defer allocator.free(rows);
    try writeScores(allocator, io, strings, rows, output_path);
}

pub fn addToFinalAccumulator(allocator: std.mem.Allocator, io: std.Io, input_root_path: []const u8, final_scores: *final_rating.Accumulator) !void {
    const input_paths = paths_mod.Paths.init(input_root_path);
    const normals_txt = try input_paths.join(allocator, &.{"historical_daily_temperature_normals_by_township.txt"});
    defer allocator.free(normals_txt);
    const crop_txt = try input_paths.join(allocator, &.{"crop_suitability_requirements.txt"});
    defer allocator.free(crop_txt);
    const normals_path = try paths_mod.existingInputPath(allocator, io, normals_txt);
    defer allocator.free(normals_path);
    const crop_path = try paths_mod.existingInputPath(allocator, io, crop_txt);
    defer allocator.free(crop_path);

    var strings = array_store.StringInterner.init(allocator);
    defer strings.deinit();
    const normals = try loadNormals(allocator, io, &strings, normals_path);
    defer allocator.free(normals);
    const crops = try loadCrops(allocator, io, &strings, crop_path);
    defer allocator.free(crops);

    const rows = try calculateScoresParallel(allocator, normals, crops);
    defer allocator.free(rows);
    for (rows) |row| {
        try final_scores.addScore(strings.get(row.crop_name_id), strings.get(row.township_id), .growing_season, @floatFromInt(row.score));
    }
}

fn calculateScoresParallel(
    allocator: std.mem.Allocator,
    normals: []const DailyNormal,
    crops: []const Crop,
) ![]Result {
    const township_ranges = try buildTownshipRanges(allocator, normals);
    defer allocator.free(township_ranges);
    const total_jobs = crops.len * township_ranges.len;
    const rows = try allocator.alloc(Result, total_jobs);
    errdefer allocator.free(rows);
    const workers = parallel.workerCount(total_jobs);
    if (workers == 0) return rows;
    if (workers == 1) {
        calculateScoreChunk(normals, township_ranges, crops, rows, 0, total_jobs);
        return rows;
    }

    const threads = try allocator.alloc(std.Thread, workers);
    defer allocator.free(threads);
    for (threads, 0..) |*thread, worker_index| {
        thread.* = try std.Thread.spawn(.{}, calculateScoreChunk, .{
            normals,
            township_ranges,
            crops,
            rows,
            parallel.chunkStart(total_jobs, worker_index, workers),
            parallel.chunkEnd(total_jobs, worker_index, workers),
        });
    }
    for (threads) |thread| thread.join();
    return rows;
}

fn calculateScoreChunk(
    normals: []const DailyNormal,
    township_ranges: []const TownshipNormalRange,
    crops: []const Crop,
    rows: []Result,
    job_start: usize,
    job_end: usize,
) void {
    for (job_start..job_end) |job_index| {
        const crop = crops[job_index / township_ranges.len];
        const township_range = township_ranges[job_index % township_ranges.len];
        var accumulator: Accumulator = .{};

        for (normals[township_range.start..township_range.end]) |normal| {
            const initial_flag = crop.is_winter_annual or (normal.max_temperature_quantile_75 > @as(f32, @floatFromInt(crop.absolute_minimum_temperature)) and normal.min_temperature_quantile_25 > 0);
            if (initial_flag) accumulator.previous_positive_flag_seen = true;
            if (accumulator.previous_positive_flag_seen and normal.min_temperature_quantile_25 > 0) {
                accumulator.growing_season_days += 1;
            }
        }

        const score = if (crop.is_winter_annual) 4 else growingSeasonScore(accumulator.growing_season_days, crop.grow_day_minimum, crop.grow_day_range);
        rows[job_index] = .{
            .crop_name_id = crop.crop_name_id,
            .township_id = township_range.township_id,
            .score = score,
        };
    }
}

fn buildTownshipRanges(allocator: std.mem.Allocator, normals: []const DailyNormal) ![]TownshipNormalRange {
    var ranges: std.ArrayList(TownshipNormalRange) = .empty;
    errdefer ranges.deinit(allocator);
    var start: usize = 0;
    while (start < normals.len) {
        const township_id = normals[start].township_id;
        var end = start + 1;
        while (end < normals.len and normals[end].township_id == township_id) : (end += 1) {}
        try ranges.append(allocator, .{ .township_id = township_id, .start = start, .end = end });
        start = end;
    }
    return ranges.toOwnedSlice(allocator);
}

fn loadNormals(allocator: std.mem.Allocator, io: std.Io, strings: *array_store.StringInterner, path: []const u8) ![]DailyNormal {
    var r = try reader_mod.Reader.open(allocator, io, path);
    defer r.close();
    const township_i = try r.header.columnIndex("township_id");
    const jd_i = try r.header.columnIndex("julian_day");
    const max_i = try r.header.columnIndex("maximum_temperature_quantile_75_celsius");
    const min_i = try r.header.columnIndex("minimum_temperature_quantile_25_celsius");
    var rows: std.ArrayList(DailyNormal) = .empty;
    errdefer rows.deinit(allocator);
    while (r.nextRow()) |row| try rows.append(allocator, .{
        .township_id = try strings.intern(try row.cell(township_i)),
        .julian_day = try std.fmt.parseInt(i32, try row.cell(jd_i), 10),
        .max_temperature_quantile_75 = try std.fmt.parseFloat(f32, try row.cell(max_i)),
        .min_temperature_quantile_25 = try std.fmt.parseFloat(f32, try row.cell(min_i)),
    });
    std.mem.sort(DailyNormal, rows.items, {}, sortNormals);
    return rows.toOwnedSlice(allocator);
}

fn loadCrops(allocator: std.mem.Allocator, io: std.Io, strings: *array_store.StringInterner, path: []const u8) ![]Crop {
    var r = try reader_mod.Reader.open(allocator, io, path);
    defer r.close();
    const crop_i = try r.header.columnIndex("crop_common_name");
    const habit_i = try r.header.columnIndex("growth_habit");
    const abs_min_i = try r.header.columnIndex("absolute_minimum_temperature_celsius");
    const grow_min_i = try r.header.columnIndex("minimum_growing_days");
    const grow_max_i = try r.header.columnIndex("maximum_growing_days");
    var rows: std.ArrayList(Crop) = .empty;
    errdefer rows.deinit(allocator);
    while (r.nextRow()) |row| {
        const grow_min = try std.fmt.parseInt(i32, try row.cell(grow_min_i), 10);
        const grow_max = try std.fmt.parseInt(i32, try row.cell(grow_max_i), 10);
        try rows.append(allocator, .{
            .crop_name_id = try strings.intern(try row.cell(crop_i)),
            .is_winter_annual = std.mem.eql(u8, try row.cell(habit_i), "Winter Annual"),
            .absolute_minimum_temperature = try std.fmt.parseInt(i32, try row.cell(abs_min_i), 10),
            .grow_day_minimum = grow_min,
            .grow_day_range = grow_max - grow_min,
        });
    }
    return rows.toOwnedSlice(allocator);
}

fn writeScores(allocator: std.mem.Allocator, io: std.Io, strings: array_store.StringInterner, rows: []Result, output_path: []const u8) !void {
    std.mem.sort(Result, rows, {}, sortRows);
    var output = try writer_mod.Writer.create(allocator, io, output_path);
    defer output.close();
    try output.writeAll("crop_common_name\ttownship_id\tgrowing_season_suitability_score\n");
    for (rows) |row| try output.print("{s}\t{s}\t{d}\n", .{ strings.get(row.crop_name_id), strings.get(row.township_id), row.score });
    try output.flush();
}

fn growingSeasonScore(days: i32, minimum: i32, range: i32) i32 {
    const d: f32 = @floatFromInt(days);
    const min: f32 = @floatFromInt(minimum);
    const r: f32 = @floatFromInt(range);
    if (d < min) return 0;
    if (d < min + 0.125 * r) return 1;
    if (d < min + 0.25 * r) return 2;
    if (d < min + 0.375 * r) return 3;
    return 4;
}

fn sortRows(_: void, a: Result, b: Result) bool {
    return if (a.crop_name_id == b.crop_name_id) a.township_id < b.township_id else a.crop_name_id < b.crop_name_id;
}
fn sortNormals(_: void, a: DailyNormal, b: DailyNormal) bool {
    if (a.township_id == b.township_id) return a.julian_day < b.julian_day;
    return a.township_id < b.township_id;
}

test "example-derived growing season thresholds" {
    // Onion in the published example requires 85-175 growing days.
    try std.testing.expectEqual(@as(i32, 0), growingSeasonScore(84, 85, 90));
    try std.testing.expectEqual(@as(i32, 1), growingSeasonScore(85, 85, 90));
    try std.testing.expectEqual(@as(i32, 4), growingSeasonScore(119, 85, 90));
}
