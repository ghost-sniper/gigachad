//! 明文 FTP 客户端（被动模式）。每个分段使用独立的控制连接，
//! 通过 REST 指定起始偏移，读够所需字节后直接断开数据连接。
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const proto = @import("../proto.zig");
const Url = @import("../url.zig").Url;

const Reply = struct {
    code: u16,

    fn class(r: Reply) u16 {
        return r.code / 100;
    }
};

const Client = struct {
    io: Io,
    host: []const u8,
    stream: net.Stream,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    read_buf: [4096]u8,
    write_buf: [1024]u8,
    diag: *proto.Diag,

    /// 结构体包含指向自身缓冲区的指针，所以原地初始化。
    fn connect(c: *Client, io: Io, url: *const Url, diag: *proto.Diag) !void {
        const host_name = try net.HostName.init(url.host);
        c.io = io;
        c.host = url.host;
        c.diag = diag;
        c.stream = try host_name.connect(io, url.port, .{ .mode = .stream });
        c.reader = c.stream.reader(io, &c.read_buf);
        c.writer = c.stream.writer(io, &c.write_buf);
        errdefer c.stream.close(io);
        try c.expect(try c.readReply(), 2, error.FtpConnectRejected);
    }

    fn close(c: *Client) void {
        // QUIT 只是礼貌，失败无所谓。
        c.send("QUIT", .{}) catch {};
        c.stream.close(c.io);
    }

    fn send(c: *Client, comptime fmt: []const u8, args: anytype) !void {
        const w = &c.writer.interface;
        try w.print(fmt ++ "\r\n", args);
        try w.flush();
    }

    /// 读取一条回复（可能是多行回复），最后一行保存在 diag 里。
    fn readReply(c: *Client) !Reply {
        const r = &c.reader.interface;
        var line = trimLine(try r.takeDelimiterInclusive('\n'));
        if (line.len < 3) return error.FtpInvalidReply;
        const code = std.fmt.parseInt(u16, line[0..3], 10) catch return error.FtpInvalidReply;
        if (line.len > 3 and line[3] == '-') {
            // 多行回复以 "xyz " 开头的行结束。
            while (true) {
                line = trimLine(try r.takeDelimiterInclusive('\n'));
                if (line.len >= 4 and std.mem.startsWith(u8, line, &codeText(code)) and line[3] == ' ') break;
            }
        }
        c.diag.set("FTP: {s}", .{line});
        return .{ .code = code };
    }

    fn command(c: *Client, comptime fmt: []const u8, args: anytype) !Reply {
        try c.send(fmt, args);
        return c.readReply();
    }

    fn expect(c: *Client, reply: Reply, class: u16, err: anyerror) !void {
        _ = c;
        if (reply.class() != class) return err;
    }

    fn login(c: *Client, ctx: *const proto.Context, url: *const Url) !void {
        const user = url.user orelse "anonymous";
        const password = ctx.auth.password orelse url.password orelse "anonymous@";
        var reply = try c.command("USER {s}", .{user});
        if (reply.code == 331 or reply.code == 332) {
            reply = try c.command("PASS {s}", .{password});
        }
        if (reply.class() != 2) return error.FtpLoginFailed;
        try c.expect(try c.command("TYPE I", .{}), 2, error.FtpTypeFailed);
    }

    /// 进入被动模式并建立数据连接。数据连接总是连到控制连接的主机，
    /// 忽略 PASV 返回的 IP（NAT 后面的服务器经常返回内网地址）。
    fn openData(c: *Client) !net.Stream {
        const port = blk: {
            const epsv = try c.command("EPSV", .{});
            if (epsv.code == 229) {
                if (parseEpsvPort(c.diag.message() orelse "")) |p| break :blk p;
            }
            const pasv = try c.command("PASV", .{});
            if (pasv.code != 227) return error.FtpPassiveFailed;
            break :blk parsePasvPort(c.diag.message() orelse "") orelse return error.FtpPassiveFailed;
        };
        const host_name = try net.HostName.init(c.host);
        return host_name.connect(c.io, port, .{ .mode = .stream });
    }
};

fn codeText(code: u16) [3]u8 {
    var out: [3]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>3}", .{code}) catch unreachable;
    return out;
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r\n");
}

/// FTP 路径相对于登录目录；与 curl 一致，URL 开头的 '/' 被去掉。
fn remotePath(url: *const Url) ![]const u8 {
    const p = std.mem.trimStart(u8, url.path, "/");
    if (p.len == 0) return error.FtpNoFilePath;
    // 防止在命令里注入额外的 FTP 命令。
    if (std.mem.indexOfAny(u8, p, "\r\n") != null) return error.FtpInvalidPath;
    return p;
}

pub fn probe(ctx: *const proto.Context, url: *const Url, diag: *proto.Diag) !proto.Probe {
    const path = try remotePath(url);
    var c: Client = undefined;
    try c.connect(ctx.io, url, diag);
    defer c.close();
    try c.login(ctx, url);

    var result: proto.Probe = .{ .size = null, .ranges = false };
    const size_reply = try c.command("SIZE {s}", .{path});
    if (size_reply.code == 213) {
        const msg = diag.message() orelse "";
        // "FTP: 213 12345"
        if (std.mem.lastIndexOfScalar(u8, msg, ' ')) |i| {
            result.size = std.fmt.parseInt(u64, msg[i + 1 ..], 10) catch null;
        }
    } else if (size_reply.code == 550) {
        return error.FtpFileNotFound;
    }
    result.ranges = (try c.command("REST 0", .{})).code == 350;
    diag.len = 0;
    return result;
}

pub fn fetch(
    ctx: *const proto.Context,
    url: *const Url,
    offset: u64,
    length: ?u64,
    sink: proto.Sink,
    diag: *proto.Diag,
) !void {
    const path = try remotePath(url);
    var c: Client = undefined;
    try c.connect(ctx.io, url, diag);
    defer c.close();
    try c.login(ctx, url);

    const data = try c.openData();
    var data_open = true;
    defer if (data_open) data.close(ctx.io);

    if (offset > 0) try c.expect(try c.command("REST {d}", .{offset}), 3, error.FtpRestFailed);
    const retr = try c.command("RETR {s}", .{path});
    if (retr.class() != 1) return error.FtpRetrFailed;

    var data_buf: [64 * 1024]u8 = undefined;
    var data_reader = data.reader(ctx.io, &data_buf);
    var buf: [64 * 1024]u8 = undefined;
    var left = length;
    while (true) {
        const cap = if (left) |l| @min(buf.len, l) else buf.len;
        if (cap == 0) {
            // 分段已读够。直接关闭数据连接，服务器会以 426 之类的回复结束传输，
            // 控制连接随后也会被关闭，无需等待。
            return;
        }
        const n = proto.readSome(&data_reader.interface, buf[0..cap]) catch |err| switch (err) {
            error.ReadFailed => return data_reader.err orelse error.ReadFailed,
            else => |e| return e,
        };
        if (n == 0) break;
        try sink.write(buf[0..n]);
        if (left) |*l| l.* -= n;
    }

    data.close(ctx.io);
    data_open = false;
    if (left) |l| if (l > 0) return error.UnexpectedEndOfStream;
    // 读到 EOF 后确认服务器报告传输成功。
    try c.expect(try c.readReply(), 2, error.FtpTransferFailed);
    diag.len = 0;
}

/// "229 Entering Extended Passive Mode (|||6446|)"
fn parseEpsvPort(msg: []const u8) ?u16 {
    const open = std.mem.indexOfScalar(u8, msg, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, msg, ')') orelse return null;
    if (close <= open + 1) return null;
    const inner = msg[open + 1 .. close];
    // 形如 <d><d><d>port<d>，分隔符由服务器决定，通常是 '|'。
    if (inner.len < 5) return null;
    const d = inner[0];
    if (inner[1] != d or inner[2] != d or inner[inner.len - 1] != d) return null;
    return std.fmt.parseInt(u16, inner[3 .. inner.len - 1], 10) catch null;
}

/// "227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)."
fn parsePasvPort(msg: []const u8) ?u16 {
    const open = std.mem.indexOfScalar(u8, msg, '(') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, msg, open, ')') orelse return null;
    var it = std.mem.splitScalar(u8, msg[open + 1 .. close], ',');
    var nums: [6]u8 = undefined;
    for (&nums) |*n| {
        const part = std.mem.trim(u8, it.next() orelse return null, " ");
        n.* = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    if (it.next() != null) return null;
    return @as(u16, nums[4]) * 256 + nums[5];
}

test parseEpsvPort {
    try std.testing.expectEqual(@as(?u16, 6446), parseEpsvPort("FTP: 229 Entering Extended Passive Mode (|||6446|)"));
    try std.testing.expectEqual(@as(?u16, null), parseEpsvPort("229 garbage"));
}

test parsePasvPort {
    try std.testing.expectEqual(@as(?u16, 50000), parsePasvPort("FTP: 227 Entering Passive Mode (192,168,1,2,195,80)."));
    try std.testing.expectEqual(@as(?u16, null), parsePasvPort("227 (1,2,3)"));
}

test remotePath {
    var u: Url = undefined;
    u.path = "/pub/gnu/hello.tar.gz";
    try std.testing.expectEqualStrings("pub/gnu/hello.tar.gz", try remotePath(&u));
    u.path = "/";
    try std.testing.expectError(error.FtpNoFilePath, remotePath(&u));
    u.path = "/a\r\nDELE b";
    try std.testing.expectError(error.FtpInvalidPath, remotePath(&u));
}
