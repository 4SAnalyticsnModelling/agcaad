const std = @import("std");
const texture = @import("soil/texture.zig");
const ph = @import("soil/ph.zig");
const drainage = @import("soil/drainage.zig");
const precip_suitability = @import("climate/precip_suitability.zig");
const winter_cold = @import("climate/winter_cold.zig");
const growing_season = @import("climate/growing_season.zig");
const temperature_suitability = @import("climate/temperature_suitability.zig");
const final_rating = @import("suitability/final_rating.zig");
const parallel = @import("core/parallel.zig");

const Usage =
    \\AgCAAD modernization
    \\
    \\Usage:
    \\  agcaad --input <input-root> --output <output-root> --threads <auto|number>
    \\
    \\Inputs may be comma- or tab-delimited .txt files.
    \\Outputs are tab-delimited .txt files.
    \\
;

const Options = struct {
    input_root: ?[]const u8 = null,
    output_root: ?[]const u8 = null,
    thread_count: ?usize = null,
    threads_seen: bool = false,
};

pub fn main(process_init: std.process.Init) !void {
    const allocator = process_init.gpa;

    var argument_iterator = try process_init.minimal.args.iterateAllocator(allocator);
    defer argument_iterator.deinit();

    _ = argument_iterator.next();
    var options: Options = .{};
    while (argument_iterator.next()) |argument| {
        const value = argument_iterator.next() orelse return usageError(error.MissingArgumentValue);
        if (std.mem.eql(u8, argument, "--input")) {
            if (options.input_root != null) return usageError(error.DuplicateArgument);
            options.input_root = value;
        } else if (std.mem.eql(u8, argument, "--output")) {
            if (options.output_root != null) return usageError(error.DuplicateArgument);
            options.output_root = value;
        } else if (std.mem.eql(u8, argument, "--threads")) {
            if (options.threads_seen) return usageError(error.DuplicateArgument);
            options.threads_seen = true;
            if (!std.mem.eql(u8, value, "auto")) {
                const count = std.fmt.parseInt(usize, value, 10) catch return usageError(error.InvalidThreadCount);
                if (count == 0) return usageError(error.InvalidThreadCount);
                options.thread_count = count;
            }
        } else {
            return usageError(error.UnknownArgument);
        }
    }
    const input_root = options.input_root orelse return usageError(error.MissingRequiredArgument);
    const output_root = options.output_root orelse return usageError(error.MissingRequiredArgument);
    if (!options.threads_seen) return usageError(error.MissingRequiredArgument);
    parallel.setThreadCount(options.thread_count);

    try ensureOutputLayout(process_init.io, output_root);

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
}

fn usageError(err: anyerror) anyerror {
    std.debug.print("{s}", .{Usage});
    return err;
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
