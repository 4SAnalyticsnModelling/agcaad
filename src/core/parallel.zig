const std = @import("std");

var configured_thread_count: usize = 1;

pub fn setThreadCount(thread_count: ?usize) void {
    configured_thread_count = thread_count orelse (std.Thread.getCpuCount() catch |err| fallback: {
        std.debug.print("Unable to detect CPU count ({s}); falling back to one worker thread.\n", .{@errorName(err)});
        break :fallback 1;
    });
}

pub fn workerCount(item_count: usize) usize {
    if (item_count == 0) return 0;
    return @min(item_count, @max(configured_thread_count, 1));
}

pub fn chunkStart(item_count: usize, worker_index: usize, workers: usize) usize {
    return item_count / workers * worker_index + item_count % workers * worker_index / workers;
}

pub fn chunkEnd(item_count: usize, worker_index: usize, workers: usize) usize {
    return chunkStart(item_count, worker_index + 1, workers);
}

test "worker counts and chunks cover every item exactly once" {
    setThreadCount(3);
    defer setThreadCount(1);
    try std.testing.expectEqual(@as(usize, 0), workerCount(0));
    try std.testing.expectEqual(@as(usize, 2), workerCount(2));
    try std.testing.expectEqual(@as(usize, 3), workerCount(10));
    try std.testing.expectEqual(@as(usize, 0), chunkStart(10, 0, 3));
    try std.testing.expectEqual(@as(usize, 3), chunkEnd(10, 0, 3));
    try std.testing.expectEqual(chunkEnd(10, 0, 3), chunkStart(10, 1, 3));
    try std.testing.expectEqual(chunkEnd(10, 1, 3), chunkStart(10, 2, 3));
    try std.testing.expectEqual(@as(usize, 10), chunkEnd(10, 2, 3));
}
