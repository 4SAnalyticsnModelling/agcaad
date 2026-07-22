const std = @import("std");
const array_store = @import("../core/array_store.zig");
const math = @import("../core/math.zig");
const score_grid = @import("../core/score_grid.zig");
const reader_mod = @import("../io/delimited_reader.zig");
const writer_mod = @import("../io/tab_writer.zig");
const paths_mod = @import("../paths.zig");
const final_rating = @import("../suitability/final_rating.zig");

const SoilPhColumns = struct {
    township_ids: []u32,
    multipliers: []f32,
    ph_values: []f32,
    fn deinit(self: SoilPhColumns, allocator: std.mem.Allocator) void {
        allocator.free(self.township_ids);
        allocator.free(self.multipliers);
        allocator.free(self.ph_values);
    }
};

const CropPhColumns = struct {
    crop_name_ids: []u32,
    ph_minimums: []f32,
    ph_maximums: []f32,
    fn deinit(self: CropPhColumns, allocator: std.mem.Allocator) void {
        allocator.free(self.crop_name_ids);
        allocator.free(self.ph_minimums);
        allocator.free(self.ph_maximums);
    }
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, input_root_path: []const u8, output_root_path: []const u8) !void {
    const input_paths = paths_mod.Paths.init(input_root_path);
    const output_paths = paths_mod.Paths.init(output_root_path);
    const soil_txt = try input_paths.join(allocator, &.{"soil_component_properties_by_township.txt"});
    defer allocator.free(soil_txt);
    const crop_txt = try input_paths.join(allocator, &.{"crop_suitability_requirements.txt"});
    defer allocator.free(crop_txt);
    const output_path = try output_paths.join(allocator, &.{"soil_ph_suitability_scores_by_crop_township.txt"});
    defer allocator.free(output_path);

    const soil_path = try paths_mod.existingInputPath(allocator, io, soil_txt);
    defer allocator.free(soil_path);
    const crop_path = try paths_mod.existingInputPath(allocator, io, crop_txt);
    defer allocator.free(crop_path);
    try runWithPaths(allocator, io, soil_path, crop_path, output_path);
}

pub fn runWithPaths(allocator: std.mem.Allocator, io: std.Io, soil_path: []const u8, crop_path: []const u8, output_path: []const u8) !void {
    var strings = array_store.StringInterner.init(allocator);
    defer strings.deinit();
    const soils = try loadSoils(allocator, io, &strings, soil_path);
    defer soils.deinit(allocator);
    const crops = try loadCrops(allocator, io, &strings, crop_path);
    defer crops.deinit(allocator);

    var totals = try score_grid.ScoreGrid.init(allocator, crops.crop_name_ids.len, soils.township_ids);
    defer totals.deinit();
    for (soils.township_ids, 0..) |township_id, soil_index| {
        for (crops.crop_name_ids, 0..) |_, crop_index| {
            const base_score = phSuitabilityScore(
                soils.ph_values[soil_index],
                crops.ph_minimums[crop_index],
                crops.ph_maximums[crop_index],
            );
            const weighted_score = math.roundToOneDecimal(@as(f32, @floatFromInt(base_score)) * soils.multipliers[soil_index]);
            totals.add(crop_index, township_id, weighted_score);
        }
    }
    try writeResults(allocator, io, strings, crops.crop_name_ids, totals, output_path);
}

pub fn addToFinalAccumulator(allocator: std.mem.Allocator, io: std.Io, input_root_path: []const u8, final_scores: *final_rating.Accumulator) !void {
    const input_paths = paths_mod.Paths.init(input_root_path);
    const soil_txt = try input_paths.join(allocator, &.{"soil_component_properties_by_township.txt"});
    defer allocator.free(soil_txt);
    const crop_txt = try input_paths.join(allocator, &.{"crop_suitability_requirements.txt"});
    defer allocator.free(crop_txt);
    const soil_path = try paths_mod.existingInputPath(allocator, io, soil_txt);
    defer allocator.free(soil_path);
    const crop_path = try paths_mod.existingInputPath(allocator, io, crop_txt);
    defer allocator.free(crop_path);

    var strings = array_store.StringInterner.init(allocator);
    defer strings.deinit();
    const soils = try loadSoils(allocator, io, &strings, soil_path);
    defer soils.deinit(allocator);
    const crops = try loadCrops(allocator, io, &strings, crop_path);
    defer crops.deinit(allocator);

    var totals = try score_grid.ScoreGrid.init(allocator, crops.crop_name_ids.len, soils.township_ids);
    defer totals.deinit();
    for (soils.township_ids, 0..) |township_id, soil_index| {
        for (crops.crop_name_ids, 0..) |_, crop_index| {
            const base_score = phSuitabilityScore(
                soils.ph_values[soil_index],
                crops.ph_minimums[crop_index],
                crops.ph_maximums[crop_index],
            );
            const weighted_score = math.roundToOneDecimal(@as(f32, @floatFromInt(base_score)) * soils.multipliers[soil_index]);
            totals.add(crop_index, township_id, weighted_score);
        }
    }

    for (crops.crop_name_ids, 0..) |crop_name_id, crop_index| {
        for (totals.township_ids.items, 0..) |township_id, township_index| {
            try final_scores.addScore(strings.get(crop_name_id), strings.get(township_id), .ph, math.roundToOneDecimal(totals.get(crop_index, township_index)));
        }
    }
}

fn loadSoils(allocator: std.mem.Allocator, io: std.Io, strings: *array_store.StringInterner, path: []const u8) !SoilPhColumns {
    var r = try reader_mod.Reader.open(allocator, io, path);
    defer r.close();
    const township_i = try r.header.columnIndex("township_id");
    const multiplier_i = try r.header.columnIndex("soil_component_area_fraction");
    const ph_i = try r.header.columnIndex("soil_ph");
    var township_ids: std.ArrayList(u32) = .empty;
    var multipliers: std.ArrayList(f32) = .empty;
    var ph_values: std.ArrayList(f32) = .empty;
    errdefer {
        township_ids.deinit(allocator);
        multipliers.deinit(allocator);
        ph_values.deinit(allocator);
    }
    while (r.nextRow()) |row| {
        try township_ids.append(allocator, try strings.intern(try row.cell(township_i)));
        try multipliers.append(allocator, math.roundToTwoDecimals(try row.boundedFloatCell(f32, multiplier_i, "soil_component_area_fraction", 0, 1)));
        try ph_values.append(allocator, math.roundToTwoDecimals(try row.boundedFloatCell(f32, ph_i, "soil_ph", 0, 14)));
    }
    return .{ .township_ids = try township_ids.toOwnedSlice(allocator), .multipliers = try multipliers.toOwnedSlice(allocator), .ph_values = try ph_values.toOwnedSlice(allocator) };
}

fn loadCrops(allocator: std.mem.Allocator, io: std.Io, strings: *array_store.StringInterner, path: []const u8) !CropPhColumns {
    var r = try reader_mod.Reader.open(allocator, io, path);
    defer r.close();
    const crop_i = try r.header.columnIndex("crop_common_name");
    const min_i = try r.header.columnIndex("minimum_soil_ph");
    const max_i = try r.header.columnIndex("maximum_soil_ph");
    var crop_name_ids: std.ArrayList(u32) = .empty;
    var ph_minimums: std.ArrayList(f32) = .empty;
    var ph_maximums: std.ArrayList(f32) = .empty;
    errdefer {
        crop_name_ids.deinit(allocator);
        ph_minimums.deinit(allocator);
        ph_maximums.deinit(allocator);
    }
    while (r.nextRow()) |row| {
        try crop_name_ids.append(allocator, try strings.intern(try row.cell(crop_i)));
        const minimum = try row.boundedFloatCell(f32, min_i, "minimum_soil_ph", 0, 14);
        const maximum = try row.boundedFloatCell(f32, max_i, "maximum_soil_ph", 0, 14);
        if (maximum < minimum) {
            std.debug.print("Invalid soil pH range in '{s}' at row {d}: maximum {d} is less than minimum {d}\n", .{ row.path, row.row_number, maximum, minimum });
            return error.InvalidRange;
        }
        try ph_minimums.append(allocator, minimum);
        try ph_maximums.append(allocator, maximum);
    }
    return .{ .crop_name_ids = try crop_name_ids.toOwnedSlice(allocator), .ph_minimums = try ph_minimums.toOwnedSlice(allocator), .ph_maximums = try ph_maximums.toOwnedSlice(allocator) };
}

fn phSuitabilityScore(ph_value: f32, ph_minimum: f32, ph_maximum: f32) i32 {
    const ph_range = ph_maximum - ph_minimum;
    const ph_mean = 0.5 * (ph_maximum + ph_minimum);
    if (ph_range > 2) return thresholdScore(ph_value, ph_mean, .{ 0.5, 1.0, 1.25, 1.5 });
    if (ph_range > 1) return thresholdScore(ph_value, ph_mean, .{ 0.5, 0.75, 1.0, 1.25 });
    return thresholdScore(ph_value, ph_mean, .{ 0.25, 0.55, 0.75, 0.85 });
}

fn thresholdScore(value: f32, center: f32, thresholds: [4]f32) i32 {
    if (value > center - thresholds[0] and value < center + thresholds[0]) return 4;
    if (value > center - thresholds[1] and value < center + thresholds[1]) return 3;
    if (value > center - thresholds[2] and value < center + thresholds[2]) return 2;
    if (value > center - thresholds[3] and value < center + thresholds[3]) return 1;
    return 0;
}

fn writeResults(allocator: std.mem.Allocator, io: std.Io, strings: array_store.StringInterner, crop_name_ids: []const u32, totals: score_grid.ScoreGrid, output_path: []const u8) !void {
    var output = try writer_mod.Writer.create(allocator, io, output_path);
    defer output.close();
    try output.writeAll("crop_common_name\ttownship_id\tsoil_ph_suitability_score\n");
    for (crop_name_ids, 0..) |crop_name_id, crop_index| for (totals.township_ids.items, 0..) |township_id, township_index| {
        try output.print("{s}\t{s}\t{d:.1}\n", .{ strings.get(crop_name_id), strings.get(township_id), math.roundToOneDecimal(totals.get(crop_index, township_index)) });
    };
    try output.flush();
}

test "example-derived yarrow soil pH scores" {
    // Example requirement range is pH 6-8; the first soil components are 7.5 and 7.1.
    try std.testing.expectEqual(@as(i32, 3), phSuitabilityScore(7.5, 6, 8));
    try std.testing.expectEqual(@as(i32, 4), phSuitabilityScore(7.1, 6, 8));
}
