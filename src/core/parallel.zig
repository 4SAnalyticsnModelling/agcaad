const std = @import("std");

pub fn workerCount(item_count: usize) usize {
    if (item_count == 0) return 0;
    const cpu_count = std.Thread.getCpuCount() catch 1;
    return @min(item_count, @max(cpu_count, 1));
}

pub fn chunkStart(item_count: usize, worker_index: usize, workers: usize) usize {
    return item_count * worker_index / workers;
}

pub fn chunkEnd(item_count: usize, worker_index: usize, workers: usize) usize {
    return item_count * (worker_index + 1) / workers;
}
