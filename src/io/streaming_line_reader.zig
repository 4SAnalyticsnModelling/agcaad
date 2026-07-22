const std = @import("std");

pub const Reader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    file_reader: std.Io.File.Reader,
    read_buffer: []u8,
    header: []const u8,
    delimiter: u8,
    path: []const u8,
    row_number: usize = 1,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Reader {
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
            std.debug.print("Failed to open input file '{s}': {s}\n", .{ path, @errorName(err) });
            return err;
        };
        errdefer file.close(io);
        const read_buffer = try allocator.alloc(u8, 1024 * 1024);
        errdefer allocator.free(read_buffer);
        var file_reader = file.readerStreaming(io, read_buffer);
        const raw_header = (file_reader.interface.takeDelimiter('\n') catch |err| {
            std.debug.print("Failed to read header from '{s}': {s}\n", .{ path, @errorName(err) });
            return err;
        }) orelse {
            std.debug.print("Input file is empty: '{s}'\n", .{path});
            return error.EmptyFile;
        };
        const header = try allocator.dupe(u8, trimLine(raw_header));
        errdefer allocator.free(header);
        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .file_reader = file_reader,
            .read_buffer = read_buffer,
            .header = header,
            .delimiter = if (std.mem.indexOfScalar(u8, header, '\t') != null) '\t' else ',',
            .path = path,
        };
    }

    pub fn close(self: *Reader) void {
        self.allocator.free(self.header);
        self.allocator.free(self.read_buffer);
        self.file.close(self.io);
    }

    pub fn nextLine(self: *Reader) !?[]const u8 {
        while (self.file_reader.interface.takeDelimiter('\n') catch |err| {
            std.debug.print("Failed reading '{s}' near row {d}: {s}\n", .{ self.path, self.row_number + 1, @errorName(err) });
            return err;
        }) |line| {
            self.row_number += 1;
            const trimmed_line = trimLine(line);
            if (trimmed_line.len == 0) continue;
            return trimmed_line;
        }
        return null;
    }

    pub fn columnIndex(self: Reader, name: []const u8) !usize {
        var column_index: usize = 0;
        var cells = std.mem.splitScalar(u8, self.header, self.delimiter);
        while (cells.next()) |header_cell| : (column_index += 1) {
            if (std.mem.eql(u8, trimCell(header_cell), name)) return column_index;
        }
        std.debug.print("Missing required column '{s}' in '{s}'\n", .{ name, self.path });
        return error.MissingColumn;
    }

    pub fn cell(self: Reader, line: []const u8, target_column_index: usize) ![]const u8 {
        var column_index: usize = 0;
        var cells = std.mem.splitScalar(u8, line, self.delimiter);
        while (cells.next()) |cell_text| : (column_index += 1) {
            if (column_index == target_column_index) return trimCell(cell_text);
        }
        std.debug.print("Missing cell in '{s}' at row {d}, column index {d}\n", .{ self.path, self.row_number, target_column_index });
        return error.MissingCell;
    }

    pub fn projectCells(self: Reader, comptime count: usize, line: []const u8, target_column_indexes: [count]usize) ![count][]const u8 {
        var result: [count][]const u8 = undefined;
        var found: [count]bool = @splat(false);
        var found_count: usize = 0;
        var column_index: usize = 0;
        var split = std.mem.splitScalar(u8, line, self.delimiter);
        while (split.next()) |cell_text| : (column_index += 1) {
            inline for (target_column_indexes, 0..) |target_column_index, target_index| {
                if (!found[target_index] and column_index == target_column_index) {
                    result[target_index] = trimCell(cell_text);
                    found[target_index] = true;
                    found_count += 1;
                }
            }
            if (found_count == count) return result;
        }
        inline for (found, 0..) |was_found, target_index| {
            if (!was_found) std.debug.print("Missing cell in '{s}' at row {d}, column index {d}\n", .{ self.path, self.row_number, target_column_indexes[target_index] });
        }
        return error.MissingCell;
    }

    pub fn intCell(self: Reader, comptime T: type, line: []const u8, target_column_index: usize, column_name: []const u8) !T {
        return @import("parse.zig").integer(T, self.path, self.row_number, column_name, try self.cell(line, target_column_index));
    }

    pub fn floatCell(self: Reader, comptime T: type, line: []const u8, target_column_index: usize, column_name: []const u8) !T {
        return @import("parse.zig").float(T, self.path, self.row_number, column_name, try self.cell(line, target_column_index));
    }
};

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \r\n");
}

fn trimCell(cell: []const u8) []const u8 {
    var trimmed_cell = std.mem.trim(u8, cell, " \r");
    if (std.mem.startsWith(u8, trimmed_cell, "\xEF\xBB\xBF")) trimmed_cell = trimmed_cell[3..];
    if (trimmed_cell.len >= 2 and trimmed_cell[0] == '"' and trimmed_cell[trimmed_cell.len - 1] == '"') {
        return trimmed_cell[1 .. trimmed_cell.len - 1];
    }
    return trimmed_cell;
}
