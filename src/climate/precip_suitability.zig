const std = @import("std");
const array_store = @import("../core/array_store.zig");
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
    var rows: std.ArrayList(Result) = .empty;
    defer rows.deinit(allocator);
    for (crops) |crop| {
        for (precip) |township| {
            try rows.append(allocator, .{
                .crop_name_id = crop.crop_name_id,
                .township_id = township.township_id,
                .score = precipitationSuitabilityScore(township.precipitation, crop.minimum, crop.maximum),
            });
        }
    }
    std.mem.sort(Result, rows.items, {}, sortRows);
    var output = writer_mod.Writer.create(allocator, io, output_path);
    defer output.close();
    try output.writeAll("crop_common_name\ttownship_id\tprecipitation_suitability_score\n");
    for (rows.items) |row| try output.print("{s}\t{s}\t{d}\n", .{ strings.get(row.crop_name_id), strings.get(row.township_id), row.score });
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

    for (crops) |crop| {
        for (precip) |township| {
            try final_scores.addScore(
                strings.get(crop.crop_name_id),
                strings.get(township.township_id),
                .precip,
                @floatFromInt(precipitationSuitabilityScore(township.precipitation, crop.minimum, crop.maximum)),
            );
        }
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
            .precipitation = try std.fmt.parseInt(i32, try row.cell(precip_i), 10),
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
        try rows.append(allocator, .{
            .crop_name_id = try strings.intern(try row.cell(crop_i)),
            .minimum = try std.fmt.parseInt(i32, try row.cell(min_i), 10),
            .maximum = try std.fmt.parseInt(i32, try row.cell(max_i), 10),
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

fn sortRows(_: void, a: Result, b: Result) bool {
    if (a.crop_name_id == b.crop_name_id) return a.township_id < b.township_id;
    return a.crop_name_id < b.crop_name_id;
}
