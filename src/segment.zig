//! 把一个文件切成若干个字节区间，每个区间由一个并发任务负责下载。
const std = @import("std");
const Allocator = std.mem.Allocator;

/// 每个分段至少这么大，避免小文件开太多连接。
pub const default_min_segment: u64 = 1024 * 1024;

pub const Segment = struct {
    start: u64,
    /// 不包含。null 表示文件大小未知，只能用单个分段读到 EOF。
    end: ?u64,
    /// 已写入文件的字节数。下载任务写，进度条和状态文件并发读。
    done: std.atomic.Value(u64) = .init(0),

    pub fn init(start: u64, end: ?u64, done: u64) Segment {
        return .{ .start = start, .end = end, .done = .init(done) };
    }

    pub fn doneBytes(s: *const Segment) u64 {
        return s.done.load(.monotonic);
    }

    /// 下一次要写入的文件偏移。
    pub fn offset(s: *const Segment) u64 {
        return s.start + s.doneBytes();
    }

    /// 剩余字节数；大小未知时为 null。
    pub fn remaining(s: *const Segment) ?u64 {
        const end = s.end orelse return null;
        return end - s.offset();
    }

    pub fn isComplete(s: *const Segment) bool {
        const r = s.remaining() orelse return false;
        return r == 0;
    }
};

/// 按连接数均分文件，最后一段承担余数。
pub fn split(gpa: Allocator, size: ?u64, connections: u32, min_segment: u64) Allocator.Error![]Segment {
    const total = size orelse {
        const segs = try gpa.alloc(Segment, 1);
        segs[0] = .init(0, null, 0);
        return segs;
    };
    const max_by_size: u64 = @max(1, total / @max(1, min_segment));
    const n: u64 = @max(1, @min(@as(u64, connections), max_by_size));
    const segs = try gpa.alloc(Segment, @intCast(n));
    const chunk = total / n;
    for (segs, 0..) |*s, i| {
        const start = chunk * i;
        const end = if (i == n - 1) total else start + chunk;
        s.* = .init(start, end, 0);
    }
    return segs;
}

pub fn totalDone(segs: []const Segment) u64 {
    var sum: u64 = 0;
    for (segs) |*s| sum += s.doneBytes();
    return sum;
}

test "split evenly with remainder" {
    const gpa = std.testing.allocator;
    const segs = try split(gpa, 10 * 1024 * 1024 + 3, 4, default_min_segment);
    defer gpa.free(segs);
    try std.testing.expectEqual(@as(usize, 4), segs.len);
    try std.testing.expectEqual(@as(u64, 0), segs[0].start);
    var covered: u64 = 0;
    for (segs, 0..) |s, i| {
        try std.testing.expectEqual(covered, s.start);
        covered = s.end.?;
        if (i + 1 < segs.len) try std.testing.expectEqual(s.end.?, segs[i + 1].start);
    }
    try std.testing.expectEqual(@as(u64, 10 * 1024 * 1024 + 3), covered);
}

test "small files use fewer connections" {
    const gpa = std.testing.allocator;
    const tiny = try split(gpa, 100, 8, default_min_segment);
    defer gpa.free(tiny);
    try std.testing.expectEqual(@as(usize, 1), tiny.len);
    try std.testing.expectEqual(@as(?u64, 100), tiny[0].end);

    const three = try split(gpa, 3 * default_min_segment + 5, 16, default_min_segment);
    defer gpa.free(three);
    try std.testing.expectEqual(@as(usize, 3), three.len);
}

test "empty and unknown size" {
    const gpa = std.testing.allocator;
    const empty = try split(gpa, 0, 8, default_min_segment);
    defer gpa.free(empty);
    try std.testing.expectEqual(@as(usize, 1), empty.len);
    try std.testing.expect(empty[0].isComplete());

    const unknown = try split(gpa, null, 8, default_min_segment);
    defer gpa.free(unknown);
    try std.testing.expectEqual(@as(usize, 1), unknown.len);
    try std.testing.expect(unknown[0].remaining() == null);
    try std.testing.expect(!unknown[0].isComplete());
}
