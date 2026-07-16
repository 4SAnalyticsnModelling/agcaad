const std = @import("std");
const texture = @import("soil/texture.zig");
const ph = @import("soil/ph.zig");
const drainage = @import("soil/drainage.zig");
const precip_suitability = @import("climate/precip_suitability.zig");
const winter_cold = @import("climate/winter_cold.zig");
const growing_season = @import("climate/growing_season.zig");
const temperature_suitability = @import("climate/temperature_suitability.zig");
const final_rating = @import("suitability/final_rating.zig");

const Usage =
    \\AgCAAD modernization
    \\
    \\Usage:
    \\  agcaad run <input-root> <output-root>
    \\  agcaad texture <input-root> <output-root>
    \\  agcaad ph <input-root> <output-root>
    \\  agcaad drainage <input-root> <output-root>
    \\  agcaad precip-score <input-root> <output-root>
    \\  agcaad winter-cold <input-root> <output-root>
    \\  agcaad growing-season <input-root> <output-root>
    \\  agcaad temp-score <input-root> <output-root>
    \\  agcaad final <input-root> <output-root>
    \\
    \\Inputs may be comma- or tab-delimited .txt files.
    \\Outputs are tab-delimited .txt files.
    \\
;

pub fn main(process_init: std.process.Init) !void {
    const allocator = process_init.gpa;

    var argument_iterator = try process_init.minimal.args.iterateAllocator(allocator);
    defer argument_iterator.deinit();

    _ = argument_iterator.next();
    const command = argument_iterator.next() orelse {
        std.debug.print("{s}", .{Usage});
        return;
    };
    const input_root = argument_iterator.next() orelse {
        std.debug.print("{s}", .{Usage});
        return;
    };
    const output_root = argument_iterator.next() orelse {
        std.debug.print("{s}", .{Usage});
        return;
    };
    const optional_weather_input = argument_iterator.next();

    try ensureOutputLayout(process_init.io, output_root);

    if (std.mem.eql(u8, command, "run")) {
        if (optional_weather_input != null) return error.UnexpectedWeatherInputForInMemoryRun;
        var final_scores = final_rating.Accumulator.init(allocator);
        defer final_scores.deinit();

        try texture.addToFinalAccumulator(allocator, process_init.io, input_root, &final_scores);
        try ph.addToFinalAccumulator(allocator, process_init.io, input_root, &final_scores);
        try drainage.addToFinalAccumulator(allocator, process_init.io, input_root, &final_scores);
        try precip_suitability.addToFinalAccumulator(allocator, process_init.io, input_root, &final_scores);
        try winter_cold.addToFinalAccumulator(allocator, process_init.io, input_root, &final_scores);
        try growing_season.addToFinalAccumulator(allocator, process_init.io, input_root, &final_scores);
        try temperature_suitability.addToFinalAccumulator(allocator, process_init.io, input_root, &final_scores);

        const output_paths = @import("paths.zig").Paths.init(output_root);
        const final_output_path = try output_paths.join(allocator, &.{"crop_suitability_rankings_and_overall_ratings.txt"});
        defer allocator.free(final_output_path);
        try final_scores.write(process_init.io, final_output_path);
        std.debug.print("AgCAAD run completed.\n", .{});
    } else if (std.mem.eql(u8, command, "texture")) {
        try texture.run(allocator, process_init.io, input_root, output_root);
    } else if (std.mem.eql(u8, command, "ph")) {
        try ph.run(allocator, process_init.io, input_root, output_root);
    } else if (std.mem.eql(u8, command, "drainage")) {
        try drainage.run(allocator, process_init.io, input_root, output_root);
    } else if (std.mem.eql(u8, command, "precip-score")) {
        try precip_suitability.run(allocator, process_init.io, input_root, output_root);
    } else if (std.mem.eql(u8, command, "winter-cold")) {
        try winter_cold.run(allocator, process_init.io, input_root, output_root);
    } else if (std.mem.eql(u8, command, "growing-season")) {
        try growing_season.run(allocator, process_init.io, input_root, output_root);
    } else if (std.mem.eql(u8, command, "temp-score")) {
        try temperature_suitability.run(allocator, process_init.io, input_root, output_root);
    } else if (std.mem.eql(u8, command, "final")) {
        try final_rating.run(allocator, process_init.io, input_root, output_root);
    } else {
        std.debug.print("{s}", .{Usage});
        return error.UnknownCommand;
    }
}

fn ensureOutputLayout(io: std.Io, output_root: []const u8) !void {
    std.Io.Dir.cwd().createDir(io, output_root, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

test {
    _ = @import("io/delimited_reader.zig");
}
