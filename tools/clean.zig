const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const cwd = std.Io.Dir.cwd();
    // build.zig 把工作目录固定为项目根目录；只删除这两个构建产物目录。
    for ([_][]const u8{ "zig-out", ".zig-cache" }) |path| {
        try cwd.deleteTree(init.io, path);
    }
}
