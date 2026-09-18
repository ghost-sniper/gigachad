//! gigachad：支持 HTTP(S)/FTP/SFTP 的多连接分段下载库。
pub const cli = @import("cli.zig");
pub const downloader = @import("downloader.zig");
pub const progress = @import("progress.zig");
pub const proto = @import("proto.zig");
pub const segment = @import("segment.zig");
pub const state = @import("state.zig");
pub const url = @import("url.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
