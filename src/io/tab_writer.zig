const std = @import("std");

pub const Writer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    bytes: std.ArrayList(u8) = .empty,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, path: []const u8) Writer {
        return .{
            .allocator = allocator,
            .io = io,
            .path = path,
        };
    }

    pub fn close(self: *Writer) void {
        self.bytes.deinit(self.allocator);
    }

    pub fn flush(self: *Writer) !void {
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = self.path,
            .data = self.bytes.items,
        });
    }

    pub fn print(self: *Writer, comptime format: []const u8, args: anytype) !void {
        const formatted_text = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(formatted_text);
        try self.bytes.appendSlice(self.allocator, formatted_text);
    }

    pub fn writeAll(self: *Writer, bytes: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, bytes);
    }
};
