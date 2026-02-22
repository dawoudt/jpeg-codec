const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;
    const allocator = std.heap.page_allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var buffer: [1024]u8 = undefined;

    const d: std.Io.Dir = try .openDirAbsolute(io, "/Users/dtabboush/Downloads/", .{});
    defer d.close(io);

    var f = try d.openFile(io, "JPEG_example_flower.jpg", .{ .mode = .read_only });
    defer f.close(io);
    var fr = f.reader(io, &buffer);
    var fr_int = &fr.interface;

    const bytes_to_read = 16;
    var idx: usize = 0;
    std.debug.print("out: ", .{});

    while (idx < bytes_to_read) : (idx += 1) {
        const b = try fr_int.takeByte();
        std.debug.print("{x} ", .{b});
    }
}
