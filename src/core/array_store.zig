const std = @import("std");

pub const StringInterner = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList([]const u8) = .empty,
    lookup: std.StringHashMap(u32),

    pub fn init(allocator: std.mem.Allocator) StringInterner {
        return .{
            .allocator = allocator,
            .lookup = std.StringHashMap(u32).init(allocator),
        };
    }

    pub fn deinit(self: *StringInterner) void {
        for (self.values.items) |value| self.allocator.free(value);
        self.values.deinit(self.allocator);
        self.lookup.deinit();
    }

    pub fn intern(self: *StringInterner, value: []const u8) !u32 {
        if (self.lookup.get(value)) |existing_id| return existing_id;
        if (self.values.items.len > std.math.maxInt(u32)) {
            std.debug.print("Too many unique strings to intern: maximum supported count is {d}\n", .{std.math.maxInt(u32) + 1});
            return error.TooManyUniqueStrings;
        }
        const owned_value = try self.allocator.dupe(u8, value);
        const new_id: u32 = @intCast(self.values.items.len);
        try self.values.append(self.allocator, owned_value);
        try self.lookup.put(owned_value, new_id);
        return new_id;
    }

    pub fn get(self: StringInterner, id: u32) []const u8 {
        return self.values.items[id];
    }
};

test "string interner deduplicates values and preserves identifiers" {
    var strings = StringInterner.init(std.testing.allocator);
    defer strings.deinit();
    const first = try strings.intern("T001R01W4");
    const second = try strings.intern("Onion");
    try std.testing.expectEqual(first, try strings.intern("T001R01W4"));
    try std.testing.expect(first != second);
    try std.testing.expectEqualStrings("Onion", strings.get(second));
}
