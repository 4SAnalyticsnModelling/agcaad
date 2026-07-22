const std = @import("std");

pub const Header = struct {
    names: []const []const u8,
    path: []const u8,

    pub fn deinit(self: Header, allocator: std.mem.Allocator) void {
        for (self.names) |name| allocator.free(name);
        allocator.free(self.names);
    }

    pub fn columnIndex(self: Header, name: []const u8) !usize {
        for (self.names, 0..) |header_name, column_index| {
            if (std.mem.eql(u8, header_name, name)) return column_index;
        }
        std.debug.print("Missing required column '{s}' in '{s}'\n", .{ name, self.path });
        return error.MissingColumn;
    }
};

pub const Reader = struct {
    allocator: std.mem.Allocator,
    file_bytes: []const u8,
    delimiter: u8,
    header: Header,
    remaining_lines: std.mem.SplitIterator(u8, .scalar),
    path: []const u8,
    row_number: usize = 1,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Reader {
        const file_bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| {
            std.debug.print("Failed to read input file '{s}': {s}\n", .{ path, @errorName(err) });
            return err;
        };
        errdefer allocator.free(file_bytes);

        var lines = std.mem.splitScalar(u8, file_bytes, '\n');
        const raw_header_line = lines.next() orelse {
            std.debug.print("Input file is empty: '{s}'\n", .{path});
            return error.EmptyFile;
        };
        const header_line = trimByteOrderMark(trimLine(raw_header_line));
        const delimiter: u8 = if (std.mem.indexOfScalar(u8, header_line, '\t') != null) '\t' else ',';
        const header = try parseHeader(allocator, path, header_line, delimiter);

        return .{
            .allocator = allocator,
            .file_bytes = file_bytes,
            .delimiter = delimiter,
            .header = header,
            .remaining_lines = lines,
            .path = path,
        };
    }

    pub fn close(self: *Reader) void {
        self.header.deinit(self.allocator);
        self.allocator.free(self.file_bytes);
    }

    pub fn nextRow(self: *Reader) ?RowView {
        while (self.remaining_lines.next()) |raw_line| {
            self.row_number += 1;
            const line = trimLine(raw_line);
            if (line.len == 0) continue;
            return .{ .line = line, .delimiter = self.delimiter, .path = self.path, .row_number = self.row_number };
        }
        return null;
    }
};

pub const RowView = struct {
    line: []const u8,
    delimiter: u8,
    path: []const u8,
    row_number: usize,

    pub fn cell(self: RowView, target_column_index: usize) ![]const u8 {
        var column_index: usize = 0;
        var cells = std.mem.splitScalar(u8, self.line, self.delimiter);
        while (cells.next()) |raw_cell| : (column_index += 1) {
            if (column_index == target_column_index) return trimCell(raw_cell);
        }
        std.debug.print("Missing cell in '{s}' at row {d}, column index {d}\n", .{ self.path, self.row_number, target_column_index });
        return error.MissingCell;
    }

    pub fn intCell(self: RowView, comptime T: type, target_column_index: usize, column_name: []const u8) !T {
        return @import("parse.zig").integer(T, self.path, self.row_number, column_name, try self.cell(target_column_index));
    }

    pub fn floatCell(self: RowView, comptime T: type, target_column_index: usize, column_name: []const u8) !T {
        return @import("parse.zig").float(T, self.path, self.row_number, column_name, try self.cell(target_column_index));
    }

    pub fn boundedFloatCell(self: RowView, comptime T: type, target_column_index: usize, column_name: []const u8, minimum: T, maximum: T) !T {
        const value = try self.floatCell(T, target_column_index, column_name);
        if (value < minimum or value > maximum) {
            std.debug.print("Out-of-range number in '{s}' at row {d}, column '{s}': {d} (expected {d}..{d})\n", .{ self.path, self.row_number, column_name, value, minimum, maximum });
            return error.ValueOutOfRange;
        }
        return value;
    }
};

fn parseHeader(allocator: std.mem.Allocator, path: []const u8, header_line: []const u8, delimiter: u8) !Header {
    var header_names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (header_names.items) |name| allocator.free(name);
        header_names.deinit(allocator);
    }

    var cells = std.mem.splitScalar(u8, header_line, delimiter);
    while (cells.next()) |raw_cell| {
        try header_names.append(allocator, try allocator.dupe(u8, trimCell(raw_cell)));
    }

    return .{ .names = try header_names.toOwnedSlice(allocator), .path = path };
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \r\n");
}

fn trimByteOrderMark(line: []const u8) []const u8 {
    const utf8_bom = "\xEF\xBB\xBF";
    if (std.mem.startsWith(u8, line, utf8_bom)) return line[utf8_bom.len..];
    return line;
}

fn trimCell(cell: []const u8) []const u8 {
    const trimmed_cell = std.mem.trim(u8, cell, " \r");
    if (trimmed_cell.len >= 2 and trimmed_cell[0] == '"' and trimmed_cell[trimmed_cell.len - 1] == '"') {
        return trimmed_cell[1 .. trimmed_cell.len - 1];
    }
    return trimmed_cell;
}

test "row views parse quoted example-style cells and bounded values" {
    const row: RowView = .{ .line = "T001R17W4,\"W\",0.412703374", .delimiter = ',', .path = "fixture.txt", .row_number = 2 };
    try std.testing.expectEqualStrings("T001R17W4", try row.cell(0));
    try std.testing.expectEqualStrings("W", try row.cell(1));
    try std.testing.expectApproxEqAbs(@as(f32, 0.412703374), try row.boundedFloatCell(f32, 2, "soil_component_area_fraction", 0, 1), 0.000001);
}
