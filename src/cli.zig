//! 命令行参数解析。
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const version = "0.1.0";

pub const usage =
    \\gigachad —— 支持 HTTP(S)/FTP/SFTP 的多连接分段下载器
    \\
    \\用法：gigachad [选项] <URL>...
    \\
    \\选项：
    \\  -c, --connections <N>   每个文件的并发连接数（默认 8，范围 1-64）
    \\  -o, --output <FILE>     输出文件名（仅限单个 URL）
    \\  -d, --dir <DIR>         保存目录（默认当前目录）
    \\  -i, --input-file <FILE> 从文件读取 URL，每行一个，'#' 开头为注释
    \\  -k, --min-split <SIZE>  每个分段的最小大小，支持 K/M/G 后缀（默认 1M）
    \\      --retries <N>       每个分段连续失败的重试次数（默认 5）
    \\      --password <PASS>   FTP/SFTP 密码（覆盖 URL 中的密码）
    \\      --identity <FILE>   SFTP 私钥文件（默认尝试 ssh-agent 和 ~/.ssh/id_ecdsa、id_rsa）
    \\      --passphrase <PASS> 私钥口令
    \\      --no-resume         忽略已有的续传进度，重新下载
    \\  -f, --force             覆盖已存在的文件
    \\  -q, --quiet             不显示进度
    \\  -h, --help              显示帮助
    \\  -V, --version           显示版本
    \\
    \\示例：
    \\  gigachad -c 16 https://example.com/big.iso
    \\  gigachad ftp://ftp.example.org/pub/file.tar.gz
    \\  gigachad --identity ~/.ssh/id_rsa sftp://user@host/data/file.bin
    \\  gigachad -d downloads -i urls.txt
    \\
;

pub const Options = struct {
    urls: std.ArrayList([]const u8) = .empty,
    input_file: ?[]const u8 = null,
    connections: u32 = 8,
    retries: u32 = 5,
    min_split: u64 = 1024 * 1024,
    output: ?[]const u8 = null,
    dir: ?[]const u8 = null,
    password: ?[]const u8 = null,
    identity: ?[]const u8 = null,
    passphrase: ?[]const u8 = null,
    resume_enabled: bool = true,
    force: bool = false,
    quiet: bool = false,
    help: bool = false,
    show_version: bool = false,
};

pub const Error = error{
    MissingValue,
    InvalidNumber,
    UnknownOption,
    NoUrls,
    OutputWithMultipleUrls,
} || Allocator.Error;

pub const Diag = struct {
    arg: []const u8 = "",
};

/// `args` 不包含程序名。返回的 Options 引用 `args` 中的字符串。
pub fn parse(arena: Allocator, args: []const []const u8, diag: *Diag) Error!Options {
    var opts: Options = .{};
    var i: usize = 0;
    var only_positional = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        diag.arg = arg;
        if (only_positional or arg.len < 2 or arg[0] != '-') {
            try opts.urls.append(arena, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            only_positional = true;
            continue;
        }

        // 支持 --name=value 形式。
        var name = arg;
        var inline_value: ?[]const u8 = null;
        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                name = arg[0..eq];
                inline_value = arg[eq + 1 ..];
            }
        }

        const Flag = enum { c, k, o, d, i, retries, password, identity, passphrase, no_resume, f, q, h, V };
        const flag: Flag = if (eqlAny(name, &.{ "-c", "--connections" }))
            .c
        else if (eqlAny(name, &.{ "-o", "--output" }))
            .o
        else if (eqlAny(name, &.{ "-d", "--dir" }))
            .d
        else if (eqlAny(name, &.{ "-i", "--input-file" }))
            .i
        else if (eqlAny(name, &.{ "-k", "--min-split" }))
            .k
        else if (eqlAny(name, &.{"--retries"}))
            .retries
        else if (eqlAny(name, &.{"--password"}))
            .password
        else if (eqlAny(name, &.{"--identity"}))
            .identity
        else if (eqlAny(name, &.{"--passphrase"}))
            .passphrase
        else if (eqlAny(name, &.{"--no-resume"}))
            .no_resume
        else if (eqlAny(name, &.{ "-f", "--force" }))
            .f
        else if (eqlAny(name, &.{ "-q", "--quiet" }))
            .q
        else if (eqlAny(name, &.{ "-h", "--help" }))
            .h
        else if (eqlAny(name, &.{ "-V", "--version" }))
            .V
        else
            return error.UnknownOption;

        switch (flag) {
            .no_resume => opts.resume_enabled = false,
            .f => opts.force = true,
            .q => opts.quiet = true,
            .h => opts.help = true,
            .V => opts.show_version = true,
            else => {
                const value = inline_value orelse blk: {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    break :blk args[i];
                };
                switch (flag) {
                    .c => opts.connections = try parseRange(value, 1, 64),
                    .retries => opts.retries = try parseRange(value, 0, 100),
                    .k => opts.min_split = try parseSize(value),
                    .o => opts.output = value,
                    .d => opts.dir = value,
                    .i => opts.input_file = value,
                    .password => opts.password = value,
                    .identity => opts.identity = value,
                    .passphrase => opts.passphrase = value,
                    else => unreachable,
                }
            },
        }
    }
    diag.arg = "";
    if (opts.help or opts.show_version) return opts;
    if (opts.urls.items.len == 0 and opts.input_file == null) return error.NoUrls;
    if (opts.output != null and (opts.urls.items.len > 1 or opts.input_file != null))
        return error.OutputWithMultipleUrls;
    return opts;
}

/// 解析 URL 列表文件：忽略空行和 '#' 注释。
pub fn parseUrlList(arena: Allocator, list: *std.ArrayList([]const u8), text: []const u8) Allocator.Error!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try list.append(arena, line);
    }
}

fn eqlAny(s: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

fn parseRange(s: []const u8, min: u32, max: u32) error{InvalidNumber}!u32 {
    const n = std.fmt.parseInt(u32, s, 10) catch return error.InvalidNumber;
    if (n < min or n > max) return error.InvalidNumber;
    return n;
}

/// "512K"、"4M"、"1G" 或纯字节数；至少 1 KiB。
fn parseSize(s: []const u8) error{InvalidNumber}!u64 {
    if (s.len == 0) return error.InvalidNumber;
    const mult: u64 = switch (std.ascii.toUpper(s[s.len - 1])) {
        'K' => 1024,
        'M' => 1024 * 1024,
        'G' => 1024 * 1024 * 1024,
        else => 1,
    };
    const digits = if (mult == 1) s else s[0 .. s.len - 1];
    const n = std.fmt.parseInt(u64, digits, 10) catch return error.InvalidNumber;
    const bytes = std.math.mul(u64, n, mult) catch return error.InvalidNumber;
    if (bytes < 1024) return error.InvalidNumber;
    return bytes;
}

test parseSize {
    try std.testing.expectEqual(@as(u64, 4 * 1024 * 1024), try parseSize("4M"));
    try std.testing.expectEqual(@as(u64, 512 * 1024), try parseSize("512k"));
    try std.testing.expectEqual(@as(u64, 2048), try parseSize("2048"));
    try std.testing.expectError(error.InvalidNumber, parseSize("100"));
    try std.testing.expectError(error.InvalidNumber, parseSize("xM"));
    try std.testing.expectError(error.InvalidNumber, parseSize(""));
}

test "parse options" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = .{};

    const o = try parse(arena, &.{ "-c", "16", "--retries=3", "-q", "https://a/b", "--identity", "k", "-d", "out" }, &diag);
    try std.testing.expectEqual(@as(u32, 16), o.connections);
    try std.testing.expectEqual(@as(u32, 3), o.retries);
    try std.testing.expect(o.quiet);
    try std.testing.expectEqualStrings("k", o.identity.?);
    try std.testing.expectEqualStrings("out", o.dir.?);
    try std.testing.expectEqual(@as(usize, 1), o.urls.items.len);
}

test "parse errors" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = .{};

    try std.testing.expectError(error.NoUrls, parse(arena, &.{"-q"}, &diag));
    try std.testing.expectError(error.MissingValue, parse(arena, &.{ "x", "-c" }, &diag));
    try std.testing.expectError(error.InvalidNumber, parse(arena, &.{ "-c", "0", "x" }, &diag));
    try std.testing.expectError(error.InvalidNumber, parse(arena, &.{ "-c", "abc", "x" }, &diag));
    try std.testing.expectError(error.UnknownOption, parse(arena, &.{ "--bogus", "x" }, &diag));
    try std.testing.expectEqualStrings("--bogus", diag.arg);
    try std.testing.expectError(error.OutputWithMultipleUrls, parse(arena, &.{ "-o", "f", "a", "b" }, &diag));
    const h = try parse(arena, &.{"-h"}, &diag);
    try std.testing.expect(h.help);
}

test parseUrlList {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var list: std.ArrayList([]const u8) = .empty;
    try parseUrlList(arena, &list, "# 注释\r\nhttps://a/1\r\n\n  ftp://b/2  \n");
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("ftp://b/2", list.items[1]);
}
