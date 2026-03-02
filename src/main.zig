const std = @import("std");

pub const std_options: std.Options = .{ .log_level = .info };

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

    var dht_num: usize = 0;
    var dqt_num: usize = 0;
    var sos_num: usize = 0;

    while (true) {
        const byte = try file_reader_intf.takeByte();
        if (byte == MARKER) {
            const next_byte = try file_reader_intf.takeByte();
            std.log.debug("{X}:\n", .{MARKER});
            if (0xF & (next_byte >> 4) == 0xE) { // APP MARKER
                switch (0xF & next_byte) {
                    0x0 => { // APP0
                        var buf: [1024]u8 = undefined;
                        const out = try read_payload(file_reader_intf, &buf);
                        std.debug.print("APP{d}:\n", .{0xF & next_byte});

                        var start: usize = 0;
                        var end: usize = 5;
                        const identifier = out[start..end]; // null terminated
                        std.debug.print("\tidentifier: {s}\n", .{identifier});

                        if (std.mem.eql(u8, identifier, &JFIF)) { // JFIF
                            start = end;
                            end = start + 2;
                            const version_bytes = out[start..end];
                            const major: u8 = version_bytes[0];
                            const minor: u8 = version_bytes[1];
                            std.debug.print("\tversion: {d}.{d:0>2}\n", .{ major, minor });

                            start = end;
                            end = start + 1;
                            const density = out[start..end];
                            std.debug.print("\tdensity: {x}\n", .{density});

                            start = end;
                            end = start + 2;
                            const Xdensity_bytes = out[start..end];
                            const Xdensity = std.mem.readInt(u16, Xdensity_bytes[0..2], .big);
                            std.debug.print("\tXdensity: {d}: (hex: {X})\n", .{ Xdensity, Xdensity });

                            start = end;
                            end = start + 2;
                            const Ydensity_bytes = out[start..end];
                            const Ydensity = std.mem.readInt(u16, Ydensity_bytes[0..2], .big);
                            std.debug.print("\tYdensity: {d} (hex: {X})\n", .{ Ydensity, Ydensity });

                            start = end;
                            end = start + 1;
                            const Xthumbnail_bytes = out[start..end];
                            const Xthumbnail = std.mem.readInt(u8, Xthumbnail_bytes[0..1], .big);
                            std.debug.print("\tXthumbnail: {d}\n", .{Xthumbnail});

                            start = end;
                            end = start + 1;
                            const Ythumbnail_bytes = out[start..end];
                            const Ythumbnail = std.mem.readInt(u8, Ythumbnail_bytes[0..1], .big);
                            std.debug.print("\tYthumbnail: {d}\n", .{Ythumbnail});

                            // Thumbnail data
                            // Uncompressed 24 bit RGB (8 bits per color channel) raster thumbnail data in the order R0, G0, B0, ... Rn-1, Gn-1, Bn-1;
                            // n = Xthumbnail × Ythumbnail
                            // 3 × n
                            if ((Xthumbnail != 0 and Ythumbnail != 0)) {
                                start = end;
                                end = (Xthumbnail * Ythumbnail) * 3;
                                const thumbnail_bytes = out[start..end];
                                std.debug.print("Thumbnail bytes: [{x}]", .{thumbnail_bytes});
                            }
                        } else if (std.mem.eql(u8, identifier, &JFXX)) { // JFXX
                            // TODO: implement
                            return error.NotImplementd;
                        }

                        continue;
                    },
                    0x1...0xF => {
                        var buf: [1024]u8 = undefined;
                        const out = try read_payload(file_reader_intf, &buf);
                        std.debug.print("APP{d}: {s}\n\n", .{ 0xF & next_byte, out });
                        continue;
                    },
                    else => unreachable,
                }
            }
            switch (next_byte) {
                MARKER_FILL => continue,
                MARKER_CODE_SOI => std.debug.print("SOI[{X}]\n", .{next_byte}),
                MARKER_CODE_EOI => {
                    std.debug.print("EOI[{X}]\n", .{next_byte});
                    return std.process.cleanExit(io);
                },
                MARKER_BYTE_STUFFING => {
                    std.log.debug("Stuffing: [{X}]", .{next_byte});
                },
                COM => {
                    var buf: [1024]u8 = undefined;
                    const out = try read_payload(file_reader_intf, &buf);
                    std.debug.print("COM: {s}\n\n", .{out});
                },
                DHT => {
                    dht_num += 1;
                    var buf: [4096]u8 = undefined;
                    const out = try read_payload(file_reader_intf, &buf);
                    std.debug.print("Define Huffman Table {d}: {any}\n\n", .{ dht_num, out });
                },
                DQT => {
                    dqt_num += 1;
                    var buf: [4096]u8 = undefined;
                    const out = try read_payload(file_reader_intf, &buf);
                    std.debug.print("Define Quantization Table {d}: {any}\n\n", .{ dqt_num, out });
                },
                SOS => {
                    sos_num += 1;
                    var buf: [4096]u8 = undefined;
                    const out = try read_payload(file_reader_intf, &buf);
                    std.debug.print("Start of scan {d}: {any}\n\n", .{ sos_num, out });
                },
                SOF0 => {
                    var buf: [4096]u8 = undefined;
                    const out = try read_payload(file_reader_intf, &buf);
                    std.debug.print("Start of Frame: {any}\n\n", .{out});
                },
                SOF2 => {
                    var buf: [4096]u8 = undefined;
                    const out = try read_payload(file_reader_intf, &buf);
                    std.debug.print("Start of Frame 2: {any}\n\n", .{out});
                },

                else => {
                    std.debug.print("UNHANDLED MARKER: {X:0>2}\n", .{next_byte});
                    continue;
                },
            }
        }
    }
}
fn read_payload(reader: *std.Io.Reader, buf: []u8) ![]u8 {
    const s1: u8 = try reader.takeByte();
    const s2: u8 = try reader.takeByte();
    const len: u16 = std.mem.readInt(u16, &[2]u8{ s1, s2 }, .big);
    const payload_len = len - 2;
    std.log.debug("payload length: {d}", .{payload_len});
    try reader.readSliceAll(buf[0..payload_len]);
    return buf[0..payload_len];
}

const MARKER = 0xFF;
const MARKER_CODE_SOI = 0xD8; // start of image
const MARKER_CODE_EOI = 0xD9; // end of image
const MARKER_FILL = 0xFF;
const MARKER_BYTE_STUFFING = 0x00; // Fill inside entropy-coded scan data

const JFIF_APP0 = 0xE0;
const COM = 0xFE; // Comments
const DHT = 0xC4; // Define Huffman Table
const DQT = 0xDB; // Define Quantization Table
const SOS = 0xDA; // Start of scan
const SOF0 = 0xC0; // Start of Frame
const SOF2 = 0xC2; // Start of Frame

const JFIF = [5]u8{ 0x4A, 0x46, 0x49, 0x46, 0x00 }; // JFIF\0
const JFXX = [5]u8{ 0x4A, 0x46, 0x58, 0x58, 0x00 }; // JFXX\0
