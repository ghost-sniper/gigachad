const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const gigachad = @import("gigachad");
const cli = gigachad.cli;
const proto = gigachad.proto;
const downloader = gigachad.downloader;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    if (builtin.os.tag == .windows) {
        // 让控制台按 UTF-8 显示中文输出。
        _ = SetConsoleOutputCP(65001);
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_fw.interface;
    var stderr_buf: [4096]u8 = undefined;
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stderr = &stderr_fw.interface;
    defer stdout.flush() catch {};
    defer stderr.flush() catch {};

    const raw_args = try init.minimal.args.toSlice(arena);
    const args = try arena.alloc([]const u8, raw_args.len -| 1);
    for (args, raw_args[1..]) |*dst, src| dst.* = src;

    var cli_diag: cli.Diag = .{};
    var opts = cli.parse(arena, args, &cli_diag) catch |err| {
        switch (err) {
            error.NoUrls => try stderr.writeAll("错误：没有指定 URL\n\n"),
            error.MissingValue => try stderr.print("错误：选项 {s} 缺少参数\n\n", .{cli_diag.arg}),
            error.InvalidNumber => try stderr.print("错误：选项 {s} 的数值无效\n\n", .{cli_diag.arg}),
            error.UnknownOption => try stderr.print("错误：未知选项 {s}\n\n", .{cli_diag.arg}),
            error.OutputWithMultipleUrls => try stderr.writeAll("错误：-o 只能用于单个 URL\n\n"),
            error.OutOfMemory => |e| return e,
        }
        try stderr.writeAll(cli.usage);
        return 2;
    };
    if (opts.help) {
        try stdout.writeAll(cli.usage);
        return 0;
    }
    if (opts.show_version) {
        try stdout.print("gigachad {s}\n", .{cli.version});
        return 0;
    }
    if (opts.input_file) |path| {
        const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024 * 1024)) catch |err| {
            try stderr.print("错误：无法读取 URL 列表 {s}：{s}\n", .{ path, @errorName(err) });
            return 2;
        };
        try cli.parseUrlList(arena, &opts.urls, text);
    }
    if (opts.urls.items.len == 0) {
        try stderr.writeAll("错误：URL 列表为空\n");
        return 2;
    }

    try proto.sftp.globalInit();
    defer proto.sftp.globalDeinit();

    const env = init.environ_map;
    var http_client: proto.HttpClient = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    // 遵循 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY 环境变量。
    http_client.initDefaultProxies(arena, env) catch {};
    var http_direct: proto.HttpClient = .{ .allocator = gpa, .io = io };
    defer http_direct.deinit();

    const ctx: proto.Context = .{
        .gpa = gpa,
        .io = io,
        .http_client = &http_client,
        .http_direct = &http_direct,
        .no_proxy = env.get("NO_PROXY") orelse env.get("no_proxy"),
        .auth = .{
            .password = opts.password,
            .identity = opts.identity,
            .passphrase = opts.passphrase,
        },
        .home = env.get("HOME") orelse env.get("USERPROFILE"),
        .local_user = env.get("USER") orelse env.get("USERNAME"),
    };

    const progress_mode: gigachad.progress.Mode = if (opts.quiet)
        .quiet
    else if (Io.File.stderr().isTty(io) catch false)
        .tty
    else
        .plain;

    const cfg: downloader.Config = .{
        .connections = opts.connections,
        .retries = opts.retries,
        .min_segment = opts.min_split,
        .output = opts.output,
        .dir = opts.dir,
        .resume_enabled = opts.resume_enabled,
        .force = opts.force,
        .progress_mode = progress_mode,
    };

    var ok: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    for (opts.urls.items) |url| {
        var diag: proto.Diag = .{};
        if (downloader.download(gpa, &ctx, cfg, url, stderr, &diag)) |outcome| switch (outcome) {
            .downloaded => ok += 1,
            .skipped => skipped += 1,
        } else |err| {
            failed += 1;
            try stderr.print("错误：{s}\n  {s}", .{ url, @errorName(err) });
            if (diag.message()) |msg| try stderr.print("：{s}", .{msg});
            try stderr.writeByte('\n');
        }
        try stderr.flush();
    }

    if (opts.urls.items.len > 1) {
        try stderr.print("\n共 {d} 个：成功 {d}，跳过 {d}，失败 {d}\n", .{ opts.urls.items.len, ok, skipped, failed });
    }
    return if (failed == 0) 0 else 1;
}

extern "kernel32" fn SetConsoleOutputCP(code_page: c_uint) callconv(.winapi) c_int;
