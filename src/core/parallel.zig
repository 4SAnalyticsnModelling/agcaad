const std = @import("std");

var configured_thread_count: ?usize = null;

pub fn setThreadCount(thread_count: ?usize) void {
    configured_thread_count = thread_count;
}

pub fn workerCount(item_count: usize) usize {
    if (item_count == 0) return 0;
    const requested_count = configured_thread_count orelse (std.Thread.getCpuCount() catch 1);
    return @min(item_count, @max(requested_count, 1));
}

pub fn chunkStart(item_count: usize, worker_index: usize, workers: usize) usize {
    return item_count * worker_index / workers;
}

pub fn chunkEnd(item_count: usize, worker_index: usize, workers: usize) usize {
    return item_count * (worker_index + 1) / workers;
}
