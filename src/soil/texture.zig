const std = @import("std");
const array_store = @import("../core/array_store.zig");
const math = @import("../core/math.zig");
const packed_key = @import("../core/packed_key.zig");
const delimited_reader = @import("../io/delimited_reader.zig");
const tab_writer = @import("../io/tab_writer.zig");
const paths_mod = @import("../paths.zig");
const final_rating = @import("../suitability/final_rating.zig");

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

const TextureSuitabilityResult = struct {
    crop_name_id: u32,
    township_id: u32,
    weighted_texture_score: f32,
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

    var result_scores = std.AutoHashMap(u64, f32).init(allocator);
    defer result_scores.deinit();

    try accumulateTextureSuitabilityScores(
        soil_textures,
        crop_requirements,
        texture_score_keys,
        &result_scores,
    );

    try writeTextureSuitabilityScores(allocator, io, string_ids, result_scores, texture_output_path);
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

    var result_scores = std.AutoHashMap(u64, f32).init(allocator);
    defer result_scores.deinit();
    try accumulateTextureSuitabilityScores(soil_textures, crop_requirements, texture_score_keys, &result_scores);

    var it = result_scores.iterator();
    while (it.next()) |entry| {
        const ids = packed_key.unpack(entry.key_ptr.*);
        try final_scores.addScore(
            string_ids.get(ids.first),
            string_ids.get(ids.second),
            .texture,
            math.roundToOneDecimal(entry.value_ptr.*),
        );
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
        try soil_series_multipliers.append(allocator, math.roundToTwoDecimals(try std.fmt.parseFloat(f32, try row.cell(multiplier_column_index))));
    }

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
        try texture_requirement_ids.append(allocator, try string_ids.intern(try row.cell(texture_requirement_column_index)));
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
        try texture_scores.append(allocator, try std.fmt.parseFloat(f32, try row.cell(texture_score_column_index)));
    }

    return .{
        .texture_requirement_ids = try texture_requirement_ids.toOwnedSlice(allocator),
        .texture_code_ids = try texture_code_ids.toOwnedSlice(allocator),
        .texture_scores = try texture_scores.toOwnedSlice(allocator),
    };
}

fn accumulateTextureSuitabilityScores(
    soil_textures: SoilTextureColumns,
    crop_requirements: CropTextureRequirementColumns,
    texture_score_keys: TextureScoreKeyColumns,
    result_scores: *std.AutoHashMap(u64, f32),
) !void {
    for (soil_textures.township_ids, 0..) |township_id, soil_row_index| {
        const texture_code_id = soil_textures.texture_code_ids[soil_row_index];
        const soil_series_multiplier = soil_textures.soil_series_multipliers[soil_row_index];

        for (crop_requirements.crop_name_ids, 0..) |crop_name_id, crop_row_index| {
            const crop_texture_requirement_id = crop_requirements.texture_requirement_ids[crop_row_index];

            for (texture_score_keys.texture_scores, 0..) |texture_score, key_row_index| {
                if (texture_score_keys.texture_requirement_ids[key_row_index] != crop_texture_requirement_id) continue;
                if (texture_score_keys.texture_code_ids[key_row_index] != texture_code_id) continue;

                const packed_result_key = packed_key.pack(crop_name_id, township_id);
                const weighted_score = math.roundToOneDecimal(texture_score * soil_series_multiplier);
                const entry = try result_scores.getOrPut(packed_result_key);
                if (entry.found_existing) {
                    entry.value_ptr.* += weighted_score;
                } else {
                    entry.value_ptr.* = weighted_score;
                }
            }
        }
    }
}

fn writeTextureSuitabilityScores(
    allocator: std.mem.Allocator,
    io: std.Io,
    string_ids: array_store.StringInterner,
    result_scores: std.AutoHashMap(u64, f32),
    texture_output_path: []const u8,
) !void {
    var output_rows: std.ArrayList(TextureSuitabilityResult) = .empty;
    defer output_rows.deinit(allocator);

    var result_iterator = result_scores.iterator();
    while (result_iterator.next()) |entry| {
        const unpacked_key = packed_key.unpack(entry.key_ptr.*);
        try output_rows.append(allocator, .{
            .crop_name_id = unpacked_key.first,
            .township_id = unpacked_key.second,
            .weighted_texture_score = math.roundToOneDecimal(entry.value_ptr.*),
        });
    }

    std.mem.sort(TextureSuitabilityResult, output_rows.items, {}, sortTextureSuitabilityResult);

    var output = tab_writer.Writer.create(allocator, io, texture_output_path);
    defer output.close();
    try output.writeAll("crop_common_name\ttownship_id\tsoil_texture_suitability_score\n");

    for (output_rows.items) |row| {
        try output.print("{s}\t{s}\t{d:.1}\n", .{
            string_ids.get(row.crop_name_id),
            string_ids.get(row.township_id),
            row.weighted_texture_score,
        });
    }
    try output.flush();
}

fn sortTextureSuitabilityResult(_: void, left: TextureSuitabilityResult, right: TextureSuitabilityResult) bool {
    if (left.crop_name_id == right.crop_name_id) return left.township_id < right.township_id;
    return left.crop_name_id < right.crop_name_id;
}
