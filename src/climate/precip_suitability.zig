const std = @import("std");
const array_store = @import("../core/array_store.zig");
const parallel = @import("../core/parallel.zig");
const reader_mod = @import("../io/delimited_reader.zig");
const writer_mod = @import("../io/tab_writer.zig");
const paths_mod = @import("../paths.zig");
const final_rating = @import("../suitability/final_rating.zig");

const TownshipPrecipitation = struct { township_id: u32, precipitation: i32 };
const CropPrecipitation = struct { crop_name_id: u32, minimum: i32, maximum: i32 };
const Result = struct { crop_name_id: u32, township_id: u32, score: i32 };

pub fn run(allocator: std.mem.Allocator, io: std.Io, input_root_path: []const u8, output_root_path: []const u8) !void {
    const input_paths = paths_mod.Paths.init(input_root_path);
    const output_paths = paths_mod.Paths.init(output_root_path);
    const input_precip_txt = try input_paths.join(allocator, &.{"historical_annual_precipitation_normals_by_township.txt"});
    defer allocator.free(input_precip_txt);
    const crop_txt = try input_paths.join(allocator, &.{"crop_suitability_requirements.txt"});
    defer allocator.free(crop_txt);
    const output_path = try output_paths.join(allocator, &.{"precipitation_suitability_scores_by_crop_township.txt"});
    defer allocator.free(output_path);
    const precip_path = try paths_mod.existingInputPath(allocator, io, input_precip_txt);
    defer allocator.free(precip_path);
    const crop_path = try paths_mod.existingInputPath(allocator, io, crop_txt);
    defer allocator.free(crop_path);
    try runWithPaths(allocator, io, precip_path, crop_path, output_path);
}

pub fn runWithPaths(allocator: std.mem.Allocator, io: std.Io, precip_path: []const u8, crop_path: []const u8, output_path: []const u8) !void {
    var strings = array_store.StringInterner.init(allocator);
    defer strings.deinit();
    const precip = try loadPrecip(allocator, io, &strings, precip_path);
    defer allocator.free(precip);
    const crops = try loadCrops(allocator, io, &strings, crop_path);
    defer allocator.free(crops);
    const rows = try calculateScoresParallel(allocator, crops, precip);
    defer allocator.free(rows);
    std.mem.sort(Result, rows, {}, sortRows);
    var output = try writer_mod.Writer.create(allocator, io, output_path);
    defer output.close();
    try output.writeAll("crop_common_name\ttownship_id\tprecipitation_suitability_score\n");
    for (rows) |row| try output.print("{s}\t{s}\t{d}\n", .{ strings.get(row.crop_name_id), strings.get(row.township_id), row.score });
    try output.flush();
}

pub fn addToFinalAccumulator(allocator: std.mem.Allocator, io: std.Io, input_root_path: []const u8, final_scores: *final_rating.Accumulator) !void {
    const input_paths = paths_mod.Paths.init(input_root_path);
    const precip_txt = try input_paths.join(allocator, &.{"historical_annual_precipitation_normals_by_township.txt"});
    defer allocator.free(precip_txt);
    const crop_txt = try input_paths.join(allocator, &.{"crop_suitability_requirements.txt"});
    defer allocator.free(crop_txt);
    const precip_path = try paths_mod.existingInputPath(allocator, io, precip_txt);
    defer allocator.free(precip_path);
    const crop_path = try paths_mod.existingInputPath(allocator, io, crop_txt);
    defer allocator.free(crop_path);

    var strings = array_store.StringInterner.init(allocator);
    defer strings.deinit();
    const precip = try loadPrecip(allocator, io, &strings, precip_path);
    defer allocator.free(precip);
    const crops = try loadCrops(allocator, io, &strings, crop_path);
    defer allocator.free(crops);

    const rows = try calculateScoresParallel(allocator, crops, precip);
    defer allocator.free(rows);
    for (rows) |row| {
        try final_scores.addScore(
            strings.get(row.crop_name_id),
            strings.get(row.township_id),
            .precip,
            @floatFromInt(row.score),
        );
    }
}

fn calculateScoresParallel(allocator: std.mem.Allocator, crops: []const CropPrecipitation, precip: []const TownshipPrecipitation) ![]Result {
    const total_count = std.math.mul(usize, crops.len, precip.len) catch {
        std.debug.print("Precipitation result count exceeds addressable memory: {d} crops by {d} townships\n", .{ crops.len, precip.len });
        return error.InputTooLarge;
    };
    const rows = try allocator.alloc(Result, total_count);
    errdefer allocator.free(rows);
    const workers = parallel.workerCount(total_count);
    if (workers == 0) return rows;
    if (workers == 1) {
        calculateScoreChunk(crops, precip, rows, 0, total_count);
        return rows;
    }
    const threads = try allocator.alloc(std.Thread, workers);
    defer allocator.free(threads);
    var spawned: usize = 0;
    for (threads, 0..) |*thread, worker_index| {
        thread.* = std.Thread.spawn(.{}, calculateScoreChunk, .{
            crops,
            precip,
            rows,
            parallel.chunkStart(total_count, worker_index, workers),
            parallel.chunkEnd(total_count, worker_index, workers),
        }) catch |err| {
            for (threads[0..spawned]) |running_thread| running_thread.join();
            std.debug.print("Failed to start precipitation worker {d} of {d}: {s}\n", .{ worker_index + 1, workers, @errorName(err) });
            return err;
        };
        spawned += 1;
    }
    for (threads) |thread| thread.join();
    return rows;
}

fn calculateScoreChunk(
    crops: []const CropPrecipitation,
    precip: []const TownshipPrecipitation,
    rows: []Result,
    job_start: usize,
    job_end: usize,
) void {
    for (job_start..job_end) |job_index| {
        const crop = crops[job_index / precip.len];
        const township = precip[job_index % precip.len];
        rows[job_index] = .{
            .crop_name_id = crop.crop_name_id,
            .township_id = township.township_id,
            .score = precipitationSuitabilityScore(township.precipitation, crop.minimum, crop.maximum),
        };
    }
}

fn loadPrecip(allocator: std.mem.Allocator, io: std.Io, strings: *array_store.StringInterner, path: []const u8) ![]TownshipPrecipitation {
    var r = try reader_mod.Reader.open(allocator, io, path);
    defer r.close();
    const township_i = try r.header.columnIndex("township_id");
    const precip_i = try r.header.columnIndex("annual_precipitation_mm");
    var rows: std.ArrayList(TownshipPrecipitation) = .empty;
    errdefer rows.deinit(allocator);
    while (r.nextRow()) |row| {
        try rows.append(allocator, .{
            .township_id = try strings.intern(try row.cell(township_i)),
            .precipitation = try row.intCell(i32, precip_i, "annual_precipitation_mm"),
        });
    }
    return rows.toOwnedSlice(allocator);
}

fn loadCrops(allocator: std.mem.Allocator, io: std.Io, strings: *array_store.StringInterner, path: []const u8) ![]CropPrecipitation {
    var r = try reader_mod.Reader.open(allocator, io, path);
    defer r.close();
    const crop_i = try r.header.columnIndex("crop_common_name");
    const min_i = try r.header.columnIndex("minimum_annual_precipitation_mm");
    const max_i = try r.header.columnIndex("maximum_annual_precipitation_mm");
    var rows: std.ArrayList(CropPrecipitation) = .empty;
    errdefer rows.deinit(allocator);
    while (r.nextRow()) |row| {
        const minimum = try row.intCell(i32, min_i, "minimum_annual_precipitation_mm");
        const maximum = try row.intCell(i32, max_i, "maximum_annual_precipitation_mm");
        if (maximum < minimum) {
            std.debug.print("Invalid precipitation range in '{s}' at row {d}: maximum {d} is less than minimum {d}\n", .{ row.path, row.row_number, maximum, minimum });
            return error.InvalidRange;
        }
        try rows.append(allocator, .{
            .crop_name_id = try strings.intern(try row.cell(crop_i)),
            .minimum = minimum,
            .maximum = maximum,
        });
    }
    return rows.toOwnedSlice(allocator);
}

fn precipitationSuitabilityScore(precipitation: i32, minimum: i32, maximum: i32) i32 {
    const p: f32 = @floatFromInt(precipitation);
    const min: f32 = @floatFromInt(minimum);
    const max: f32 = @floatFromInt(maximum);
    const range = max - min;
    if (range >= 300) {
        if (p >= min and p <= max + 1.25 * range and p >= min + range / 3.0) return 4;
        if (p >= min and p <= max + 1.25 * range) return 3;
        if (p >= min - 150 and p <= max + 1.6 * range) return 2;
        if (p >= min - 350 and p <= max + 1.8 * range) return 1;
        return 0;
    }
    if (p >= min and p <= max + 350 and p >= min + range / 3.0) return 4;
    if (p >= min and p <= max + 350) return 3;
    if (p >= min - range / 3.0 and p <= max + 480) return 2;
    if (p >= min - 2.0 * range / 3.0 and p <= max + 600) return 1;
    return 0;
}

test "example-derived wheatgrass precipitation thresholds" {
    // Crested wheatgrass in the example has a 150-450 mm requirement.
    try std.testing.expectEqual(@as(i32, 0), precipitationSuitabilityScore(-201, 150, 450));
    try std.testing.expectEqual(@as(i32, 3), precipitationSuitabilityScore(150, 150, 450));
    try std.testing.expectEqual(@as(i32, 4), precipitationSuitabilityScore(356, 150, 450));
    try std.testing.expectEqual(@as(i32, 2), precipitationSuitabilityScore(826, 150, 450));
    try std.testing.expectEqual(@as(i32, 0), precipitationSuitabilityScore(991, 150, 450));
}

test "Appendix D wide precipitation boundaries match the production model" {
    // Requirement 150-450 mm, range 300 mm. Check both sides of every class.
    try std.testing.expectEqual(@as(i32, 0), precipitationSuitabilityScore(-201, 150, 450));
    try std.testing.expectEqual(@as(i32, 1), precipitationSuitabilityScore(-200, 150, 450));
    try std.testing.expectEqual(@as(i32, 1), precipitationSuitabilityScore(-1, 150, 450));
    try std.testing.expectEqual(@as(i32, 2), precipitationSuitabilityScore(0, 150, 450));
    try std.testing.expectEqual(@as(i32, 2), precipitationSuitabilityScore(149, 150, 450));
    try std.testing.expectEqual(@as(i32, 3), precipitationSuitabilityScore(150, 150, 450));
    try std.testing.expectEqual(@as(i32, 4), precipitationSuitabilityScore(250, 150, 450));
    try std.testing.expectEqual(@as(i32, 4), precipitationSuitabilityScore(825, 150, 450));
    try std.testing.expectEqual(@as(i32, 2), precipitationSuitabilityScore(826, 150, 450));
    try std.testing.expectEqual(@as(i32, 2), precipitationSuitabilityScore(930, 150, 450));
    try std.testing.expectEqual(@as(i32, 1), precipitationSuitabilityScore(931, 150, 450));
    try std.testing.expectEqual(@as(i32, 1), precipitationSuitabilityScore(990, 150, 450));
    try std.testing.expectEqual(@as(i32, 0), precipitationSuitabilityScore(991, 150, 450));
}

test "Appendix D narrow precipitation boundaries match the production model" {
    // Requirement 300-500 mm, range 200 mm.
    try std.testing.expectEqual(@as(i32, 0), precipitationSuitabilityScore(166, 300, 500));
    try std.testing.expectEqual(@as(i32, 1), precipitationSuitabilityScore(167, 300, 500));
    try std.testing.expectEqual(@as(i32, 1), precipitationSuitabilityScore(233, 300, 500));
    try std.testing.expectEqual(@as(i32, 2), precipitationSuitabilityScore(234, 300, 500));
    try std.testing.expectEqual(@as(i32, 3), precipitationSuitabilityScore(300, 300, 500));
    try std.testing.expectEqual(@as(i32, 4), precipitationSuitabilityScore(367, 300, 500));
    try std.testing.expectEqual(@as(i32, 4), precipitationSuitabilityScore(850, 300, 500));
    try std.testing.expectEqual(@as(i32, 2), precipitationSuitabilityScore(851, 300, 500));
    try std.testing.expectEqual(@as(i32, 2), precipitationSuitabilityScore(980, 300, 500));
    try std.testing.expectEqual(@as(i32, 1), precipitationSuitabilityScore(981, 300, 500));
    try std.testing.expectEqual(@as(i32, 1), precipitationSuitabilityScore(1100, 300, 500));
    try std.testing.expectEqual(@as(i32, 0), precipitationSuitabilityScore(1101, 300, 500));
}

fn sortRows(_: void, a: Result, b: Result) bool {
    if (a.crop_name_id == b.crop_name_id) return a.township_id < b.township_id;
    return a.crop_name_id < b.crop_name_id;
}
