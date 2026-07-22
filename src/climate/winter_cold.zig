const std = @import("std");
const array_store = @import("../core/array_store.zig");
const parallel = @import("../core/parallel.zig");
const reader_mod = @import("../io/delimited_reader.zig");
const writer_mod = @import("../io/tab_writer.zig");
const paths_mod = @import("../paths.zig");
const final_rating = @import("../suitability/final_rating.zig");

const TownshipWinterMinimum = struct { township_id: u32, minimum_temperature_quantile_05: f32 };
const CropWinterTolerance = struct { crop_name_id: u32, growth_habit_id: u32, critical_minimum_winter_temperature: ?f32 };
const Result = struct { crop_name_id: u32, township_id: u32, score: i32 };

pub fn run(allocator: std.mem.Allocator, io: std.Io, input_root_path: []const u8, output_root_path: []const u8) !void {
    const paths = paths_mod.Paths.init(input_root_path);
    const winter_txt = try paths.join(allocator, &.{"historical_winter_critical_temperature_by_township.txt"});
    defer allocator.free(winter_txt);
    const crop_txt = try paths.join(allocator, &.{"crop_suitability_requirements.txt"});
    defer allocator.free(crop_txt);
    const output_paths = paths_mod.Paths.init(output_root_path);
    const output_path = try output_paths.join(allocator, &.{"winter_cold_tolerance_scores_by_crop_township.txt"});
    defer allocator.free(output_path);
    const winter_path = try paths_mod.existingInputPath(allocator, io, winter_txt);
    defer allocator.free(winter_path);
    const crop_path = try paths_mod.existingInputPath(allocator, io, crop_txt);
    defer allocator.free(crop_path);
    try runWithPaths(allocator, io, winter_path, crop_path, output_path);
}

pub fn runWithPaths(allocator: std.mem.Allocator, io: std.Io, winter_path: []const u8, crop_path: []const u8, output_path: []const u8) !void {
    var strings = array_store.StringInterner.init(allocator);
    defer strings.deinit();
    const townships = try loadTownships(allocator, io, &strings, winter_path);
    defer allocator.free(townships);
    const crops = try loadCrops(allocator, io, &strings, crop_path);
    defer allocator.free(crops);
    const rows = try calculateScoresParallel(allocator, strings, crops, townships);
    defer allocator.free(rows);
    std.mem.sort(Result, rows, {}, sortRows);
    var output = try writer_mod.Writer.create(allocator, io, output_path);
    defer output.close();
    try output.writeAll("crop_common_name\ttownship_id\twinter_cold_tolerance_score\n");
    for (rows) |row| try output.print("{s}\t{s}\t{d}\n", .{ strings.get(row.crop_name_id), strings.get(row.township_id), row.score });
    try output.flush();
}

pub fn addToFinalAccumulator(allocator: std.mem.Allocator, io: std.Io, input_root_path: []const u8, final_scores: *final_rating.Accumulator) !void {
    const paths = paths_mod.Paths.init(input_root_path);
    const winter_txt = try paths.join(allocator, &.{"historical_winter_critical_temperature_by_township.txt"});
    defer allocator.free(winter_txt);
    const crop_txt = try paths.join(allocator, &.{"crop_suitability_requirements.txt"});
    defer allocator.free(crop_txt);
    const winter_path = try paths_mod.existingInputPath(allocator, io, winter_txt);
    defer allocator.free(winter_path);
    const crop_path = try paths_mod.existingInputPath(allocator, io, crop_txt);
    defer allocator.free(crop_path);

    var strings = array_store.StringInterner.init(allocator);
    defer strings.deinit();
    const townships = try loadTownships(allocator, io, &strings, winter_path);
    defer allocator.free(townships);
    const crops = try loadCrops(allocator, io, &strings, crop_path);
    defer allocator.free(crops);

    const rows = try calculateScoresParallel(allocator, strings, crops, townships);
    defer allocator.free(rows);
    for (rows) |row| {
        try final_scores.addScore(
            strings.get(row.crop_name_id),
            strings.get(row.township_id),
            .winter,
            @floatFromInt(row.score),
        );
    }
}

fn calculateScoresParallel(
    allocator: std.mem.Allocator,
    strings: array_store.StringInterner,
    crops: []const CropWinterTolerance,
    townships: []const TownshipWinterMinimum,
) ![]Result {
    const total_count = std.math.mul(usize, crops.len, townships.len) catch {
        std.debug.print("Winter-cold result count exceeds addressable memory: {d} crops by {d} townships\n", .{ crops.len, townships.len });
        return error.InputTooLarge;
    };
    const rows = try allocator.alloc(Result, total_count);
    errdefer allocator.free(rows);
    const workers = parallel.workerCount(total_count);
    if (workers == 0) return rows;
    if (workers == 1) {
        calculateScoreChunk(strings, crops, townships, rows, 0, total_count);
        return rows;
    }
    const threads = try allocator.alloc(std.Thread, workers);
    defer allocator.free(threads);
    var spawned: usize = 0;
    for (threads, 0..) |*thread, worker_index| {
        thread.* = std.Thread.spawn(.{}, calculateScoreChunk, .{
            strings,
            crops,
            townships,
            rows,
            parallel.chunkStart(total_count, worker_index, workers),
            parallel.chunkEnd(total_count, worker_index, workers),
        }) catch |err| {
            for (threads[0..spawned]) |running_thread| running_thread.join();
            std.debug.print("Failed to start winter-cold worker {d} of {d}: {s}\n", .{ worker_index + 1, workers, @errorName(err) });
            return err;
        };
        spawned += 1;
    }
    for (threads) |thread| thread.join();
    return rows;
}

fn calculateScoreChunk(
    strings: array_store.StringInterner,
    crops: []const CropWinterTolerance,
    townships: []const TownshipWinterMinimum,
    rows: []Result,
    job_start: usize,
    job_end: usize,
) void {
    for (job_start..job_end) |job_index| {
        const crop = crops[job_index / townships.len];
        const township = townships[job_index % townships.len];
        rows[job_index] = .{
            .crop_name_id = crop.crop_name_id,
            .township_id = township.township_id,
            .score = winterColdToleranceScore(strings.get(crop.growth_habit_id), crop.critical_minimum_winter_temperature, township.minimum_temperature_quantile_05),
        };
    }
}

fn loadTownships(allocator: std.mem.Allocator, io: std.Io, strings: *array_store.StringInterner, path: []const u8) ![]TownshipWinterMinimum {
    var r = try reader_mod.Reader.open(allocator, io, path);
    defer r.close();
    const township_i = try r.header.columnIndex("township_id");
    const min_i = try r.header.columnIndex("minimum_temperature_quantile_05_celsius");
    var rows: std.ArrayList(TownshipWinterMinimum) = .empty;
    errdefer rows.deinit(allocator);
    while (r.nextRow()) |row| try rows.append(allocator, .{
        .township_id = try strings.intern(try row.cell(township_i)),
        .minimum_temperature_quantile_05 = try row.floatCell(f32, min_i, "minimum_temperature_quantile_05_celsius"),
    });
    return rows.toOwnedSlice(allocator);
}

fn loadCrops(allocator: std.mem.Allocator, io: std.Io, strings: *array_store.StringInterner, path: []const u8) ![]CropWinterTolerance {
    var r = try reader_mod.Reader.open(allocator, io, path);
    defer r.close();
    const crop_i = try r.header.columnIndex("crop_common_name");
    const habit_i = try r.header.columnIndex("growth_habit");
    const critical_i = try r.header.columnIndex("critical_minimum_winter_temperature_celsius");
    var rows: std.ArrayList(CropWinterTolerance) = .empty;
    errdefer rows.deinit(allocator);
    while (r.nextRow()) |row| {
        const critical_text = try row.cell(critical_i);
        try rows.append(allocator, .{
            .crop_name_id = try strings.intern(try row.cell(crop_i)),
            .growth_habit_id = try strings.intern(try row.cell(habit_i)),
            .critical_minimum_winter_temperature = if (critical_text.len == 0) null else try row.floatCell(f32, critical_i, "critical_minimum_winter_temperature_celsius"),
        });
    }
    return rows.toOwnedSlice(allocator);
}

fn winterColdToleranceScore(growth_habit: []const u8, critical_minimum: ?f32, township_minimum: f32) i32 {
    if (critical_minimum == null) return 4;
    if (std.mem.eql(u8, growth_habit, "Annual") or
        std.mem.eql(u8, growth_habit, "Functional Annual/Biennial") or
        std.mem.eql(u8, growth_habit, "Annual/Biennial/Perennial") or
        std.mem.eql(u8, growth_habit, "Annual/Perennial")) return 4;
    const critical = critical_minimum.?;
    // Appendix D, figure 7: each one-degree band above the critical minimum
    // advances one class; highly suitable begins above critical + 3 C.
    if (township_minimum > critical + 3) return 4;
    if (township_minimum > critical + 2) return 3;
    if (township_minimum > critical + 1) return 2;
    if (township_minimum >= critical) return 1;
    return 0;
}

test "example-derived winter cold scoring" {
    try std.testing.expectEqual(@as(i32, 4), winterColdToleranceScore("Winter Annual", -46, -21.9));
    try std.testing.expectEqual(@as(i32, 4), winterColdToleranceScore("Perennial", null, -21.9));
    try std.testing.expectEqual(@as(i32, 0), winterColdToleranceScore("Perennial", -10, -21.9));
    try std.testing.expectEqual(@as(i32, 1), winterColdToleranceScore("Perennial", -10, -10));
    try std.testing.expectEqual(@as(i32, 2), winterColdToleranceScore("Perennial", -10, -8.5));
    try std.testing.expectEqual(@as(i32, 3), winterColdToleranceScore("Perennial", -10, -7.5));
    try std.testing.expectEqual(@as(i32, 4), winterColdToleranceScore("Perennial", -10, -6.5));
}

fn sortRows(_: void, a: Result, b: Result) bool {
    if (a.crop_name_id == b.crop_name_id) return a.township_id < b.township_id;
    return a.crop_name_id < b.crop_name_id;
}
