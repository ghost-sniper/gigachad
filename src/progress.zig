//! 终端进度条：总进度、速度（指数平滑）、剩余时间、活动连接数。
const std = @import("std");
const Io = std.Io;

pub const Mode = enum {
    /// 交互终端：用 '\r' 原地刷新同一行。
    tty,
    /// 输出被重定向：每隔一段时间打印一行。
    plain,
    quiet,
};

const plain_interval_ms = 10_000;
const bar_width = 24;
const name_width = 24;

pub const Progress = struct {
    io: Io,
    out: *Io.Writer,
    mode: Mode,
    name: []const u8,
    start: Io.Timestamp,
    last_t: Io.Timestamp,
    last_bytes: u64,
    /// 续传时已有的字节数，不计入平均速度。
    initial_bytes: u64,
    last_print: Io.Timestamp,
    /// 字节/秒，指数平滑。
    speed: f64 = 0,
    line_len: usize = 0,

    pub fn init(io: Io, out: *Io.Writer, mode: Mode, name: []const u8, initial_bytes: u64) Progress {
        const now = Io.Clock.awake.now(io);
        return .{
            .io = io,
            .out = out,
            .mode = mode,
            .name = name,
            .start = now,
            .last_t = now,
            .last_bytes = initial_bytes,
            .initial_bytes = initial_bytes,
            .last_print = now,
        };
    }

    pub fn update(p: *Progress, done: u64, total: ?u64, active: usize) void {
        const now = Io.Clock.awake.now(p.io);
        const dt_ns = p.last_t.durationTo(now).toNanoseconds();
        if (dt_ns > 0) {
            const inst = @as(f64, @floatFromInt(done -| p.last_bytes)) * std.time.ns_per_s / @as(f64, @floatFromInt(dt_ns));
            p.speed = if (p.speed == 0) inst else p.speed * 0.7 + inst * 0.3;
            p.last_t = now;
            p.last_bytes = done;
        }
        switch (p.mode) {
            .quiet => return,
            .plain => {
                if (p.last_print.durationTo(now).toMilliseconds() < plain_interval_ms) return;
                p.last_print = now;
                p.render(done, total, active, false) catch return;
                p.out.writeByte('\n') catch return;
            },
            .tty => p.render(done, total, active, true) catch return,
        }
        p.out.flush() catch {};
    }

    /// 结束当前行并打印最终结果。
    pub fn finish(p: *Progress, done: u64, ok: bool) void {
        if (p.mode == .quiet) return;
        const elapsed_ms = p.start.durationTo(Io.Clock.awake.now(p.io)).toMilliseconds();
        const secs = @as(f64, @floatFromInt(@max(elapsed_ms, 1))) / 1000.0;
        const avg = @as(f64, @floatFromInt(done -| p.initial_bytes)) / secs;
        if (p.mode == .tty) p.clearLine() catch {};
        var size_buf: [16]u8 = undefined;
        var speed_buf: [16]u8 = undefined;
        p.out.print("{s} {s}  {s}  用时 {d:.1}s  平均 {s}/s\n", .{
            if (ok) "完成" else "失败",
            p.name,
            fmtBytes(&size_buf, done),
            secs,
            fmtBytes(&speed_buf, @intFromFloat(avg)),
        }) catch {};
        p.out.flush() catch {};
    }

    fn clearLine(p: *Progress) !void {
        try p.out.writeByte('\r');
        try p.out.splatByteAll(' ', p.line_len);
        try p.out.writeByte('\r');
    }

    fn render(p: *Progress, done: u64, total: ?u64, active: usize, in_place: bool) !void {
        var line_buf: [256]u8 = undefined;
        var w: Io.Writer = .fixed(&line_buf);
        formatLine(&w, p.name, done, total, p.speed, active) catch {};
        const line = w.buffered();
        if (in_place) {
            try p.out.writeByte('\r');
            try p.out.writeAll(line);
            // 新行比旧行短时，用空格盖掉残留字符。
            if (line.len < p.line_len) try p.out.splatByteAll(' ', p.line_len - line.len);
            p.line_len = @max(p.line_len, line.len);
        } else {
            try p.out.writeAll(line);
        }
    }
};

pub fn formatLine(w: *Io.Writer, name: []const u8, done: u64, total: ?u64, speed: f64, active: usize) Io.Writer.Error!void {
    try w.print("{s:<24} ", .{truncateUtf8(name, name_width)});
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    var s: [16]u8 = undefined;
    if (total) |t| {
        const ratio: f64 = if (t == 0) 1 else @as(f64, @floatFromInt(done)) / @as(f64, @floatFromInt(t));
        const filled: usize = @intFromFloat(@min(1.0, ratio) * bar_width);
        try w.writeByte('[');
        try w.splatByteAll('#', filled);
        try w.splatByteAll('-', bar_width - filled);
        try w.print("] {d:>5.1}%  {s}/{s}", .{ ratio * 100, fmtBytes(&a, done), fmtBytes(&b, t) });
    } else {
        try w.print("{s}", .{fmtBytes(&a, done)});
    }
    try w.print("  {s}/s", .{fmtBytes(&s, @intFromFloat(@max(0, speed)))});
    if (total) |t| {
        if (speed >= 1 and t > done) {
            const eta: u64 = @intFromFloat(@as(f64, @floatFromInt(t - done)) / speed);
            try w.print("  剩余 {d}:{d:0>2}:{d:0>2}", .{ eta / 3600, eta / 60 % 60, eta % 60 });
        }
    }
    try w.print("  连接 {d}", .{active});
}

/// 按字节截断但不切断 UTF-8 多字节字符。
fn truncateUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

pub fn fmtBytes(buf: *[16]u8, n: u64) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var v: f64 = @floatFromInt(n);
    var i: usize = 0;
    while (v >= 1024 and i + 1 < units.len) : (i += 1) v /= 1024;
    return if (i == 0)
        std.fmt.bufPrint(buf, "{d} B", .{n}) catch "?"
    else
        std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[i] }) catch "?";
}

test fmtBytes {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("512 B", fmtBytes(&buf, 512));
    try std.testing.expectEqualStrings("1.5 KiB", fmtBytes(&buf, 1536));
    try std.testing.expectEqualStrings("3.0 GiB", fmtBytes(&buf, 3 * 1024 * 1024 * 1024));
}

test formatLine {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try formatLine(&w, "file.iso", 512 * 1024, 1024 * 1024, 1024, 4);
    const line = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, line, " 50.0%") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "[############------------]") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "连接 4") != null);
}

test truncateUtf8 {
    try std.testing.expectEqualStrings("ab", truncateUtf8("ab", 5));
    // "中" 占 3 字节，截到 4 字节时不能留下半个字符。
    try std.testing.expectEqualStrings("a中", truncateUtf8("a中文", 5));
}
