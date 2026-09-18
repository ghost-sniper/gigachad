//! HTTP/HTTPS，基于（修补过的）std.http.Client。分段通过 Range 请求实现。
const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("../proto.zig");
const Url = @import("../url.zig").Url;

const user_agent = "gigachad/0.1";
const max_redirects = 10;

fn requestOptions(range: ?[]const u8, headers_buf: *[1]std.http.Header) proto.HttpClient.RequestOptions {
    var extra: []const std.http.Header = &.{};
    if (range) |r| {
        headers_buf[0] = .{ .name = "Range", .value = r };
        extra = headers_buf[0..1];
    }
    return .{
        // 中途放弃的响应体不能放回连接池，干脆每个请求用独立连接。
        .keep_alive = false,
        .redirect_behavior = @enumFromInt(max_redirects),
        .headers = .{
            .user_agent = .{ .override = user_agent },
            // 压缩后的字节偏移与文件偏移不一致，必须要求原始内容。
            .accept_encoding = .omit,
        },
        .extra_headers = extra,
    };
}

pub fn probe(ctx: *const proto.Context, arena: Allocator, url: *const Url, diag: *proto.Diag) !proto.Probe {
    // 用 bytes=0-0 探测：一次请求同时得到大小和是否支持 Range，
    // 比 HEAD 更可靠（不少服务器对 HEAD 的处理与 GET 不一致）。
    var headers_buf: [1]std.http.Header = undefined;
    var req = try clientFor(ctx, url).request(.GET, url.uri, requestOptions("bytes=0-0", &headers_buf));
    defer req.deinit();
    // 连接不复用：提前标记关闭，避免 deinit 为了复用连接而把剩余响应体（可能是整个文件）读完。
    defer if (req.connection) |conn| {
        conn.closing = true;
    };
    try req.sendBodiless();

    var redirect_buf: [8 * 1024]u8 = undefined;
    const response = try req.receiveHead(&redirect_buf);
    const head = response.head;

    var result: proto.Probe = .{ .size = null, .ranges = false };
    var content_range: ?[]const u8 = null;
    var it = head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-range")) content_range = h.value;
    }
    if (head.content_disposition) |cd| {
        if (parseContentDispositionFileName(cd)) |name| result.file_name = try arena.dupe(u8, name);
    }

    switch (head.status) {
        .partial_content => {
            const cr = content_range orelse return error.InvalidContentRange;
            result.size = parseContentRangeTotal(cr) orelse return error.InvalidContentRange;
            result.ranges = true;
        },
        .ok => result.size = head.content_length,
        // 对空文件请求 bytes=0-0 会得到 416，Content-Range 为 "bytes */0"。
        .range_not_satisfiable => {
            const cr = content_range orelse return error.InvalidContentRange;
            result.size = parseContentRangeTotal(cr) orelse return error.InvalidContentRange;
            result.ranges = true;
        },
        else => {
            diag.set("HTTP {d} {s}", .{ @intFromEnum(head.status), head.reason });
            return error.HttpBadStatus;
        },
    }
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
    var range_buf: [64]u8 = undefined;
    const range: ?[]const u8 = if (length) |len|
        try std.fmt.bufPrint(&range_buf, "bytes={d}-{d}", .{ offset, offset + len - 1 })
    else if (offset > 0)
        try std.fmt.bufPrint(&range_buf, "bytes={d}-", .{offset})
    else
        null;

    var headers_buf: [1]std.http.Header = undefined;
    var req = try clientFor(ctx, url).request(.GET, url.uri, requestOptions(range, &headers_buf));
    defer req.deinit();
    // 连接不复用：提前标记关闭，避免 deinit 为了复用连接而把剩余响应体（可能是整个文件）读完。
    defer if (req.connection) |conn| {
        conn.closing = true;
    };
    try req.sendBodiless();

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    switch (response.head.status) {
        .partial_content => {},
        // 服务器忽略了 Range：只有从头开始读时才能接受。
        .ok => if (offset != 0) return error.HttpRangeNotSupported,
        else => |status| {
            diag.set("HTTP {d} {s}", .{ @intFromEnum(status), response.head.reason });
            return error.HttpBadStatus;
        },
    }

    var transfer_buf: [64]u8 = undefined;
    const body = response.reader(&transfer_buf);
    var buf: [64 * 1024]u8 = undefined;
    var left = length;
    while (true) {
        const cap = if (left) |l| @min(buf.len, l) else buf.len;
        if (cap == 0) return;
        const n = proto.readSome(body, buf[0..cap]) catch |err| switch (err) {
            error.ReadFailed => {
                if (response.bodyErr()) |e| return e;
                if (req.connection) |conn| if (conn.getReadError()) |e| return e;
                return error.ReadFailed;
            },
            else => |e| return e,
        };
        if (n == 0) {
            if (left != null) return error.UnexpectedEndOfStream;
            return;
        }
        try sink.write(buf[0..n]);
        if (left) |*l| l.* -= n;
    }
}

fn clientFor(ctx: *const proto.Context, url: *const Url) *proto.HttpClient {
    if (ctx.no_proxy) |list| if (noProxyMatch(list, url.host)) return ctx.http_direct;
    return ctx.http_client;
}

/// NO_PROXY 语义（与 curl 一致）：逗号分隔；"*" 匹配所有主机；
/// "example.com" 或 ".example.com" 匹配该域名及其所有子域名。
pub fn noProxyMatch(list: []const u8, host: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, ", ");
    while (it.next()) |raw| {
        if (std.mem.eql(u8, raw, "*")) return true;
        // 去掉可能附带的端口（IPv6 地址本身含冒号，不处理）。
        var entry = raw;
        if (std.mem.indexOfScalar(u8, entry, ':')) |i| {
            if (std.mem.indexOfScalarPos(u8, entry, i + 1, ':') == null) entry = entry[0..i];
        }
        entry = std.mem.trimStart(u8, entry, ".");
        if (entry.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(host, entry)) return true;
        if (host.len > entry.len and host[host.len - entry.len - 1] == '.' and
            std.ascii.eqlIgnoreCase(host[host.len - entry.len ..], entry)) return true;
    }
    return false;
}

test noProxyMatch {
    const list = "localhost,127.0.0.1,::1,.local, example.com:8080";
    try std.testing.expect(noProxyMatch(list, "localhost"));
    try std.testing.expect(noProxyMatch(list, "127.0.0.1"));
    try std.testing.expect(noProxyMatch(list, "::1"));
    try std.testing.expect(noProxyMatch(list, "printer.local"));
    try std.testing.expect(noProxyMatch(list, "www.EXAMPLE.com"));
    try std.testing.expect(!noProxyMatch(list, "notexample.com"));
    try std.testing.expect(!noProxyMatch(list, "github.com"));
    try std.testing.expect(noProxyMatch("*", "anything"));
}

/// 解析 "bytes 0-0/12345" 或 "bytes */12345" 中的总大小。
pub fn parseContentRangeTotal(value: []const u8) ?u64 {
    const v = std.mem.trim(u8, value, " \t");
    if (!std.ascii.startsWithIgnoreCase(v, "bytes")) return null;
    const slash = std.mem.lastIndexOfScalar(u8, v, '/') orelse return null;
    const total = std.mem.trim(u8, v[slash + 1 ..], " \t");
    if (std.mem.eql(u8, total, "*")) return null;
    return std.fmt.parseInt(u64, total, 10) catch null;
}

/// 从 Content-Disposition 中取出 filename 参数，只保留最后一级路径以防目录穿越。
pub fn parseContentDispositionFileName(value: []const u8) ?[]const u8 {
    var params = std.mem.splitScalar(u8, value, ';');
    _ = params.first();
    while (params.next()) |raw_param| {
        const param = std.mem.trim(u8, raw_param, " \t");
        const eq = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        const key = std.mem.trim(u8, param[0..eq], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "filename")) continue;
        var name = std.mem.trim(u8, param[eq + 1 ..], " \t");
        if (name.len >= 2 and name[0] == '"' and name[name.len - 1] == '"') name = name[1 .. name.len - 1];
        return sanitizeFileName(name);
    }
    return null;
}

fn sanitizeFileName(name: []const u8) ?[]const u8 {
    var base = name;
    if (std.mem.lastIndexOfAny(u8, base, "/\\")) |i| base = base[i + 1 ..];
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return null;
    for (base) |ch| if (ch < 0x20 or ch == ':') return null;
    return base;
}

test parseContentRangeTotal {
    try std.testing.expectEqual(@as(?u64, 12345), parseContentRangeTotal("bytes 0-0/12345"));
    try std.testing.expectEqual(@as(?u64, 0), parseContentRangeTotal("bytes */0"));
    try std.testing.expectEqual(@as(?u64, null), parseContentRangeTotal("bytes 0-0/*"));
    try std.testing.expectEqual(@as(?u64, null), parseContentRangeTotal("items 0-0/5"));
}

test parseContentDispositionFileName {
    try std.testing.expectEqualStrings("a.zip", parseContentDispositionFileName("attachment; filename=\"a.zip\"").?);
    try std.testing.expectEqualStrings("b.bin", parseContentDispositionFileName("attachment;filename=b.bin").?);
    try std.testing.expectEqualStrings("passwd", parseContentDispositionFileName("attachment; filename=\"../../etc/passwd\"").?);
    try std.testing.expect(parseContentDispositionFileName("inline") == null);
    try std.testing.expect(parseContentDispositionFileName("attachment; filename=\"..\"") == null);
}
