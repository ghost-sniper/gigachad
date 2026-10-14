const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // C 依赖在 debug 模式下用 fast 编译：UBSan 会误报 mbedTLS/libssh2 中
    // 的一些有意为之的写法，而且它们本身不需要调试。
    const c_optimize: std.lang.Optimize = if (optimize == .debug) .fast else optimize;
    const mbedtls = buildMbedTls(b, target, c_optimize);
    const libssh2 = buildLibssh2(b, target, c_optimize, mbedtls);

    // libssh2 头文件的 Zig 绑定。
    const ssh_c = b.addTranslateC(.{
        .root_source_file = b.path("src/proto/ssh_c.h"),
        .target = target,
        .optimize = optimize,
    });
    ssh_c.addIncludePath(b.dependency("libssh2", .{}).path("include"));

    const mod = b.addModule("gigachad", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "ssh_c", .module = ssh_c.createModule() },
        },
    });
    mod.linkLibrary(libssh2);

    const exe = b.addExecutable(.{
        .name = "gigachad",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gigachad", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

fn buildMbedTls(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Step.Compile {
    const dep = b.dependency("mbedtls", .{});
    const lib = b.addLibrary(.{
        .name = "mbedtls",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const m = lib.root_module;
    addMbedTlsConfig(b, m);
    m.addIncludePath(dep.path("include"));
    m.addIncludePath(dep.path("library"));
    m.addCSourceFiles(.{
        .root = dep.path("library"),
        .files = &mbedtls_sources,
        .flags = &c_flags,
    });
    m.addCSourceFile(.{ .file = b.path("src/c/mbedtls_threading.c"), .flags = &c_flags });
    if (target.result.os.tag == .windows) {
        m.linkSystemLibrary("bcrypt", .{});
        m.linkSystemLibrary("ws2_32", .{});
    }
    lib.installHeadersDirectory(dep.path("include"), "", .{});
    return lib;
}

const c_flags = [_][]const u8{"-std=gnu99"};

/// mbedTLS 的结构体布局取决于配置（例如 MBEDTLS_THREADING_C），
/// 所以 mbedTLS 自身和所有包含其头文件的代码必须使用同一份配置。
fn addMbedTlsConfig(b: *std.Build, m: *std.Build.Module) void {
    m.addIncludePath(b.path("src/c"));
    m.addCMacro("MBEDTLS_USER_CONFIG_FILE", "\"mbedtls_user_config.h\"");
}

fn buildLibssh2(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    mbedtls: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const dep = b.dependency("libssh2", .{});
    const lib = b.addLibrary(.{
        .name = "ssh2",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const m = lib.root_module;
    addMbedTlsConfig(b, m);
    m.addIncludePath(dep.path("include"));
    m.addIncludePath(dep.path("src"));
    m.linkLibrary(mbedtls);
    m.addCMacro("LIBSSH2_MBEDTLS", "1");
    m.addCMacro("LIBSSH2DEBUG_DISABLED", "1");

    if (target.result.os.tag == .windows) {
        m.linkSystemLibrary("ws2_32", .{});
        m.linkSystemLibrary("crypt32", .{});
    } else {
        // Windows 由 libssh2_setup.h 自动配置；其他平台补齐 configure 通常探测出的宏。
        for ([_][]const u8{
            "HAVE_UNISTD_H",     "HAVE_INTTYPES_H",   "HAVE_SYS_SELECT_H",
            "HAVE_SYS_UIO_H",    "HAVE_SYS_SOCKET_H", "HAVE_SYS_IOCTL_H",
            "HAVE_SYS_TIME_H",   "HAVE_SYS_UN_H",     "HAVE_ARPA_INET_H",
            "HAVE_NETINET_IN_H", "HAVE_GETTIMEOFDAY", "HAVE_STRTOLL",
            "HAVE_SNPRINTF",     "HAVE_POLL",         "HAVE_O_NONBLOCK",
        }) |name| m.addCMacro(name, "1");
    }

    m.addCSourceFiles(.{
        .root = dep.path("src"),
        .files = &libssh2_sources,
        .flags = &c_flags,
    });
    m.addCSourceFile(.{ .file = b.path("src/c/ssh_socket.c"), .flags = &c_flags });
    return lib;
}

const libssh2_sources = [_][]const u8{
    "agent.c",             "bcrypt_pbkdf.c", "channel.c",   "comp.c",      "chacha.c",
    "cipher-chachapoly.c", "crypt.c",        "crypto.c",    "global.c",    "hostkey.c",
    "keepalive.c",         "kex.c",          "knownhost.c", "mac.c",       "misc.c",
    "packet.c",            "pem.c",          "poly1305.c",  "publickey.c", "scp.c",
    "session.c",           "sftp.c",         "transport.c", "userauth.c",  "userauth_kbd_packet.c",
    "version.c",
};

const mbedtls_sources = [_][]const u8{
    "aes.c",                 "aesce.c",             "aesni.c",                       "aria.c",
    "asn1parse.c",           "asn1write.c",         "base64.c",                      "bignum.c",
    "bignum_core.c",         "bignum_mod.c",        "bignum_mod_raw.c",              "block_cipher.c",
    "camellia.c",            "ccm.c",               "chacha20.c",                    "chachapoly.c",
    "cipher.c",              "cipher_wrap.c",       "cmac.c",                        "constant_time.c",
    "ctr_drbg.c",            "debug.c",             "des.c",                         "dhm.c",
    "ecdh.c",                "ecdsa.c",             "ecjpake.c",                     "ecp.c",
    "ecp_curves.c",          "ecp_curves_new.c",    "entropy.c",                     "entropy_poll.c",
    "error.c",               "gcm.c",               "hkdf.c",                        "hmac_drbg.c",
    "lmots.c",               "lms.c",               "md.c",                          "md5.c",
    "memory_buffer_alloc.c", "mps_reader.c",        "mps_trace.c",                   "net_sockets.c",
    "nist_kw.c",             "oid.c",               "padlock.c",                     "pem.c",
    "pk.c",                  "pk_ecc.c",            "pk_wrap.c",                     "pkcs12.c",
    "pkcs5.c",               "pkcs7.c",             "pkparse.c",                     "pkwrite.c",
    "platform.c",            "platform_util.c",     "poly1305.c",                    "psa_crypto.c",
    "psa_crypto_aead.c",     "psa_crypto_cipher.c", "psa_crypto_client.c",           "psa_crypto_driver_wrappers_no_static.c",
    "psa_crypto_ecp.c",      "psa_crypto_ffdh.c",   "psa_crypto_hash.c",             "psa_crypto_mac.c",
    "psa_crypto_pake.c",     "psa_crypto_rsa.c",    "psa_crypto_se.c",               "psa_crypto_slot_management.c",
    "psa_crypto_storage.c",  "psa_its_file.c",      "psa_util.c",                    "ripemd160.c",
    "rsa.c",                 "rsa_alt_helpers.c",   "sha1.c",                        "sha256.c",
    "sha3.c",                "sha512.c",            "ssl_cache.c",                   "ssl_ciphersuites.c",
    "ssl_client.c",          "ssl_cookie.c",        "ssl_debug_helpers_generated.c", "ssl_msg.c",
    "ssl_ticket.c",          "ssl_tls.c",           "ssl_tls12_client.c",            "ssl_tls12_server.c",
    "ssl_tls13_client.c",    "ssl_tls13_generic.c", "ssl_tls13_keys.c",              "ssl_tls13_server.c",
    "threading.c",           "timing.c",            "version.c",                     "version_features.c",
    "x509.c",                "x509_create.c",       "x509_crl.c",                    "x509_crt.c",
    "x509_csr.c",            "x509write.c",         "x509write_crt.c",               "x509write_csr.c",
};
