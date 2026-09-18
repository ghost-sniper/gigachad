//! SFTP，基于 libssh2（mbedTLS 后端）。每个分段各开一个 SSH 会话。
//! libssh2 是阻塞式 C API，运行在各自的并发任务（线程）里。
const std = @import("std");
const builtin = @import("builtin");
const c = @import("ssh_c");
const proto = @import("../proto.zig");
const Url = @import("../url.zig").Url;

/// 进程启动时调用一次，必须早于任何 SFTP 操作（libssh2_init 不是线程安全的）。
pub fn globalInit() !void {
    c.gigachad_mbedtls_threading_init();
    if (c.gigachad_net_init() != 0) return error.NetworkInitFailed;
    if (c.libssh2_init(0) != 0) return error.Libssh2InitFailed;
}

pub fn globalDeinit() void {
    c.libssh2_exit();
}

const Session = struct {
    sock: c.libssh2_socket_t,
    session: *c.LIBSSH2_SESSION,
    sftp: *c.LIBSSH2_SFTP,
    diag: *proto.Diag,
    /// keyboard-interactive 回调通过 session abstract 拿到它。
    kbd_password: ?[]const u8 = null,

    /// 连接、握手、校验主机密钥、认证，最后启动 SFTP 子系统。
    /// `announce` 为 true 时，未知主机密钥会打印一次警告（只在探测阶段打印）。
    fn open(s: *Session, ctx: *const proto.Context, url: *const Url, diag: *proto.Diag, announce: bool) !void {
        s.* = .{ .sock = undefined, .session = undefined, .sftp = undefined, .diag = diag };

        var host_z: [256]u8 = undefined;
        const host = std.fmt.bufPrintZ(&host_z, "{s}", .{url.host}) catch return error.HostNameTooLong;
        if (c.gigachad_tcp_connect(host.ptr, url.port, &s.sock) != 0) {
            diag.set("无法连接 {s}:{d}", .{ url.host, url.port });
            return error.ConnectionFailed;
        }
        errdefer c.gigachad_tcp_close(s.sock);

        s.session = c.libssh2_session_init_ex(null, null, null, @ptrCast(s)) orelse return error.OutOfMemory;
        errdefer _ = c.libssh2_session_free(s.session);
        c.libssh2_session_set_blocking(s.session, 1);
        c.libssh2_session_set_timeout(s.session, 60 * 1000);

        if (c.libssh2_session_handshake(s.session, s.sock) != 0) return s.fail(error.SshHandshakeFailed);
        errdefer _ = c.libssh2_session_disconnect_ex(s.session, c.SSH_DISCONNECT_BY_APPLICATION, "bye", "");

        try s.verifyHostKey(ctx, url, announce);
        try s.authenticate(ctx, url);

        s.sftp = c.libssh2_sftp_init(s.session) orelse return s.fail(error.SftpInitFailed);
    }

    fn close(s: *Session) void {
        _ = c.libssh2_sftp_shutdown(s.sftp);
        _ = c.libssh2_session_disconnect_ex(s.session, c.SSH_DISCONNECT_BY_APPLICATION, "bye", "");
        _ = c.libssh2_session_free(s.session);
        c.gigachad_tcp_close(s.sock);
    }

    /// 把 libssh2 的最后一条错误信息写入 diag，再返回 `err`。
    fn fail(s: *Session, err: anyerror) anyerror {
        s.noteError();
        return err;
    }

    fn noteError(s: *Session) void {
        var msg: [*c]u8 = null;
        var len: c_int = 0;
        _ = c.libssh2_session_last_error(s.session, &msg, &len, 0);
        if (msg != null and len > 0) s.diag.set("SSH: {s}", .{msg[0..@intCast(len)]});
    }

    fn verifyHostKey(s: *Session, ctx: *const proto.Context, url: *const Url, announce: bool) !void {
        var key_len: usize = 0;
        var key_type: c_int = 0;
        const key = c.libssh2_session_hostkey(s.session, &key_len, &key_type) orelse
            return s.fail(error.SshNoHostKey);

        const found: c_int = blk: {
            const home = ctx.home orelse break :blk c.LIBSSH2_KNOWNHOST_CHECK_NOTFOUND;
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "{s}/.ssh/known_hosts", .{home}) catch
                break :blk c.LIBSSH2_KNOWNHOST_CHECK_NOTFOUND;
            const kh = c.libssh2_knownhost_init(s.session) orelse return error.OutOfMemory;
            defer c.libssh2_knownhost_free(kh);
            if (c.libssh2_knownhost_readfile(kh, path.ptr, c.LIBSSH2_KNOWNHOST_FILE_OPENSSH) < 0)
                break :blk c.LIBSSH2_KNOWNHOST_CHECK_NOTFOUND;

            var host_z: [256]u8 = undefined;
            const host = std.fmt.bufPrintZ(&host_z, "{s}", .{url.host}) catch unreachable;
            const typemask = c.LIBSSH2_KNOWNHOST_TYPE_PLAIN | c.LIBSSH2_KNOWNHOST_KEYENC_RAW | knownHostKeyType(key_type);
            break :blk c.libssh2_knownhost_checkp(kh, host.ptr, url.port, key, key_len, typemask, null);
        };

        switch (found) {
            c.LIBSSH2_KNOWNHOST_CHECK_MATCH => {},
            c.LIBSSH2_KNOWNHOST_CHECK_MISMATCH => {
                s.diag.set("{s} 的主机密钥与 known_hosts 中记录的不一致，可能存在中间人攻击", .{url.host});
                return error.SshHostKeyMismatch;
            },
            else => if (announce) {
                var fp_buf: [64]u8 = undefined;
                std.log.warn("{s} 不在 ~/.ssh/known_hosts 中，主机密钥指纹 SHA256:{s}", .{
                    url.host, s.fingerprint(&fp_buf),
                });
            },
        }
    }

    fn fingerprint(s: *Session, buf: *[64]u8) []const u8 {
        const hash = c.libssh2_hostkey_hash(s.session, c.LIBSSH2_HOSTKEY_HASH_SHA256) orelse return "?";
        const encoder = std.base64.standard_no_pad.Encoder;
        return encoder.encode(buf, @as([*]const u8, @ptrCast(hash))[0..32]);
    }

    fn authenticate(s: *Session, ctx: *const proto.Context, url: *const Url) !void {
        const user = url.user orelse ctx.local_user orelse {
            s.diag.set("未指定用户名，请写成 sftp://user@host/path", .{});
            return error.SshNoUser;
        };
        const ulen: c_uint = @intCast(user.len);
        var user_z: [256]u8 = undefined;
        const user_c = std.fmt.bufPrintZ(&user_z, "{s}", .{user}) catch return error.UserNameTooLong;

        const methods_ptr = c.libssh2_userauth_list(s.session, user_c.ptr, ulen);
        if (methods_ptr == null) {
            // 服务器接受了 "none" 认证。
            if (c.libssh2_userauth_authenticated(s.session) != 0) return;
            return s.fail(error.SshAuthFailed);
        }
        const methods = std.mem.span(methods_ptr);
        const password = ctx.auth.password orelse url.password;

        if (hasMethod(methods, "publickey")) {
            if (ctx.auth.identity) |key| {
                if (try s.authKeyFile(user_c, key, ctx.auth.passphrase)) return;
            } else {
                if (s.authAgent(user_c)) return;
                // mbedTLS 后端不支持 ed25519，只尝试 ECDSA 和 RSA 默认密钥。
                if (ctx.home) |home| for ([_][]const u8{ "id_ecdsa", "id_rsa" }) |name| {
                    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                    const path = std.fmt.bufPrint(&path_buf, "{s}/.ssh/{s}", .{ home, name }) catch continue;
                    if (try s.authKeyFile(user_c, path, ctx.auth.passphrase)) return;
                };
            }
        }
        if (password) |pw| {
            if (hasMethod(methods, "password")) {
                if (c.libssh2_userauth_password_ex(s.session, user_c.ptr, ulen, pw.ptr, @intCast(pw.len), null) == 0) return;
            }
            if (hasMethod(methods, "keyboard-interactive")) {
                s.kbd_password = pw;
                if (c.libssh2_userauth_keyboard_interactive_ex(s.session, user_c.ptr, ulen, kbdCallback) == 0) return;
            }
        }
        s.noteError();
        if (password == null and s.diag.len == 0) s.diag.set("服务器支持的认证方式：{s}", .{methods});
        return error.SshAuthFailed;
    }

    /// 文件不存在时返回 false，继续尝试其他方式。
    fn authKeyFile(s: *Session, user: [:0]const u8, path: []const u8, passphrase: ?[]const u8) !bool {
        var path_z: [std.fs.max_path_bytes]u8 = undefined;
        const key = std.fmt.bufPrintZ(&path_z, "{s}", .{path}) catch return false;
        var pass_z: [1024]u8 = undefined;
        const pass: ?[*:0]const u8 = if (passphrase) |p|
            (std.fmt.bufPrintZ(&pass_z, "{s}", .{p}) catch return error.PassphraseTooLong).ptr
        else
            null;
        const rc = c.libssh2_userauth_publickey_fromfile_ex(s.session, user.ptr, @intCast(user.len), null, key.ptr, pass);
        if (rc == 0) return true;
        if (rc == c.LIBSSH2_ERROR_FILE) return false;
        s.noteError();
        return false;
    }

    /// ssh-agent（Windows 上是 OpenSSH agent 或 Pageant）。
    fn authAgent(s: *Session, user: [:0]const u8) bool {
        const agent = c.libssh2_agent_init(s.session) orelse return false;
        defer c.libssh2_agent_free(agent);
        if (c.libssh2_agent_connect(agent) != 0) return false;
        defer _ = c.libssh2_agent_disconnect(agent);
        if (c.libssh2_agent_list_identities(agent) != 0) return false;

        var prev: ?*c.struct_libssh2_agent_publickey = null;
        while (true) {
            var ident: ?*c.struct_libssh2_agent_publickey = null;
            if (c.libssh2_agent_get_identity(agent, &ident, prev) != 0) return false;
            if (c.libssh2_agent_userauth(agent, user.ptr, ident) == 0) return true;
            prev = ident;
        }
    }

    fn kbdCallback(
        name: [*c]const u8,
        name_len: c_int,
        instruction: [*c]const u8,
        instruction_len: c_int,
        num_prompts: c_int,
        prompts: [*c]const c.LIBSSH2_USERAUTH_KBDINT_PROMPT,
        responses: [*c]c.LIBSSH2_USERAUTH_KBDINT_RESPONSE,
        abstract: [*c]?*anyopaque,
    ) callconv(.c) void {
        _ = .{ name, name_len, instruction, instruction_len, prompts };
        const s: *Session = @ptrCast(@alignCast(abstract.*.?));
        const pw = s.kbd_password orelse return;
        // 对每个提示都回答密码；libssh2 会用 free() 释放这些内存。
        for (0..@intCast(num_prompts)) |i| {
            const mem: [*]u8 = @ptrCast(std.c.malloc(pw.len) orelse return);
            @memcpy(mem[0..pw.len], pw);
            responses[i].text = @ptrCast(mem);
            responses[i].length = @intCast(pw.len);
        }
    }

    fn openFile(s: *Session, url: *const Url) !*c.LIBSSH2_SFTP_HANDLE {
        const path = remotePath(url);
        const handle = c.libssh2_sftp_open_ex(s.sftp, path.ptr, @intCast(path.len), c.LIBSSH2_FXF_READ, 0, c.LIBSSH2_SFTP_OPENFILE);
        if (handle) |h| return h;
        return switch (c.libssh2_sftp_last_error(s.sftp)) {
            c.LIBSSH2_FX_NO_SUCH_FILE => blk: {
                s.diag.set("远程文件不存在：{s}", .{path});
                break :blk error.SftpFileNotFound;
            },
            c.LIBSSH2_FX_PERMISSION_DENIED => blk: {
                s.diag.set("没有权限读取：{s}", .{path});
                break :blk error.SftpPermissionDenied;
            },
            else => s.fail(error.SftpOpenFailed),
        };
    }
};

fn hasMethod(list: []const u8, method: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |m| if (std.mem.eql(u8, m, method)) return true;
    return false;
}

fn knownHostKeyType(hostkey_type: c_int) c_int {
    return switch (hostkey_type) {
        c.LIBSSH2_HOSTKEY_TYPE_RSA => c.LIBSSH2_KNOWNHOST_KEY_SSHRSA,
        c.LIBSSH2_HOSTKEY_TYPE_DSS => c.LIBSSH2_KNOWNHOST_KEY_SSHDSS,
        c.LIBSSH2_HOSTKEY_TYPE_ECDSA_256 => c.LIBSSH2_KNOWNHOST_KEY_ECDSA_256,
        c.LIBSSH2_HOSTKEY_TYPE_ECDSA_384 => c.LIBSSH2_KNOWNHOST_KEY_ECDSA_384,
        c.LIBSSH2_HOSTKEY_TYPE_ECDSA_521 => c.LIBSSH2_KNOWNHOST_KEY_ECDSA_521,
        c.LIBSSH2_HOSTKEY_TYPE_ED25519 => c.LIBSSH2_KNOWNHOST_KEY_ED25519,
        else => c.LIBSSH2_KNOWNHOST_KEY_UNKNOWN,
    };
}

/// URL 中的路径是绝对路径；"/~/x" 表示相对于用户主目录的 "x"。
fn remotePath(url: *const Url) []const u8 {
    if (std.mem.startsWith(u8, url.path, "/~/")) return url.path[3..];
    return url.path;
}

pub fn probe(ctx: *const proto.Context, url: *const Url, diag: *proto.Diag) !proto.Probe {
    var s: Session = undefined;
    try s.open(ctx, url, diag, true);
    defer s.close();
    const handle = try s.openFile(url);
    defer _ = c.libssh2_sftp_close_handle(handle);

    var attrs: c.LIBSSH2_SFTP_ATTRIBUTES = undefined;
    if (c.libssh2_sftp_fstat_ex(handle, &attrs, 0) != 0) return s.fail(error.SftpStatFailed);
    const size: ?u64 = if (attrs.flags & c.LIBSSH2_SFTP_ATTR_SIZE != 0) attrs.filesize else null;
    return .{ .size = size, .ranges = true };
}

pub fn fetch(
    ctx: *const proto.Context,
    url: *const Url,
    offset: u64,
    length: ?u64,
    sink: proto.Sink,
    diag: *proto.Diag,
) !void {
    var s: Session = undefined;
    try s.open(ctx, url, diag, false);
    defer s.close();
    const handle = try s.openFile(url);
    defer _ = c.libssh2_sftp_close_handle(handle);

    c.libssh2_sftp_seek64(handle, offset);
    var buf: [256 * 1024]u8 = undefined;
    var left = length;
    while (true) {
        const cap = if (left) |l| @min(buf.len, l) else buf.len;
        if (cap == 0) return;
        const n = c.libssh2_sftp_read(handle, &buf, cap);
        if (n < 0) return s.fail(error.SftpReadFailed);
        if (n == 0) {
            if (left != null) return error.UnexpectedEndOfStream;
            return;
        }
        const got: usize = @intCast(n);
        try sink.write(buf[0..got]);
        if (left) |*l| l.* -= got;
    }
}

test hasMethod {
    try std.testing.expect(hasMethod("publickey,password", "password"));
    try std.testing.expect(!hasMethod("publickey,keyboard-interactive", "password"));
}

test remotePath {
    var u: Url = undefined;
    u.path = "/~/data/x.bin";
    try std.testing.expectEqualStrings("data/x.bin", remotePath(&u));
    u.path = "/srv/x.bin";
    try std.testing.expectEqualStrings("/srv/x.bin", remotePath(&u));
}
