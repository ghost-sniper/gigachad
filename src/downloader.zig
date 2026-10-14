//! 单个 URL 的下载流程：探测 → 切分/续传 → 分段并发下载 → 重命名为最终文件。
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const proto = @import("proto.zig");
const Url = @import("url.zig").Url;
const segment = @import("segment.zig");
const Segment = segment.Segment;
const state = @import("state.zig");
const progress = @import("progress.zig");

pub const Config = struct {
    connections: u32 = 8,
    /// 单个分段连续失败（期间没有任何进展）的最大重试次数。
    retries: u32 = 5,
    /// 输出文件路径；为 null 时根据 URL 或服务器建议推断。
    output: ?[]const u8 = null,
    /// 输出目录（`output` 为相对路径或未指定时使用）。
    dir: ?[]const u8 = null,
    resume_enabled: bool = true,
    force: bool = false,
    progress_mode: progress.Mode = .tty,
    min_segment: u64 = segment.default_min_segment,
};

pub const Outcome = enum { downloaded, skipped };

const tick_ms = 200;
const save_every_ticks = 5;
const part_suffix = ".part";

/// 下载失败时，`diag` 中存放给用户看的说明。
pub fn download(
    gpa: Allocator,
    ctx: *const proto.Context,
    cfg: Config,
    raw_url: []const u8,
    out: *Io.Writer,
    diag: *proto.Diag,
) !Outcome {
    const io = ctx.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const url = Url.parse(arena, raw_url) catch |err| {
        diag.set("无法解析 URL：{s}", .{raw_url});
        return err;
    };

    const info = try withRetries(io, cfg.retries, proto.probe, .{ ctx, arena, &url, diag });

    const out_path = try outputPath(arena, cfg, &url, info.file_name);
    const part_path = try std.mem.concat(arena, u8, &.{ out_path, part_suffix });
    const state_path = try std.mem.concat(arena, u8, &.{ out_path, state.suffix });
    const cwd = Io.Dir.cwd();

    if (std.fs.path.dirname(out_path)) |parent| try cwd.createDirPath(io, parent);

    // 目标文件已存在且没有未完成的下载。
    if (cwd.statFile(io, out_path, .{})) |st| {
        const has_state = if (cwd.access(io, state_path, .{})) |_| true else |_| false;
        if (!has_state and !cfg.force) {
            if (info.size != null and st.size == info.size.?) {
                if (cfg.progress_mode != .quiet) try out.print("跳过 {s}：文件已存在且大小一致\n", .{out_path});
                return .skipped;
            }
            diag.set("{s} 已存在且大小不同，使用 -f 覆盖或 -o 指定其他文件名", .{out_path});
            return error.OutputExists;
        }
    } else |_| {}

    // 只有大小已知且支持 Range 时才能分段和续传。
    const splittable = info.size != null and info.ranges;
    const connections: u32 = if (splittable) cfg.connections else 1;

    var file: Io.File = undefined;
    var segs: []Segment = &.{};
    defer gpa.free(segs);

    var resumed = false;
    if (splittable and cfg.resume_enabled) {
        if (try state.load(gpa, io, cwd, state_path)) |st| {
            const usable = std.mem.eql(u8, st.url, raw_url) and st.size == info.size.? and blk: {
                const part = cwd.statFile(io, part_path, .{}) catch break :blk false;
                break :blk part.size == st.size;
            };
            if (usable) {
                file = try cwd.openFile(io, part_path, .{ .mode = .read_write });
                gpa.free(st.url);
                segs = st.segments;
                resumed = true;
            } else st.deinit(gpa);
        }
    }
    if (!resumed) {
        segs = try segment.split(gpa, info.size, connections, cfg.min_segment);
        file = try cwd.createFile(io, part_path, .{ .read = true, .truncate = true });
        if (info.size) |size| file.setLength(io, size) catch {};
    }
    var file_open = true;
    defer if (file_open) file.close(io);

    var job: Job = .{
        .ctx = ctx,
        .url = &url,
        .file = file,
        .segs = segs,
        .ranges = info.ranges,
        .retries = cfg.retries,
    };

    const display_name = std.fs.path.basename(out_path);
    var bar: progress.Progress = .init(io, out, cfg.progress_mode, display_name, segment.totalDone(segs));
    if (resumed and cfg.progress_mode != .quiet) {
        var buf: [16]u8 = undefined;
        try out.print("续传 {s}：已完成 {s}\n", .{ out_path, progress.fmtBytes(&buf, segment.totalDone(segs)) });
    }

    // 为每个未完成的分段启动一个并发任务。
    var group: Io.Group = .init;
    for (segs, 0..) |*seg, i| {
        if (seg.isComplete()) continue;
        _ = job.active.fetchAdd(1, .monotonic);
        group.concurrent(io, segmentTask, .{ &job, i }) catch {
            // 当前 Io 不支持并发（例如单线程构建），退化为顺序执行。
            segmentTask(&job, i);
        };
    }

    // 主任务：刷新进度条并定期保存状态，直到所有分段结束。
    var ticks: usize = 0;
    while (job.active.load(.acquire) > 0) {
        io.sleep(.fromMilliseconds(tick_ms), .awake) catch |err| {
            group.cancel(io);
            return err;
        };
        ticks += 1;
        bar.update(segment.totalDone(segs), info.size, job.active.load(.monotonic));
        if (splittable and ticks % save_every_ticks == 0) {
            state.save(io, cwd, state_path, raw_url, info.size.?, segs) catch {};
        }
    }
    group.await(io) catch {};

    const done = segment.totalDone(segs);
    if (job.failure) |f| {
        if (splittable) state.save(io, cwd, state_path, raw_url, info.size.?, segs) catch {};
        bar.finish(done, false);
        diag.* = f.diag;
        return f.err;
    }
    if (info.size) |size| if (done != size) {
        bar.finish(done, false);
        diag.set("下载的字节数 {d} 与文件大小 {d} 不一致", .{ done, size });
        return error.SizeMismatch;
    };

    file.close(io);
    file_open = false;
    try cwd.rename(part_path, cwd, out_path, io);
    cwd.deleteFile(io, state_path) catch {};
    bar.finish(done, true);
    return .downloaded;
}

const Failure = struct {
    err: anyerror,
    diag: proto.Diag,
};

const Job = struct {
    ctx: *const proto.Context,
    url: *const Url,
    file: Io.File,
    segs: []Segment,
    ranges: bool,
    retries: u32,
    active: std.atomic.Value(usize) = .init(0),
    mutex: Io.Mutex = .init,
    /// 第一个彻底失败的分段的错误。
    failure: ?Failure = null,

    fn fail(job: *Job, err: anyerror, diag: *const proto.Diag) void {
        const io = job.ctx.io;
        job.mutex.lockUncancelable(io);
        defer job.mutex.unlock(io);
        if (job.failure == null) job.failure = .{ .err = err, .diag = diag.* };
    }
};

/// 把收到的数据写到分段当前位置，然后推进进度。
/// 先写文件后更新计数，保证状态文件记录的进度不会超过实际落盘的数据。
const SegmentSink = struct {
    job: *Job,
    seg: *Segment,

    fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
        const s: *SegmentSink = @ptrCast(@alignCast(context));
        try s.job.file.writePositionalAll(s.job.ctx.io, bytes, s.seg.offset());
        _ = s.seg.done.fetchAdd(bytes.len, .monotonic);
    }

    fn sink(s: *SegmentSink) proto.Sink {
        return .{ .context = s, .writeFn = write };
    }
};

fn segmentTask(job: *Job, index: usize) void {
    defer _ = job.active.fetchSub(1, .release);
    const io = job.ctx.io;
    const seg = &job.segs[index];
    var sink_state: SegmentSink = .{ .job = job, .seg = seg };
    var diag: proto.Diag = .{};
    var attempts: u32 = 0;

    while (!seg.isComplete()) {
        const before = seg.doneBytes();
        if (proto.fetch(job.ctx, job.url, seg.offset(), seg.remaining(), sink_state.sink(), &diag)) |_| {
            // 大小未知时读到 EOF 就是完成。
            if (seg.end == null) return;
        } else |err| {
            if (err == error.Canceled) return;
            // 本次尝试有进展就重新计数，只有连续无进展的失败才会耗尽重试次数。
            if (seg.doneBytes() > before) attempts = 0;
            attempts += 1;
            if (attempts > job.retries) {
                job.fail(err, &diag);
                return;
            }
            // 服务器不支持 Range 时只能从头再来。
            if (!job.ranges) seg.done.store(0, .monotonic);
            io.sleep(backoff(attempts), .awake) catch return;
        }
    }
}

/// 指数退避：0.5s、1s、2s …… 最长 30s。
fn backoff(attempt: u32) Io.Duration {
    const shift: u6 = @intCast(@min(attempt - 1, 16));
    const ms = @min(@as(i64, 500) << shift, 30_000);
    return .fromMilliseconds(ms);
}

/// 对整个操作做重试（用于探测阶段）。
fn withRetries(io: Io, retries: u32, comptime func: anytype, args: anytype) !proto.Probe {
    var attempt: u32 = 0;
    while (true) {
        if (@call(.auto, func, args)) |result| {
            return result;
        } else |err| {
            attempt += 1;
            if (attempt > retries or !isRetryable(err)) return err;
            try io.sleep(backoff(attempt), .awake);
        }
    }
}

/// 明确的客户端错误（URL、认证、文件不存在等）重试也没用。
fn isRetryable(err: anyerror) bool {
    return switch (err) {
        error.InvalidUrl,
        error.UnsupportedScheme,
        error.MissingHost,
        error.UnsupportedUriScheme,
        error.UriMissingHost,
        error.InvalidHostName,
        error.HttpBadStatus,
        error.FtpLoginFailed,
        error.FtpFileNotFound,
        error.FtpNoFilePath,
        error.FtpInvalidPath,
        error.SshAuthFailed,
        error.SshNoUser,
        error.SshHostKeyMismatch,
        error.SftpFileNotFound,
        error.SftpPermissionDenied,
        error.OutOfMemory,
        => false,
        else => true,
    };
}

fn outputPath(arena: Allocator, cfg: Config, url: *const Url, suggested: ?[]const u8) ![]const u8 {
    const name = cfg.output orelse suggested orelse url.fileName() orelse "index.html";
    if (cfg.dir) |dir| {
        if (cfg.output != null and std.fs.path.isAbsolute(name)) return name;
        return std.fs.path.join(arena, &.{ dir, name });
    }
    return name;
}

test backoff {
    try std.testing.expectEqual(@as(i64, 500), backoff(1).toMilliseconds());
    try std.testing.expectEqual(@as(i64, 2000), backoff(3).toMilliseconds());
    try std.testing.expectEqual(@as(i64, 30_000), backoff(10).toMilliseconds());
    try std.testing.expectEqual(@as(i64, 30_000), backoff(100).toMilliseconds());
}

test outputPath {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const url = try Url.parse(arena, "https://example.com/pub/file.iso");

    try std.testing.expectEqualStrings("file.iso", try outputPath(arena, .{}, &url, null));
    try std.testing.expectEqualStrings("cd.iso", try outputPath(arena, .{}, &url, "cd.iso"));
    try std.testing.expectEqualStrings("x.bin", try outputPath(arena, .{ .output = "x.bin" }, &url, "cd.iso"));
    const joined = try outputPath(arena, .{ .dir = "dl" }, &url, null);
    try std.testing.expectEqualStrings("file.iso", std.fs.path.basename(joined));
    try std.testing.expectEqualStrings("dl", std.fs.path.dirname(joined).?);
}
