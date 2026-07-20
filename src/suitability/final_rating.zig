const std = @import("std");
const math = @import("../core/math.zig");
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
};

const SuitabilityScores = struct {
    common_name: []const u8,
    township_id: []const u8,
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
    key: []const u8,
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
    scores: std.StringHashMap(SuitabilityScores),

    pub fn init(allocator: std.mem.Allocator) Accumulator {
        return .{ .allocator = allocator, .scores = std.StringHashMap(SuitabilityScores).init(allocator) };
    }

    pub fn deinit(self: *Accumulator) void {
        var it = self.scores.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.common_name);
            self.allocator.free(entry.value_ptr.township_id);
        }
        self.scores.deinit();
    }

    pub fn addScore(self: *Accumulator, crop_common_name: []const u8, township_id: []const u8, field: Field, value: f32) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{s}\t{s}", .{ crop_common_name, township_id });
        const entry = try self.scores.getOrPut(key);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{
                .common_name = try self.allocator.dupe(u8, crop_common_name),
                .township_id = try self.allocator.dupe(u8, township_id),
            };
        } else {
            self.allocator.free(key);
        }
        setScoreField(entry.value_ptr, field, value);
        entry.value_ptr.present_mask |= maskForField(field);
    }

    pub fn write(self: Accumulator, io: std.Io, output_path: []const u8) !void {
        try writeFinalRatings(self.allocator, io, self.scores, output_path);
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

fn writeFinalRatings(allocator: std.mem.Allocator, io: std.Io, scores: std.StringHashMap(SuitabilityScores), output_path: []const u8) !void {
    var rows: std.ArrayList(OutputRow) = .empty;
    defer rows.deinit(allocator);
    var it = scores.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.present_mask != ScoreMask.complete) continue;
        const overall_score = calculateOverallScore(entry.value_ptr.*);
        try rows.append(allocator, .{
            .key = entry.key_ptr.*,
            .scores = entry.value_ptr.*,
            .overall_score = overall_score,
            .rating = ratingForScore(overall_score),
        });
    }
    std.mem.sort(OutputRow, rows.items, {}, sortRows);

    var output = writer_mod.Writer.create(allocator, io, output_path);
    defer output.close();
    try output.writeAll("crop_common_name\ttownship_id\twinter_cold_tolerance_score\tprecipitation_suitability_score\tgrowing_season_suitability_score\tsoil_drainage_suitability_score\tsoil_ph_suitability_score\tsoil_texture_suitability_score\ttemperature_suitability_score\toverall_suitability_score\toverall_suitability_rating\tlimitation_notes\n");
    for (rows.items) |row| {
        try output.print("{s}\t{s}\t{d:.1}\t{d:.1}\t{d:.1}\t{d:.1}\t{d:.1}\t{d:.1}\t{d:.1}\t{d:.1}\t{s}\t", .{
            row.scores.common_name,
            row.scores.township_id,
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
    return math.roundToOneDecimal(soil_temperature_mean * std.math.pow(f32, climate_product, 1.0 / 3.0));
}

fn ratingForScore(score: f32) []const u8 {
    if (score > 3.5) return "Highly Suitable";
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
    return std.mem.lessThan(u8, left.key, right.key);
}
