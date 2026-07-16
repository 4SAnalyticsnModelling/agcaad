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
    std.Io.Dir.cwd().access(io, preferred_txt_path, .{}) catch {
        if (!std.mem.endsWith(u8, preferred_txt_path, ".txt")) return allocator.dupe(u8, preferred_txt_path);
        const fallback_csv_path = try allocator.alloc(u8, preferred_txt_path.len);
        @memcpy(fallback_csv_path[0 .. preferred_txt_path.len - 3], preferred_txt_path[0 .. preferred_txt_path.len - 3]);
        @memcpy(fallback_csv_path[preferred_txt_path.len - 3 ..], "csv");
        return fallback_csv_path;
    };
    return allocator.dupe(u8, preferred_txt_path);
}

pub fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch {
        return false;
    };
    return true;
}

pub fn generatedOrInputPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    output_txt_path: []const u8,
    input_txt_path: []const u8,
) ![]const u8 {
    if (exists(io, output_txt_path)) return allocator.dupe(u8, output_txt_path);
    return existingInputPath(allocator, io, input_txt_path);
}
