const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [256]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buf);

    try stdout.interface.print("Hello, Zig!\n", .{});
    try stdout.interface.flush();
}
