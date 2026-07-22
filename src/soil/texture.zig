const std = @import("std");
const array_store = @import("../core/array_store.zig");
const math = @import("../core/math.zig");
const packed_key = @import("../core/packed_key.zig");
const score_grid = @import("../core/score_grid.zig");
const delimited_reader = @import("../io/delimited_reader.zig");
const tab_writer = @import("../io/tab_writer.zig");
const paths_mod = @import("../paths.zig");
const final_rating = @import("../suitability/final_rating.zig");
const weights = @import("weights.zig");

const SoilTextureColumns = struct {
    township_ids: []u32,
    texture_code_ids: []u32,
    soil_series_multipliers: []f32,

    pub fn deinit(self: SoilTextureColumns, allocator: std.mem.Allocator) void {
        allocator.free(self.township_ids);
        allocator.free(self.texture_code_ids);
        allocator.free(self.soil_series_multipliers);
    }
};

const CropTextureRequirementColumns = struct {
    crop_name_ids: []u32,
    texture_requirement_ids: []u32,

    pub fn deinit(self: CropTextureRequirementColumns, allocator: std.mem.Allocator) void {
        allocator.free(self.crop_name_ids);
        allocator.free(self.texture_requirement_ids);
    }
};

const TextureScoreKeyColumns = struct {
    texture_requirement_ids: []u32,
    texture_code_ids: []u32,
    texture_scores: []f32,

    pub fn deinit(self: TextureScoreKeyColumns, allocator: std.mem.Allocator) void {
        allocator.free(self.texture_requirement_ids);
        allocator.free(self.texture_code_ids);
        allocator.free(self.texture_scores);
    }
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, input_root_path: []const u8, output_root_path: []const u8) !void {
    const input_paths = paths_mod.Paths.init(input_root_path);
    const output_paths = paths_mod.Paths.init(output_root_path);
    const soil_property_txt_path = try input_paths.join(allocator, &.{"soil_component_properties_by_township.txt"});
    defer allocator.free(soil_property_txt_path);
    const crop_requirement_txt_path = try input_paths.join(allocator, &.{"crop_suitability_requirements.txt"});
    defer allocator.free(crop_requirement_txt_path);
    const texture_score_key_txt_path = try input_paths.join(allocator, &.{"soil_texture_requirement_scores.txt"});
    defer allocator.free(texture_score_key_txt_path);
    const texture_output_path = try output_paths.join(allocator, &.{"soil_texture_suitability_scores_by_crop_township.txt"});
    defer allocator.free(texture_output_path);

    const soil_property_path = try paths_mod.existingInputPath(allocator, io, soil_property_txt_path);
    defer allocator.free(soil_property_path);
    const crop_requirement_path = try paths_mod.existingInputPath(allocator, io, crop_requirement_txt_path);
    defer allocator.free(crop_requirement_path);
    const texture_score_key_path = try paths_mod.existingInputPath(allocator, io, texture_score_key_txt_path);
    defer allocator.free(texture_score_key_path);

    try runWithPaths(allocator, io, soil_property_path, crop_requirement_path, texture_score_key_path, texture_output_path);
}

pub fn runWithPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    soil_property_path: []const u8,
    crop_requirement_path: []const u8,
    texture_score_key_path: []const u8,
    texture_output_path: []const u8,
) !void {
    var string_ids = array_store.StringInterner.init(allocator);
    defer string_ids.deinit();

    const soil_textures = try loadSoilTextureColumns(allocator, io, &string_ids, soil_property_path);
    defer soil_textures.deinit(allocator);
    const crop_requirements = try loadCropTextureRequirementColumns(allocator, io, &string_ids, crop_requirement_path);
    defer crop_requirements.deinit(allocator);
    const texture_score_keys = try loadTextureScoreKeyColumns(allocator, io, &string_ids, texture_score_key_path);
    defer texture_score_keys.deinit(allocator);

    var result_scores = try score_grid.ScoreGrid.init(allocator, crop_requirements.crop_name_ids.len, soil_textures.township_ids);
    defer result_scores.deinit();

    try accumulateTextureSuitabilityScores(
        string_ids,
        soil_textures,
        crop_requirements,
        texture_score_keys,
        &result_scores,
    );

    try writeTextureSuitabilityScores(allocator, io, string_ids, crop_requirements.crop_name_ids, result_scores, texture_output_path);
}

pub fn addToFinalAccumulator(allocator: std.mem.Allocator, io: std.Io, input_root_path: []const u8, final_scores: *final_rating.Accumulator) !void {
    const input_paths = paths_mod.Paths.init(input_root_path);
    const soil_property_txt_path = try input_paths.join(allocator, &.{"soil_component_properties_by_township.txt"});
    defer allocator.free(soil_property_txt_path);
    const crop_requirement_txt_path = try input_paths.join(allocator, &.{"crop_suitability_requirements.txt"});
    defer allocator.free(crop_requirement_txt_path);
    const texture_score_key_txt_path = try input_paths.join(allocator, &.{"soil_texture_requirement_scores.txt"});
    defer allocator.free(texture_score_key_txt_path);

    const soil_property_path = try paths_mod.existingInputPath(allocator, io, soil_property_txt_path);
    defer allocator.free(soil_property_path);
    const crop_requirement_path = try paths_mod.existingInputPath(allocator, io, crop_requirement_txt_path);
    defer allocator.free(crop_requirement_path);
    const texture_score_key_path = try paths_mod.existingInputPath(allocator, io, texture_score_key_txt_path);
    defer allocator.free(texture_score_key_path);

    var string_ids = array_store.StringInterner.init(allocator);
    defer string_ids.deinit();
    const soil_textures = try loadSoilTextureColumns(allocator, io, &string_ids, soil_property_path);
    defer soil_textures.deinit(allocator);
    const crop_requirements = try loadCropTextureRequirementColumns(allocator, io, &string_ids, crop_requirement_path);
    defer crop_requirements.deinit(allocator);
    const texture_score_keys = try loadTextureScoreKeyColumns(allocator, io, &string_ids, texture_score_key_path);
    defer texture_score_keys.deinit(allocator);

    var result_scores = try score_grid.ScoreGrid.init(allocator, crop_requirements.crop_name_ids.len, soil_textures.township_ids);
    defer result_scores.deinit();
    try accumulateTextureSuitabilityScores(string_ids, soil_textures, crop_requirements, texture_score_keys, &result_scores);

    for (crop_requirements.crop_name_ids, 0..) |crop_name_id, crop_index| {
        for (result_scores.township_ids.items, 0..) |township_id, township_index| {
            try final_scores.addScore(string_ids.get(crop_name_id), string_ids.get(township_id), .texture, result_scores.get(crop_index, township_index));
        }
    }
}

fn loadSoilTextureColumns(
    allocator: std.mem.Allocator,
    io: std.Io,
    string_ids: *array_store.StringInterner,
    soil_property_path: []const u8,
) !SoilTextureColumns {
    var reader = try delimited_reader.Reader.open(allocator, io, soil_property_path);
    defer reader.close();

    const township_column_index = try reader.header.columnIndex("township_id");
    const multiplier_column_index = try reader.header.columnIndex("soil_component_area_fraction");
    const texture_code_column_index = try reader.header.columnIndex("alberta_soil_texture_code");

    var township_ids: std.ArrayList(u32) = .empty;
    var texture_code_ids: std.ArrayList(u32) = .empty;
    var soil_series_multipliers: std.ArrayList(f32) = .empty;
    errdefer {
        township_ids.deinit(allocator);
        texture_code_ids.deinit(allocator);
        soil_series_multipliers.deinit(allocator);
    }

    while (reader.nextRow()) |row| {
        try township_ids.append(allocator, try string_ids.intern(try row.cell(township_column_index)));
        try texture_code_ids.append(allocator, try string_ids.intern(try row.cell(texture_code_column_index)));
        try soil_series_multipliers.append(allocator, try row.boundedFloatCell(f32, multiplier_column_index, "soil_component_area_fraction", 0, 1));
    }

    try weights.validateAreaFractions(allocator, string_ids.*, township_ids.items, soil_series_multipliers.items, reader.path);

    return .{
        .township_ids = try township_ids.toOwnedSlice(allocator),
        .texture_code_ids = try texture_code_ids.toOwnedSlice(allocator),
        .soil_series_multipliers = try soil_series_multipliers.toOwnedSlice(allocator),
    };
}

fn loadCropTextureRequirementColumns(
    allocator: std.mem.Allocator,
    io: std.Io,
    string_ids: *array_store.StringInterner,
    crop_requirement_path: []const u8,
) !CropTextureRequirementColumns {
    var reader = try delimited_reader.Reader.open(allocator, io, crop_requirement_path);
    defer reader.close();

    const crop_name_column_index = try reader.header.columnIndex("crop_common_name");
    const texture_requirement_column_index = try reader.header.columnIndex("soil_texture_requirement_code");

    var crop_name_ids: std.ArrayList(u32) = .empty;
    var texture_requirement_ids: std.ArrayList(u32) = .empty;
    errdefer {
        crop_name_ids.deinit(allocator);
        texture_requirement_ids.deinit(allocator);
    }

    while (reader.nextRow()) |row| {
        try crop_name_ids.append(allocator, try string_ids.intern(try row.cell(crop_name_column_index)));
        const requirement_code = try row.cell(texture_requirement_column_index);
        const normalized_code = if (std.mem.eql(u8, requirement_code, "MMCV")) "MMCVC" else requirement_code;
        try texture_requirement_ids.append(allocator, try string_ids.intern(normalized_code));
    }

    return .{
        .crop_name_ids = try crop_name_ids.toOwnedSlice(allocator),
        .texture_requirement_ids = try texture_requirement_ids.toOwnedSlice(allocator),
    };
}

fn loadTextureScoreKeyColumns(
    allocator: std.mem.Allocator,
    io: std.Io,
    string_ids: *array_store.StringInterner,
    texture_score_key_path: []const u8,
) !TextureScoreKeyColumns {
    var reader = try delimited_reader.Reader.open(allocator, io, texture_score_key_path);
    defer reader.close();

    const texture_requirement_column_index = try reader.header.columnIndex("soil_texture_requirement_code");
    const texture_code_column_index = try reader.header.columnIndex("alberta_soil_texture_code");
    const texture_score_column_index = try reader.header.columnIndex("soil_texture_suitability_score");

    var texture_requirement_ids: std.ArrayList(u32) = .empty;
    var texture_code_ids: std.ArrayList(u32) = .empty;
    var texture_scores: std.ArrayList(f32) = .empty;
    errdefer {
        texture_requirement_ids.deinit(allocator);
        texture_code_ids.deinit(allocator);
        texture_scores.deinit(allocator);
    }

    while (reader.nextRow()) |row| {
        try texture_requirement_ids.append(allocator, try string_ids.intern(try row.cell(texture_requirement_column_index)));
        try texture_code_ids.append(allocator, try string_ids.intern(try row.cell(texture_code_column_index)));
        try texture_scores.append(allocator, try row.boundedFloatCell(f32, texture_score_column_index, "soil_texture_suitability_score", 0, 4));
    }

    return .{
        .texture_requirement_ids = try texture_requirement_ids.toOwnedSlice(allocator),
        .texture_code_ids = try texture_code_ids.toOwnedSlice(allocator),
        .texture_scores = try texture_scores.toOwnedSlice(allocator),
    };
}

fn accumulateTextureSuitabilityScores(
    string_ids: array_store.StringInterner,
    soil_textures: SoilTextureColumns,
    crop_requirements: CropTextureRequirementColumns,
    texture_score_keys: TextureScoreKeyColumns,
    result_scores: *score_grid.ScoreGrid,
) !void {
    var score_by_requirement_texture = std.AutoHashMap(u64, f32).init(result_scores.allocator);
    defer score_by_requirement_texture.deinit();
    try score_by_requirement_texture.ensureTotalCapacity(@intCast(texture_score_keys.texture_scores.len));
    for (texture_score_keys.texture_scores, 0..) |score, key_index| {
        const entry = try score_by_requirement_texture.getOrPut(packed_key.pack(texture_score_keys.texture_requirement_ids[key_index], texture_score_keys.texture_code_ids[key_index]));
        if (entry.found_existing) {
            std.debug.print("Duplicate texture score mapping for requirement '{s}' and texture code '{s}'\n", .{ string_ids.get(texture_score_keys.texture_requirement_ids[key_index]), string_ids.get(texture_score_keys.texture_code_ids[key_index]) });
            return error.DuplicateSuitabilityMapping;
        }
        entry.value_ptr.* = score;
    }

    for (soil_textures.township_ids, 0..) |township_id, soil_row_index| {
        const texture_code_id = soil_textures.texture_code_ids[soil_row_index];
        const soil_series_multiplier = soil_textures.soil_series_multipliers[soil_row_index];

        for (crop_requirements.crop_name_ids, 0..) |crop_name_id, crop_row_index| {
            const crop_texture_requirement_id = crop_requirements.texture_requirement_ids[crop_row_index];
            const texture_score = score_by_requirement_texture.get(packed_key.pack(crop_texture_requirement_id, texture_code_id)) orelse {
                std.debug.print("Missing texture score mapping for crop '{s}', requirement '{s}', texture code '{s}'\n", .{ string_ids.get(crop_name_id), string_ids.get(crop_texture_requirement_id), string_ids.get(texture_code_id) });
                return error.MissingSuitabilityMapping;
            };
            const weighted_score = texture_score * soil_series_multiplier;
            result_scores.add(crop_row_index, township_id, weighted_score);
        }
    }
}

fn writeTextureSuitabilityScores(
    allocator: std.mem.Allocator,
    io: std.Io,
    string_ids: array_store.StringInterner,
    crop_name_ids: []const u32,
    result_scores: score_grid.ScoreGrid,
    texture_output_path: []const u8,
) !void {
    var output = try tab_writer.Writer.create(allocator, io, texture_output_path);
    defer output.close();
    try output.writeAll("crop_common_name\ttownship_id\tsoil_texture_suitability_score\n");

    for (crop_name_ids, 0..) |crop_name_id, crop_index| for (result_scores.township_ids.items, 0..) |township_id, township_index| {
        try output.print("{s}\t{s}\t{d:.1}\n", .{
            string_ids.get(crop_name_id),
            string_ids.get(township_id),
            math.roundToOneDecimal(result_scores.get(crop_index, township_index)),
        });
    };
    try output.flush();
}
