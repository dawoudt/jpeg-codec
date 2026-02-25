const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args_buffer: [2048]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&args_buffer);
    const alloc = fba.threadSafeAllocator();
    const args = try init.minimal.args.toSlice(alloc);

    var path = std.mem.splitBackwardsAny(u8, args[1], "/");
    const file_name = path.first();
    const directory_path = path.rest();

    const directory: std.Io.Dir = try .openDirAbsolute(io, directory_path, .{});
    defer directory.close(io);

    var file = try directory.openFile(io, file_name, .{ .mode = .read_only });
    defer file.close(io);

    var file_buffer: [1024]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);
    var file_reader_intf = &file_reader.interface;
    while (true) {
        const byte = try file_reader_intf.takeByte();
        if (byte == MARKER) {
            const next_byte = try file_reader_intf.takeByte();
            if (next_byte == MARKER_CODE_SOI) {
                std.debug.print("SOI: {x}{x}", .{ byte, next_byte });
            } else if (next_byte == MARKER_CODE_EOI) {
                std.debug.print("SOI: {x}{x}", .{ byte, next_byte });
                return 0;
            }
        }
    }
}

const MARKER = 0xFF;
const MARKER_CODE_SOI = 0xD8; // start of image
const MARKER_CODE_EOI = 0xD8; // end of image
