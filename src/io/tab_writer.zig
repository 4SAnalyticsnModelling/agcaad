const std = @import("std");

pub const Writer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    file_writer: std.Io.File.Writer,
    buffer: []u8,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Writer {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        errdefer file.close(io);
        const buffer = try allocator.alloc(u8, 64 * 1024);
        errdefer allocator.free(buffer);
        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .file_writer = file.writerStreaming(io, buffer),
            .buffer = buffer,
        };
    }

    pub fn close(self: *Writer) void {
        self.file.close(self.io);
        self.allocator.free(self.buffer);
    }

    pub fn flush(self: *Writer) !void {
        try self.file_writer.interface.flush();
    }

    pub fn print(self: *Writer, comptime format: []const u8, args: anytype) !void {
        try self.file_writer.interface.print(format, args);
    }

    pub fn writeAll(self: *Writer, bytes: []const u8) !void {
        try self.file_writer.interface.writeAll(bytes);
    }
};
