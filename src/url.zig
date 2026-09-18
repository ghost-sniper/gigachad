//! URL 解析：把原始字符串拆成各协议需要的字段（已做百分号解码）。
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Scheme = enum {
    http,
    https,
    ftp,
    sftp,

    pub fn defaultPort(s: Scheme) u16 {
        return switch (s) {
            .http => 80,
            .https => 443,
            .ftp => 21,
            .sftp => 22,
        };
    }
};

pub const Url = struct {
    /// 用户输入的原始 URL（HTTP 请求直接使用它）。
    raw: []const u8,
    uri: std.Uri,
    scheme: Scheme,
    host: []const u8,
    port: u16,
    user: ?[]const u8,
    password: ?[]const u8,
    /// 解码后的路径，总是以 '/' 开头。
    path: []const u8,

    pub const ParseError = error{ InvalidUrl, UnsupportedScheme, MissingHost } || Allocator.Error;

    /// 返回的字段可能引用 `raw`，也可能在 `arena` 中分配。
    pub fn parse(arena: Allocator, raw: []const u8) ParseError!Url {
        const uri = std.Uri.parse(raw) catch return error.InvalidUrl;
        const scheme = std.meta.stringToEnum(Scheme, uri.scheme) orelse blk: {
            // 大小写不敏感
            var buf: [8]u8 = undefined;
            if (uri.scheme.len > buf.len) return error.UnsupportedScheme;
            const lower = std.ascii.lowerString(&buf, uri.scheme);
            break :blk std.meta.stringToEnum(Scheme, lower) orelse return error.UnsupportedScheme;
        };
        const host_c = uri.host orelse return error.MissingHost;
        const host = try host_c.toRawMaybeAlloc(arena);
        if (host.len == 0) return error.MissingHost;

        var path = try uri.path.toRawMaybeAlloc(arena);
        if (path.len == 0) path = "/";

        return .{
            .raw = raw,
            .uri = uri,
            .scheme = scheme,
            .host = host,
            .port = uri.port orelse scheme.defaultPort(),
            .user = if (uri.user) |u| try u.toRawMaybeAlloc(arena) else null,
            .password = if (uri.password) |p| try p.toRawMaybeAlloc(arena) else null,
            .path = path,
        };
    }

    /// 从路径推断本地文件名；路径以 '/' 结尾时返回 null。
    pub fn fileName(u: Url) ?[]const u8 {
        const base = std.fs.path.basenamePosix(u.path);
        if (base.len == 0 or std.mem.endsWith(u8, u.path, "/")) return null;
        return base;
    }
};

test "parse http" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const u = try Url.parse(arena, "https://example.com/dir/file%20name.iso?x=1");
    try std.testing.expectEqual(Scheme.https, u.scheme);
    try std.testing.expectEqualStrings("example.com", u.host);
    try std.testing.expectEqual(@as(u16, 443), u.port);
    try std.testing.expectEqualStrings("/dir/file name.iso", u.path);
    try std.testing.expectEqualStrings("file name.iso", u.fileName().?);
    try std.testing.expect(u.user == null);
}

test "parse sftp with credentials" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const u = try Url.parse(arena, "SFTP://bob:p%40ss@10.0.0.1:2222/home/bob/a.tar.gz");
    try std.testing.expectEqual(Scheme.sftp, u.scheme);
    try std.testing.expectEqualStrings("10.0.0.1", u.host);
    try std.testing.expectEqual(@as(u16, 2222), u.port);
    try std.testing.expectEqualStrings("bob", u.user.?);
    try std.testing.expectEqualStrings("p@ss", u.password.?);
    try std.testing.expectEqualStrings("a.tar.gz", u.fileName().?);
}

test "parse errors and defaults" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.UnsupportedScheme, Url.parse(arena, "gopher://x/y"));
    try std.testing.expectError(error.InvalidUrl, Url.parse(arena, "not a url"));
    const u = try Url.parse(arena, "ftp://ftp.example.org");
    try std.testing.expectEqual(@as(u16, 21), u.port);
    try std.testing.expectEqualStrings("/", u.path);
    try std.testing.expect(u.fileName() == null);
}
