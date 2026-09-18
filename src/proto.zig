//! 各协议的统一入口：`probe` 获取文件信息，`fetch` 下载一个字节区间。
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Url = @import("url.zig").Url;

pub const http = @import("proto/http.zig");
pub const ftp = @import("proto/ftp.zig");
pub const sftp = @import("proto/sftp.zig");

/// std.http.Client 的修补版本，见文件头说明。
pub const HttpClient = @import("http/Client.zig");

/// 所有下载任务共享的上下文，必须是线程安全的。
pub const Context = struct {
    gpa: Allocator,
    io: Io,
    /// 使用环境变量中的代理。
    http_client: *HttpClient,
    /// 不走代理，用于 NO_PROXY 匹配的主机。
    http_direct: *HttpClient,
    /// NO_PROXY 环境变量的值。
    no_proxy: ?[]const u8 = null,
    auth: Auth = .{},
    /// 用于查找 ~/.ssh 下的默认密钥和 known_hosts。
    home: ?[]const u8 = null,
    /// URL 未指定用户时 SFTP 使用的本地用户名。
    local_user: ?[]const u8 = null,
};

pub const Auth = struct {
    /// 覆盖 URL 中的密码。
    password: ?[]const u8 = null,
    /// SFTP 私钥文件。
    identity: ?[]const u8 = null,
    /// 私钥的保护口令。
    passphrase: ?[]const u8 = null,
};

pub const Probe = struct {
    /// 文件大小；服务器不告知时为 null。
    size: ?u64,
    /// 是否支持从任意偏移开始读取（分段和续传的前提）。
    ranges: bool,
    /// 服务器建议的文件名（HTTP Content-Disposition）。
    file_name: ?[]const u8 = null,
};

/// 接收下载数据。协议实现保证写入的总字节数不超过请求的长度。
pub const Sink = struct {
    context: *anyopaque,
    writeFn: *const fn (context: *anyopaque, bytes: []const u8) anyerror!void,

    pub fn write(s: Sink, bytes: []const u8) anyerror!void {
        return s.writeFn(s.context, bytes);
    }
};

/// 失败时附带的人类可读说明（服务器回复、libssh2 错误信息等）。
pub const Diag = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn set(d: *Diag, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&d.buf, fmt, args) catch blk: {
            @memcpy(d.buf[d.buf.len - 3 ..], "...");
            break :blk d.buf[0..];
        };
        d.len = s.len;
    }

    pub fn message(d: *const Diag) ?[]const u8 {
        return if (d.len == 0) null else d.buf[0..d.len];
    }
};

/// `arena` 用于 Probe 中返回的字符串。
pub fn probe(ctx: *const Context, arena: Allocator, url: *const Url, diag: *Diag) anyerror!Probe {
    return switch (url.scheme) {
        .http, .https => http.probe(ctx, arena, url, diag),
        .ftp => ftp.probe(ctx, url, diag),
        .sftp => sftp.probe(ctx, url, diag),
    };
}

/// 从 `offset` 开始下载 `length` 个字节；`length` 为 null 时读到 EOF。
pub fn fetch(ctx: *const Context, url: *const Url, offset: u64, length: ?u64, sink: Sink, diag: *Diag) anyerror!void {
    if (length) |l| if (l == 0) return;
    return switch (url.scheme) {
        .http, .https => http.fetch(ctx, url, offset, length, sink, diag),
        .ftp => ftp.fetch(ctx, url, offset, length, sink, diag),
        .sftp => sftp.fetch(ctx, url, offset, length, sink, diag),
    };
}

/// 从 reader 读取至多 `buf.len` 字节，有数据就立即返回；返回 0 表示 EOF。
pub fn readSome(r: *Io.Reader, buf: []u8) Io.Reader.Error!usize {
    var data: [1][]u8 = .{buf};
    while (true) {
        const n = r.readVec(&data) catch |err| switch (err) {
            error.EndOfStream => return 0,
            else => |e| return e,
        };
        if (n > 0) return n;
    }
}

test {
    _ = http;
    _ = ftp;
    _ = sftp;
}
