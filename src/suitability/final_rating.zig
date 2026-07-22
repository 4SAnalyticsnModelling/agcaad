const std = @import("std");
const builtin = @import("builtin");
const array_store = @import("../core/array_store.zig");
const math = @import("../core/math.zig");
const packed_key = @import("../core/packed_key.zig");
const writer_mod = @import("../io/tab_writer.zig");

const ScoreMask = struct {
    const winter: u8 = 1 << 0;
    const precip: u8 = 1 << 1;
    const growing_season: u8 = 1 << 2;
    const drainage: u8 = 1 << 3;
    const ph: u8 = 1 << 4;
    const texture: u8 = 1 << 5;
    const temperature: u8 = 1 << 6;
    const complete: u8 = winter | precip | growing_season | drainage | ph | texture | temperature;
    const soil_complete: u8 = drainage | ph | texture;
    const climate_complete: u8 = winter | precip | growing_season | temperature;
};

const SuitabilityScores = struct {
    common_name_id: u32,
    township_id: u32,
    winter_cold_tolerance_score: f32 = 0,
    precipitation_suitability_score: f32 = 0,
    growing_season_score: f32 = 0,
    drainage_score: f32 = 0,
    ph_score: f32 = 0,
    texture_score: f32 = 0,
    temperature_score: f32 = 0,
    present_mask: u8 = 0,
};

const OutputRow = struct {
    common_name: []const u8,
    township: []const u8,
    scores: SuitabilityScores,
    overall_score: f32,
    rating: []const u8,
};

pub const Field = enum {
    winter,
    precip,
    growing_season,
    drainage,
    ph,
    texture,
    temperature,
};

pub const Accumulator = struct {
    allocator: std.mem.Allocator,
    strings: array_store.StringInterner,
    scores: std.AutoHashMap(u64, SuitabilityScores),

    pub fn init(allocator: std.mem.Allocator) Accumulator {
        return .{
            .allocator = allocator,
            .strings = array_store.StringInterner.init(allocator),
            .scores = std.AutoHashMap(u64, SuitabilityScores).init(allocator),
        };
    }

    pub fn deinit(self: *Accumulator) void {
        self.scores.deinit();
        self.strings.deinit();
    }

    pub fn addScore(self: *Accumulator, crop_common_name: []const u8, township_id: []const u8, field: Field, value: f32) !void {
        const maximum: f32 = switch (field) {
            .drainage, .ph, .texture, .temperature => 5,
            else => 4,
        };
        if (!std.math.isFinite(value) or value < 0 or value > maximum) {
            if (!builtin.is_test) std.debug.print("Invalid {s} score for crop '{s}', township '{s}': {d} (expected finite value from 0 through {d})\n", .{ @tagName(field), crop_common_name, township_id, value, maximum });
            return error.InvalidSuitabilityScore;
        }
        const common_name_id = try self.strings.intern(crop_common_name);
        const township_name_id = try self.strings.intern(township_id);
        const entry = try self.scores.getOrPut(packed_key.pack(common_name_id, township_name_id));
        if (!entry.found_existing) {
            entry.value_ptr.* = .{
                .common_name_id = common_name_id,
                .township_id = township_name_id,
            };
        }
        const field_mask = maskForField(field);
        if (entry.value_ptr.present_mask & field_mask != 0) {
            if (!builtin.is_test) std.debug.print("Duplicate {s} score for crop '{s}', township '{s}'\n", .{ @tagName(field), crop_common_name, township_id });
            return error.DuplicateSuitabilityScore;
        }
        setScoreField(entry.value_ptr, field, value);
        entry.value_ptr.present_mask |= field_mask;
    }

    pub fn write(self: Accumulator, io: std.Io, output_path: []const u8) !void {
        try writeFinalRatings(self.allocator, io, self.strings, self.scores, output_path);
    }
};

fn maskForField(field: Field) u8 {
    return switch (field) {
        .winter => ScoreMask.winter,
        .precip => ScoreMask.precip,
        .growing_season => ScoreMask.growing_season,
        .drainage => ScoreMask.drainage,
        .ph => ScoreMask.ph,
        .texture => ScoreMask.texture,
        .temperature => ScoreMask.temperature,
    };
}

fn setScoreField(scores: *SuitabilityScores, field: Field, value: f32) void {
    switch (field) {
        .winter => scores.winter_cold_tolerance_score = value,
        .precip => scores.precipitation_suitability_score = value,
        .growing_season => scores.growing_season_score = value,
        .drainage => scores.drainage_score = value,
        .ph => scores.ph_score = value,
        .texture => scores.texture_score = value,
        .temperature => scores.temperature_score = value,
    }
}

fn writeFinalRatings(allocator: std.mem.Allocator, io: std.Io, strings: array_store.StringInterner, scores: std.AutoHashMap(u64, SuitabilityScores), output_path: []const u8) !void {
    var rows: std.ArrayList(OutputRow) = .empty;
    defer rows.deinit(allocator);
    var soil_only_count: usize = 0;
    var climate_only_count: usize = 0;
    var it = scores.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.present_mask != ScoreMask.complete) {
            if (entry.value_ptr.present_mask == ScoreMask.soil_complete) {
                soil_only_count += 1;
                continue;
            }
            if (entry.value_ptr.present_mask == ScoreMask.climate_complete) {
                climate_only_count += 1;
                continue;
            }
            std.debug.print("Incomplete suitability data for crop '{s}', township '{s}': present score mask 0x{x}, expected 0x{x}\n", .{ strings.get(entry.value_ptr.common_name_id), strings.get(entry.value_ptr.township_id), entry.value_ptr.present_mask, ScoreMask.complete });
            return error.IncompleteSuitabilityData;
        }
        const overall_score = calculateOverallScore(entry.value_ptr.*);
        try rows.append(allocator, .{
            .common_name = strings.get(entry.value_ptr.common_name_id),
            .township = strings.get(entry.value_ptr.township_id),
            .scores = entry.value_ptr.*,
            .overall_score = overall_score,
            .rating = ratingForScore(overall_score),
        });
    }
    if (soil_only_count != 0 or climate_only_count != 0) {
        std.debug.print("Coverage notice: omitted {d} soil-only and {d} climate-only crop/township pairs because the input domains do not overlap for those pairs.\n", .{ soil_only_count, climate_only_count });
    }
    std.mem.sort(OutputRow, rows.items, {}, sortRows);

    var output = try writer_mod.Writer.create(allocator, io, output_path);
    defer output.close();
    try output.writeAll("crop_common_name\ttownship_id\twinter_cold_tolerance_score\tprecipitation_suitability_score\tgrowing_season_suitability_score\tsoil_drainage_suitability_score\tsoil_ph_suitability_score\tsoil_texture_suitability_score\ttemperature_suitability_score\toverall_suitability_score\toverall_suitability_rating\tlimitation_notes\n");
    for (rows.items) |row| {
        try output.print("{s}\t{s}\t{d:.1}\t{d:.1}\t{d:.1}\t{d:.1}\t{d:.1}\t{d:.1}\t{d:.1}\t{d:.1}\t{s}\t", .{
            row.common_name,
            row.township,
            row.scores.winter_cold_tolerance_score,
            row.scores.precipitation_suitability_score,
            row.scores.growing_season_score,
            row.scores.drainage_score,
            row.scores.ph_score,
            row.scores.texture_score,
            row.scores.temperature_score,
            row.overall_score,
            row.rating,
        });
        try writeLimitationNotes(&output, row.scores);
        try output.writeAll("\n");
    }
    try output.flush();
}

fn calculateOverallScore(scores: SuitabilityScores) f32 {
    const soil_temperature_mean = (scores.temperature_score + scores.texture_score + scores.drainage_score + scores.ph_score) / 4.0;
    const climate_product = (scores.precipitation_suitability_score * scores.growing_season_score * scores.winter_cold_tolerance_score) / 64.0;
    // Appendix D, figure 6. The printed "0.3" denotes a cube root; retain
    // full precision here so the rating is not changed by display rounding.
    return soil_temperature_mean * std.math.cbrt(climate_product);
}

fn ratingForScore(score: f32) []const u8 {
    if (score >= 3.5) return "Highly Suitable";
    if (score >= 2.5) return "Suitable";
    if (score >= 1.5) return "Moderately Suitable";
    if (score >= 0.5) return "Slightly Suitable";
    return "Unsuitable";
}

fn writeLimitationNotes(output: *writer_mod.Writer, scores: SuitabilityScores) !void {
    var has_note = false;
    try writeLimitationNote(output, &has_note, "winter cold", scores.winter_cold_tolerance_score);
    try writeLimitationNote(output, &has_note, "moisture", scores.precipitation_suitability_score);
    try writeLimitationNote(output, &has_note, "growing season length", scores.growing_season_score);
    try writeLimitationNote(output, &has_note, "soil drainage", scores.drainage_score);
    try writeLimitationNote(output, &has_note, "soil pH", scores.ph_score);
    try writeLimitationNote(output, &has_note, "soil texture", scores.texture_score);
    try writeLimitationNote(output, &has_note, "heat", scores.temperature_score);
    if (!has_note) try output.writeAll("No major limitation identified");
}

fn writeLimitationNote(output: *writer_mod.Writer, has_note: *bool, factor_name: []const u8, score: f32) !void {
    const rating = ratingForScore(score);
    if (std.mem.eql(u8, rating, "Highly Suitable") or std.mem.eql(u8, rating, "Suitable")) return;
    if (!has_note.*) {
        try output.writeAll("May be limited by ");
    } else {
        try output.writeAll(", ");
    }
    try output.writeAll(factor_name);
    has_note.* = true;
}

fn sortRows(_: void, left: OutputRow, right: OutputRow) bool {
    const crop_order = std.mem.order(u8, left.common_name, right.common_name);
    return if (crop_order == .eq) std.mem.lessThan(u8, left.township, right.township) else crop_order == .lt;
}

test "ratings cover all boundaries and reject corrupt scores" {
    try std.testing.expectEqualStrings("Unsuitable", ratingForScore(0.49));
    try std.testing.expectEqualStrings("Slightly Suitable", ratingForScore(0.5));
    try std.testing.expectEqualStrings("Moderately Suitable", ratingForScore(1.5));
    try std.testing.expectEqualStrings("Suitable", ratingForScore(2.5));
    try std.testing.expectEqualStrings("Highly Suitable", ratingForScore(3.5));

    const all_four: SuitabilityScores = .{ .common_name_id = 0, .township_id = 0, .winter_cold_tolerance_score = 4, .precipitation_suitability_score = 4, .growing_season_score = 4, .drainage_score = 4, .ph_score = 4, .texture_score = 4, .temperature_score = 4 };
    try std.testing.expectEqual(@as(f32, 4), calculateOverallScore(all_four));
    const half_climate: SuitabilityScores = .{ .common_name_id = 0, .township_id = 0, .winter_cold_tolerance_score = 4, .precipitation_suitability_score = 4, .growing_season_score = 2, .drainage_score = 4, .ph_score = 4, .texture_score = 4, .temperature_score = 4 };
    try std.testing.expectApproxEqAbs(@as(f32, 4 * std.math.cbrt(@as(f32, 0.5))), calculateOverallScore(half_climate), 0.0001);
    try std.testing.expectEqualStrings("Slightly Suitable", ratingForScore(1.49));

    var accumulator = Accumulator.init(std.testing.allocator);
    defer accumulator.deinit();
    try std.testing.expectError(error.InvalidSuitabilityScore, accumulator.addScore("Onion", "T001R01W4", .temperature, std.math.nan(f32)));
    try accumulator.addScore("Onion", "T001R01W4", .temperature, 4);
    try std.testing.expectError(error.DuplicateSuitabilityScore, accumulator.addScore("Onion", "T001R01W4", .temperature, 3));
}
