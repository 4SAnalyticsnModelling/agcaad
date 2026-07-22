const std = @import("std");
const array_store = @import("../core/array_store.zig");
const math = @import("../core/math.zig");
const packed_key = @import("../core/packed_key.zig");
const score_grid = @import("../core/score_grid.zig");
const reader_mod = @import("../io/delimited_reader.zig");
const writer_mod = @import("../io/tab_writer.zig");
const paths_mod = @import("../paths.zig");
const final_rating = @import("../suitability/final_rating.zig");
const weights = @import("weights.zig");

const SoilDrainageColumns = struct {
    township_ids: []u32,
    drainage_code_ids: []u32,
    multipliers: []f32,
    fn deinit(self: SoilDrainageColumns, allocator: std.mem.Allocator) void {
        allocator.free(self.township_ids);
        allocator.free(self.drainage_code_ids);
        allocator.free(self.multipliers);
    }
};
const CropDrainageColumns = struct {
    crop_name_ids: []u32,
    drainage_requirement_ids: []u32,
    fn deinit(self: CropDrainageColumns, allocator: std.mem.Allocator) void {
        allocator.free(self.crop_name_ids);
        allocator.free(self.drainage_requirement_ids);
    }
};
const DrainageKeyColumns = struct {
    drainage_requirement_ids: []u32,
    drainage_code_ids: []u32,
    scores: []f32,
    fn deinit(self: DrainageKeyColumns, allocator: std.mem.Allocator) void {
        allocator.free(self.drainage_requirement_ids);
        allocator.free(self.drainage_code_ids);
        allocator.free(self.scores);
    }
};
pub fn run(allocator: std.mem.Allocator, io: std.Io, input_root_path: []const u8, output_root_path: []const u8) !void {
    const input_paths = paths_mod.Paths.init(input_root_path);
    const output_paths = paths_mod.Paths.init(output_root_path);
    const soil_txt = try input_paths.join(allocator, &.{"soil_component_properties_by_township.txt"});
    defer allocator.free(soil_txt);
    const crop_txt = try input_paths.join(allocator, &.{"crop_suitability_requirements.txt"});
    defer allocator.free(crop_txt);
    const key_txt = try input_paths.join(allocator, &.{"soil_drainage_requirement_scores.txt"});
    defer allocator.free(key_txt);
    const output_path = try output_paths.join(allocator, &.{"soil_drainage_suitability_scores_by_crop_township.txt"});
    defer allocator.free(output_path);
    const soil_path = try paths_mod.existingInputPath(allocator, io, soil_txt);
    defer allocator.free(soil_path);
    const crop_path = try paths_mod.existingInputPath(allocator, io, crop_txt);
    defer allocator.free(crop_path);
    const key_path = try paths_mod.existingInputPath(allocator, io, key_txt);
    defer allocator.free(key_path);
    try runWithPaths(allocator, io, soil_path, crop_path, key_path, output_path);
}

pub fn runWithPaths(allocator: std.mem.Allocator, io: std.Io, soil_path: []const u8, crop_path: []const u8, key_path: []const u8, output_path: []const u8) !void {
    var strings = array_store.StringInterner.init(allocator);
    defer strings.deinit();
    const soils = try loadSoils(allocator, io, &strings, soil_path);
    defer soils.deinit(allocator);
    const crops = try loadCrops(allocator, io, &strings, crop_path);
    defer crops.deinit(allocator);
    const keys = try loadKeys(allocator, io, &strings, key_path);
    defer keys.deinit(allocator);
    var totals = try score_grid.ScoreGrid.init(allocator, crops.crop_name_ids.len, soils.township_ids);
    defer totals.deinit();
    try accumulateScores(allocator, strings, soils, crops, keys, &totals);
    try writeResults(allocator, io, strings, crops.crop_name_ids, totals, output_path);
}

pub fn addToFinalAccumulator(allocator: std.mem.Allocator, io: std.Io, input_root_path: []const u8, final_scores: *final_rating.Accumulator) !void {
    const input_paths = paths_mod.Paths.init(input_root_path);
    const soil_txt = try input_paths.join(allocator, &.{"soil_component_properties_by_township.txt"});
    defer allocator.free(soil_txt);
    const crop_txt = try input_paths.join(allocator, &.{"crop_suitability_requirements.txt"});
    defer allocator.free(crop_txt);
    const key_txt = try input_paths.join(allocator, &.{"soil_drainage_requirement_scores.txt"});
    defer allocator.free(key_txt);
    const soil_path = try paths_mod.existingInputPath(allocator, io, soil_txt);
    defer allocator.free(soil_path);
    const crop_path = try paths_mod.existingInputPath(allocator, io, crop_txt);
    defer allocator.free(crop_path);
    const key_path = try paths_mod.existingInputPath(allocator, io, key_txt);
    defer allocator.free(key_path);

    var strings = array_store.StringInterner.init(allocator);
    defer strings.deinit();
    const soils = try loadSoils(allocator, io, &strings, soil_path);
    defer soils.deinit(allocator);
    const crops = try loadCrops(allocator, io, &strings, crop_path);
    defer crops.deinit(allocator);
    const keys = try loadKeys(allocator, io, &strings, key_path);
    defer keys.deinit(allocator);

    var totals = try score_grid.ScoreGrid.init(allocator, crops.crop_name_ids.len, soils.township_ids);
    defer totals.deinit();
    try accumulateScores(allocator, strings, soils, crops, keys, &totals);

    for (crops.crop_name_ids, 0..) |crop_name_id, crop_index| {
        for (totals.township_ids.items, 0..) |township_id, township_index| {
            try final_scores.addScore(strings.get(crop_name_id), strings.get(township_id), .drainage, totals.get(crop_index, township_index));
        }
    }
}

fn accumulateScores(allocator: std.mem.Allocator, strings: array_store.StringInterner, soils: SoilDrainageColumns, crops: CropDrainageColumns, keys: DrainageKeyColumns, totals: *score_grid.ScoreGrid) !void {
    var score_by_requirement_drainage = std.AutoHashMap(u64, f32).init(allocator);
    defer score_by_requirement_drainage.deinit();
    try score_by_requirement_drainage.ensureTotalCapacity(@intCast(keys.scores.len));
    for (keys.scores, 0..) |score, key_index| {
        const entry = try score_by_requirement_drainage.getOrPut(packed_key.pack(keys.drainage_requirement_ids[key_index], keys.drainage_code_ids[key_index]));
        if (entry.found_existing) {
            std.debug.print("Duplicate drainage score mapping for requirement '{s}' and drainage code '{s}'\n", .{ strings.get(keys.drainage_requirement_ids[key_index]), strings.get(keys.drainage_code_ids[key_index]) });
            return error.DuplicateSuitabilityMapping;
        }
        entry.value_ptr.* = score;
    }
    for (soils.township_ids, 0..) |township_id, soil_index| {
        const drainage_code_id = soils.drainage_code_ids[soil_index];
        for (crops.crop_name_ids, 0..) |crop_name_id, crop_index| {
            const requirement_id = crops.drainage_requirement_ids[crop_index];
            const score = score_by_requirement_drainage.get(packed_key.pack(requirement_id, drainage_code_id)) orelse {
                std.debug.print("Missing drainage score mapping for crop '{s}', requirement '{s}', drainage code '{s}'\n", .{ strings.get(crop_name_id), strings.get(requirement_id), strings.get(drainage_code_id) });
                return error.MissingSuitabilityMapping;
            };
            const weighted_score = score * soils.multipliers[soil_index];
            totals.add(crop_index, township_id, weighted_score);
        }
    }
}

fn loadSoils(allocator: std.mem.Allocator, io: std.Io, strings: *array_store.StringInterner, path: []const u8) !SoilDrainageColumns {
    var r = try reader_mod.Reader.open(allocator, io, path);
    defer r.close();
    const township_i = try r.header.columnIndex("township_id");
    const multiplier_i = try r.header.columnIndex("soil_component_area_fraction");
    const drainage_i = try r.header.columnIndex("soil_drainage_code");
    var township_ids: std.ArrayList(u32) = .empty;
    var drainage_code_ids: std.ArrayList(u32) = .empty;
    var multipliers: std.ArrayList(f32) = .empty;
    errdefer {
        township_ids.deinit(allocator);
        drainage_code_ids.deinit(allocator);
        multipliers.deinit(allocator);
    }
    while (r.nextRow()) |row| {
        try township_ids.append(allocator, try strings.intern(try row.cell(township_i)));
        try drainage_code_ids.append(allocator, try strings.intern(try row.cell(drainage_i)));
        try multipliers.append(allocator, try row.boundedFloatCell(f32, multiplier_i, "soil_component_area_fraction", 0, 1));
    }
    try weights.validateAreaFractions(allocator, strings.*, township_ids.items, multipliers.items, path);
    return .{ .township_ids = try township_ids.toOwnedSlice(allocator), .drainage_code_ids = try drainage_code_ids.toOwnedSlice(allocator), .multipliers = try multipliers.toOwnedSlice(allocator) };
}

fn loadCrops(allocator: std.mem.Allocator, io: std.Io, strings: *array_store.StringInterner, path: []const u8) !CropDrainageColumns {
    var r = try reader_mod.Reader.open(allocator, io, path);
    defer r.close();
    const crop_i = try r.header.columnIndex("crop_common_name");
    const req_i = try r.header.columnIndex("soil_drainage_requirement_code");
    const description_i = try r.header.columnIndex("soil_drainage_requirement_description");
    var crop_name_ids: std.ArrayList(u32) = .empty;
    var drainage_requirement_ids: std.ArrayList(u32) = .empty;
    errdefer {
        crop_name_ids.deinit(allocator);
        drainage_requirement_ids.deinit(allocator);
    }
    while (r.nextRow()) |row| {
        try crop_name_ids.append(allocator, try strings.intern(try row.cell(crop_i)));
        const requirement_code = try row.cell(req_i);
        const description = try row.cell(description_i);
        const normalized_code = if (std.mem.eql(u8, requirement_code, "A") and std.mem.startsWith(u8, description, "Semi-Exce")) "SE" else requirement_code;
        try drainage_requirement_ids.append(allocator, try strings.intern(normalized_code));
    }
    return .{ .crop_name_ids = try crop_name_ids.toOwnedSlice(allocator), .drainage_requirement_ids = try drainage_requirement_ids.toOwnedSlice(allocator) };
}

fn loadKeys(allocator: std.mem.Allocator, io: std.Io, strings: *array_store.StringInterner, path: []const u8) !DrainageKeyColumns {
    var r = try reader_mod.Reader.open(allocator, io, path);
    defer r.close();
    const req_i = try r.header.columnIndex("soil_drainage_requirement_code");
    const drainage_i = try r.header.columnIndex("soil_drainage_code");
    const score_i = try r.header.columnIndex("soil_drainage_suitability_score");
    var drainage_requirement_ids: std.ArrayList(u32) = .empty;
    var drainage_code_ids: std.ArrayList(u32) = .empty;
    var scores: std.ArrayList(f32) = .empty;
    errdefer {
        drainage_requirement_ids.deinit(allocator);
        drainage_code_ids.deinit(allocator);
        scores.deinit(allocator);
    }
    while (r.nextRow()) |row| {
        try drainage_requirement_ids.append(allocator, try strings.intern(try row.cell(req_i)));
        try drainage_code_ids.append(allocator, try strings.intern(try row.cell(drainage_i)));
        try scores.append(allocator, try row.boundedFloatCell(f32, score_i, "soil_drainage_suitability_score", 0, 4));
    }
    return .{ .drainage_requirement_ids = try drainage_requirement_ids.toOwnedSlice(allocator), .drainage_code_ids = try drainage_code_ids.toOwnedSlice(allocator), .scores = try scores.toOwnedSlice(allocator) };
}

fn writeResults(allocator: std.mem.Allocator, io: std.Io, strings: array_store.StringInterner, crop_name_ids: []const u32, totals: score_grid.ScoreGrid, output_path: []const u8) !void {
    var output = try writer_mod.Writer.create(allocator, io, output_path);
    defer output.close();
    try output.writeAll("crop_common_name\ttownship_id\tsoil_drainage_suitability_score\n");
    for (crop_name_ids, 0..) |crop_name_id, crop_index| for (totals.township_ids.items, 0..) |township_id, township_index| {
        try output.print("{s}\t{s}\t{d:.1}\n", .{ strings.get(crop_name_id), strings.get(township_id), math.roundToOneDecimal(totals.get(crop_index, township_index)) });
    };
    try output.flush();
}

test "indexed drainage lookup preserves example-derived weighted score" {
    const allocator = std.testing.allocator;
    const soils: SoilDrainageColumns = .{
        .township_ids = @constCast(&[_]u32{ 0, 0 }),
        .drainage_code_ids = @constCast(&[_]u32{ 1, 1 }),
        .multipliers = @constCast(&[_]f32{ 0.41, 0.08 }),
    };
    const crops: CropDrainageColumns = .{ .crop_name_ids = @constCast(&[_]u32{2}), .drainage_requirement_ids = @constCast(&[_]u32{1}) };
    const keys: DrainageKeyColumns = .{ .drainage_requirement_ids = @constCast(&[_]u32{1}), .drainage_code_ids = @constCast(&[_]u32{1}), .scores = @constCast(&[_]f32{4}) };
    var totals = try score_grid.ScoreGrid.init(allocator, crops.crop_name_ids.len, soils.township_ids);
    defer totals.deinit();
    var strings = array_store.StringInterner.init(allocator);
    defer strings.deinit();
    _ = try strings.intern("township");
    _ = try strings.intern("W");
    _ = try strings.intern("crop");
    try accumulateScores(allocator, strings, soils, crops, keys, &totals);
    // Keep the exact 4*0.37 + 1*0.48 component weighting; 1.9 is only its
    // one-decimal display representation.
    try std.testing.expectApproxEqAbs(@as(f32, 1.96), totals.get(0, 0), 0.001);
}
