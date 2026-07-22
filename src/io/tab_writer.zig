const std = @import("std");

pub const Writer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    file_writer: std.Io.File.Writer,
    buffer: []u8,
    path: []const u8,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Writer {
        const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
            std.debug.print("Failed to create output file '{s}': {s}\n", .{ path, @errorName(err) });
            return err;
        };
        errdefer file.close(io);
        const buffer = try allocator.alloc(u8, 64 * 1024);
        errdefer allocator.free(buffer);
        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .file_writer = file.writerStreaming(io, buffer),
            .buffer = buffer,
            .path = path,
        };
    }

    pub fn close(self: *Writer) void {
        self.file.close(self.io);
        self.allocator.free(self.buffer);
    }

    pub fn flush(self: *Writer) !void {
        self.file_writer.interface.flush() catch |err| {
            std.debug.print("Failed to flush output file '{s}': {s}\n", .{ self.path, @errorName(err) });
            return err;
        };
    }

    pub fn print(self: *Writer, comptime format: []const u8, args: anytype) !void {
        self.file_writer.interface.print(format, args) catch |err| {
            std.debug.print("Failed writing output file '{s}': {s}\n", .{ self.path, @errorName(err) });
            return err;
        };
    }

    pub fn writeAll(self: *Writer, bytes: []const u8) !void {
        self.file_writer.interface.writeAll(bytes) catch |err| {
            std.debug.print("Failed writing output file '{s}': {s}\n", .{ self.path, @errorName(err) });
            return err;
        };
    }
};
