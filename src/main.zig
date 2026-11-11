const std = @import("std");
const Io = std.Io;

/// エントリポイント。Zig 0.15 以降は `std.process.Init` を受け取る形式。
pub fn main(init: std.process.Init) !void {
    // stdout はバッファ付き Writer 経由で書く（最後に flush が必要）
    var stdout_buf: [256]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), init.io, &stdout_buf);
    const out = &stdout_file.interface;

    try out.print("Hello, Zig!\n", .{});

    // コマンドライン引数（args[0] は実行ファイル名）
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    try out.print("argc = {d}\n", .{args.len});
    for (args, 0..) |arg, i| {
        try out.print("  argv[{d}] = {s}\n", .{ i, arg });
    }

    try out.flush();
}

// テストは `zig build test` で実行される。
test "add" {
    try std.testing.expectEqual(@as(i32, 42), add(40, 2));
}

fn add(a: i32, b: i32) i32 {
    return a + b;
}
