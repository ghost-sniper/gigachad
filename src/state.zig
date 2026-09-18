//! 断点续传状态文件 `<输出文件>.gigachad`。
//!
//! 文本格式：
//!   gigachad 1
//!   size <文件总大小>
//!   url <原始 URL>
//!   seg <start> <end> <done>   （每个分段一行）
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Segment = @import("segment.zig").Segment;

pub const suffix = ".gigachad";
const magic = "gigachad 1";

pub const State = struct {
    url: []const u8,
    size: u64,
    segments: []Segment,

    pub fn deinit(s: State, gpa: Allocator) void {
        gpa.free(s.url);
        gpa.free(s.segments);
    }
};

pub fn serialize(w: *Io.Writer, url: []const u8, size: u64, segs: []const Segment) Io.Writer.Error!void {
    try w.print("{s}\nsize {d}\nurl {s}\n", .{ magic, size, url });
    for (segs) |*s| {
        try w.print("seg {d} {d} {d}\n", .{ s.start, s.end.?, s.doneBytes() });
    }
}

pub const ParseError = error{InvalidStateFile} || Allocator.Error;

pub fn parse(gpa: Allocator, text: []const u8) ParseError!State {
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    if (!std.mem.eql(u8, lines.next() orelse return error.InvalidStateFile, magic))
        return error.InvalidStateFile;

    var size: ?u64 = null;
    var url: ?[]const u8 = null;
    var segs: std.ArrayList(Segment) = .empty;
    errdefer segs.deinit(gpa);

    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "size ")) {
            size = std.fmt.parseInt(u64, line[5..], 10) catch return error.InvalidStateFile;
        } else if (std.mem.startsWith(u8, line, "url ")) {
            url = line[4..];
        } else if (std.mem.startsWith(u8, line, "seg ")) {
            var it = std.mem.tokenizeScalar(u8, line[4..], ' ');
            var nums: [3]u64 = undefined;
            for (&nums) |*n| {
                const tok = it.next() orelse return error.InvalidStateFile;
                n.* = std.fmt.parseInt(u64, tok, 10) catch return error.InvalidStateFile;
            }
            const start, const end, const done = nums;
            if (end < start or done > end - start) return error.InvalidStateFile;
            try segs.append(gpa, .init(start, end, done));
        } else return error.InvalidStateFile;
    }

    const total = size orelse return error.InvalidStateFile;
    if (url == null or segs.items.len == 0) return error.InvalidStateFile;

    // 分段必须首尾相接、恰好覆盖整个文件。
    var expect: u64 = 0;
    for (segs.items) |*s| {
        if (s.start != expect) return error.InvalidStateFile;
        expect = s.end.?;
    }
    if (expect != total) return error.InvalidStateFile;

    const url_copy = try gpa.dupe(u8, url.?);
    errdefer gpa.free(url_copy);
    return .{ .url = url_copy, .size = total, .segments = try segs.toOwnedSlice(gpa) };
}

/// 读取状态文件；文件不存在或内容损坏时返回 null。
pub fn load(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) Allocator.Error!?State {
    const text = dir.readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return null,
    };
    defer gpa.free(text);
    return parse(gpa, text) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.InvalidStateFile => null,
    };
}

/// 先写临时文件再 rename，保证中途退出时不会留下写了一半的状态文件。
pub fn save(io: Io, dir: Io.Dir, path: []const u8, url: []const u8, size: u64, segs: []const Segment) !void {
    var buf: [64 * 1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    serialize(&w, url, size, segs) catch return error.StateTooLarge;

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return error.NameTooLong;
    try dir.writeFile(io, .{ .sub_path = tmp, .data = w.buffered() });
    try dir.rename(tmp, dir, path, io);
}

test "roundtrip" {
    const gpa = std.testing.allocator;
    var segs = [_]Segment{ .init(0, 100, 40), .init(100, 250, 150) };

    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try serialize(&w, "https://example.com/a b", 250, &segs);

    const st = try parse(gpa, w.buffered());
    defer st.deinit(gpa);
    try std.testing.expectEqualStrings("https://example.com/a b", st.url);
    try std.testing.expectEqual(@as(u64, 250), st.size);
    try std.testing.expectEqual(@as(usize, 2), st.segments.len);
    try std.testing.expectEqual(@as(u64, 40), st.segments[0].doneBytes());
    try std.testing.expect(st.segments[1].isComplete());
}

test "reject inconsistent files" {
    const gpa = std.testing.allocator;
    const bad = [_][]const u8{
        "",
        "gigachad 2\nsize 10\nurl x\nseg 0 10 0\n",
        "gigachad 1\nsize 10\nurl x\nseg 0 5 0\n", // 没覆盖完整
        "gigachad 1\nsize 10\nurl x\nseg 0 10 11\n", // done 超出
        "gigachad 1\nsize 10\nurl x\nseg 0 4 0\nseg 5 10 0\n", // 有空洞
        "gigachad 1\nsize 10\nseg 0 10 0\n", // 缺 url
    };
    for (bad) |text| {
        try std.testing.expectError(error.InvalidStateFile, parse(gpa, text));
    }
}
