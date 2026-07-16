const std = @import("std");

pub const Header = struct {
    names: []const []const u8,

    pub fn deinit(self: Header, allocator: std.mem.Allocator) void {
        for (self.names) |name| allocator.free(name);
        allocator.free(self.names);
    }

    pub fn columnIndex(self: Header, name: []const u8) !usize {
        for (self.names, 0..) |header_name, column_index| {
            if (std.mem.eql(u8, header_name, name)) return column_index;
        }
        return error.MissingColumn;
    }
};

pub const Reader = struct {
    allocator: std.mem.Allocator,
    file_bytes: []const u8,
    delimiter: u8,
    header: Header,
    remaining_lines: std.mem.SplitIterator(u8, .scalar),

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Reader {
        const file_bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
        errdefer allocator.free(file_bytes);

        var lines = std.mem.splitScalar(u8, file_bytes, '\n');
        const raw_header_line = lines.next() orelse return error.EmptyFile;
        const header_line = trimByteOrderMark(trimLine(raw_header_line));
        const delimiter: u8 = if (std.mem.indexOfScalar(u8, header_line, '\t') != null) '\t' else ',';
        const header = try parseHeader(allocator, header_line, delimiter);

        return .{
            .allocator = allocator,
            .file_bytes = file_bytes,
            .delimiter = delimiter,
            .header = header,
            .remaining_lines = lines,
        };
    }

    pub fn close(self: *Reader) void {
        self.header.deinit(self.allocator);
        self.allocator.free(self.file_bytes);
    }

    pub fn nextRow(self: *Reader) ?RowView {
        while (self.remaining_lines.next()) |raw_line| {
            const line = trimLine(raw_line);
            if (line.len == 0) continue;
            return .{ .line = line, .delimiter = self.delimiter };
        }
        return null;
    }
};

pub const RowView = struct {
    line: []const u8,
    delimiter: u8,

    pub fn cell(self: RowView, target_column_index: usize) ![]const u8 {
        var column_index: usize = 0;
        var cells = std.mem.splitScalar(u8, self.line, self.delimiter);
        while (cells.next()) |raw_cell| : (column_index += 1) {
            if (column_index == target_column_index) return trimCell(raw_cell);
        }
        return error.MissingCell;
    }
};

fn parseHeader(allocator: std.mem.Allocator, header_line: []const u8, delimiter: u8) !Header {
    var header_names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (header_names.items) |name| allocator.free(name);
        header_names.deinit(allocator);
    }

    var cells = std.mem.splitScalar(u8, header_line, delimiter);
    while (cells.next()) |raw_cell| {
        try header_names.append(allocator, try allocator.dupe(u8, trimCell(raw_cell)));
    }

    return .{ .names = try header_names.toOwnedSlice(allocator) };
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
