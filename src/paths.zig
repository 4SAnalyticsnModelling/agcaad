const std = @import("std");

pub const Paths = struct {
    root: []const u8,

    pub fn init(root: []const u8) Paths {
        return .{ .root = root };
    }

    pub fn join(self: Paths, allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
        var all = try allocator.alloc([]const u8, parts.len + 1);
        defer allocator.free(all);
        all[0] = self.root;
        for (parts, 0..) |part, i| all[i + 1] = part;
        return std.fs.path.join(allocator, all);
    }
};

pub fn existingInputPath(allocator: std.mem.Allocator, io: std.Io, preferred_txt_path: []const u8) ![]const u8 {
    var txt_exists = true;
    std.Io.Dir.cwd().access(io, preferred_txt_path, .{}) catch |txt_err| switch (txt_err) {
        error.FileNotFound => txt_exists = false,
        else => {
            std.debug.print("Cannot access required input file '{s}': {s}\n", .{ preferred_txt_path, @errorName(txt_err) });
            return txt_err;
        },
    };
    if (txt_exists) return allocator.dupe(u8, preferred_txt_path);
    if (!std.mem.endsWith(u8, preferred_txt_path, ".txt")) {
        std.debug.print("Required input file not found: '{s}'\n", .{preferred_txt_path});
        return error.FileNotFound;
    }
    const fallback_csv_path = try allocator.alloc(u8, preferred_txt_path.len);
    errdefer allocator.free(fallback_csv_path);
    @memcpy(fallback_csv_path[0 .. preferred_txt_path.len - 3], preferred_txt_path[0 .. preferred_txt_path.len - 3]);
    @memcpy(fallback_csv_path[preferred_txt_path.len - 3 ..], "csv");
    std.Io.Dir.cwd().access(io, fallback_csv_path, .{}) catch |csv_err| {
        std.debug.print("Required input file not found as either '{s}' or '{s}': {s}\n", .{ preferred_txt_path, fallback_csv_path, @errorName(csv_err) });
        return csv_err;
    };
    return fallback_csv_path;
}
