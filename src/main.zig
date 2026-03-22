const std = @import("std");

pub const std_options: std.Options = .{ .log_level = .info };

const ByteRepresentation = enum(u8) {
    small_hex = 'x',
    big_hex = 'X',
    decimal = 'd',
};

const MARKER = 0xFF;
const SOI = 0xD8; // start of image
const EOI = 0xD9; // end of image
const FILL = 0xFF;
const BYTE_STUFFING = 0x00; // Fill inside entropy-coded scan data
const COM = 0xFE; // Comments
const DHT = 0xC4; // Define Huffman Table
const DQT = 0xDB; // Define Quantization Table
const SOS = 0xDA; // Start of scan
const SOF0 = 0xC0; // Start of Frame
const SOF2 = 0xC2; // Start of Frame 2

const JFIF = [5]u8{ 0x4A, 0x46, 0x49, 0x46, 0x00 }; // JFIF\0
const JFXX = [5]u8{ 0x4A, 0x46, 0x58, 0x58, 0x00 }; // JFXX\0

const Component = enum(u3) {
    Luminance = 1,
    BlueChroma = 2,
    RedChroma = 3,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var alloc_buffer: [1024 * 100]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&alloc_buffer);
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
            std.log.debug("Marker: {X}:\n", .{MARKER});
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
                FILL => continue,
                SOI => std.debug.print("SOI: {X}\n", .{next_byte}),
                EOI => {
                    std.debug.print("EOI: {X}\n", .{next_byte});
                    return std.process.cleanExit(io);
                },
                BYTE_STUFFING => {
                    std.log.debug("Stuffing: {X}", .{next_byte});
                },
                COM => {
                    var buf: [1024]u8 = undefined;
                    const out = try read_payload(file_reader_intf, &buf);
                    std.debug.print("COM: {s}\n\n", .{out});
                },
                DHT => {
                    dht_num += 1;
                    var buf: [4096]u8 = undefined;
                    var dht: HuffmanTable = try .init(dht_num, file_reader_intf, &buf, alloc);
                    defer dht.deinit();
                    dht.print();
                    // dht.print_table();
                },
                DQT => {
                    dqt_num += 1;
                    var buf: [4096]u8 = undefined;
                    const out = try read_payload(file_reader_intf, &buf);
                    std.debug.print("Define Quantization Table {d}: \n", .{dqt_num});
                    print_bytes(out, .small_hex);
                },
                SOS => {
                    sos_num += 1;
                    var buf: [4096]u8 = undefined;
                    const out = try read_payload(file_reader_intf, &buf);
                    std.debug.print("Start of scan {d}: \n", .{sos_num});
                    print_bytes(out, .small_hex);
                },
                SOF0 => {
                    var buf: [4096]u8 = undefined;
                    const out = try read_payload(file_reader_intf, &buf);
                    const precision_bytes = out[0..2];
                    const precision = std.mem.readInt(u16, precision_bytes[0..2], .big);
                    std.debug.print("Start of Frame: {any}\n", .{out});
                    std.debug.print("\tPrecision: {d}\n", .{precision});
                },
                SOF2 => {
                    var buf: [4096]u8 = undefined;
                    const out = try read_payload(file_reader_intf, &buf);
                    std.debug.print("Start of Frame 2: \n", .{});
                    // for (out) |value| {
                    //     std.debug.print("{X:0>2} ", .{value});
                    // }
                    // std.debug.print("\n", .{});
                    var start: usize = 0;
                    var end: usize = start + 1;

                    const precision: u8 = @intCast(out[start]);
                    std.debug.print("\tPrecision: {d}\n", .{precision});

                    start = end;
                    end = start + 2;
                    const height_bytes: []u8 = out[start..end];
                    const height: u16 = std.mem.readInt(u16, height_bytes[0..2], .big);
                    std.debug.print("\tHeight: {d}\n", .{height});

                    start = end;
                    end = start + 2;
                    const width_bytes: []u8 = out[start..end];
                    const width: u16 = std.mem.readInt(u16, width_bytes[0..2], .big);
                    std.debug.print("\tWidth: {d}\n", .{width});

                    start = end;
                    end = start + 1;

                    const num_of_components: u8 = @intCast(out[start]);
                    std.debug.print("\tNumber of Components: {d}\n", .{num_of_components});
                    var component_counter: usize = 0;
                    while (component_counter < num_of_components) : (component_counter += 1) {
                        start = end;
                        end = start + 1;
                        const component_id: u8 = @intCast(out[start]);
                        const component: Component = @enumFromInt(component_id);

                        start = end;
                        end = start + 1;
                        const sample: u8 = @intCast(out[start]);
                        const vertical_sample = sample & 0xF;
                        const horizontal_sample = (sample >> 4) & 0xF;
                        start = end;
                        end = start + 1;
                        const dct_tbl_num: u8 = @intCast(out[start]);
                        std.debug.print("\t    Component: {s}\n\t    Horizontal sample: {d}\n\t    Vertical sample: {d}\n\t    Qunatization Table: {d}\n\n", .{
                            @tagName(component),
                            horizontal_sample,
                            vertical_sample,
                            dct_tbl_num,
                        });
                    }
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

fn print_bytes(str: []u8, comptime fmt: ByteRepresentation) void {
    std.debug.print("\tRaw: ", .{});
    for (str) |b| {
        switch (fmt) {
            .small_hex, .big_hex => std.debug.print("{" ++ [_]u8{@intFromEnum(fmt)} ++ ":0>2} ", .{b}),
            else => std.debug.print("{" ++ [_]u8{@intFromEnum(fmt)} ++ "} ", .{b}),
        }
    }
    std.debug.print("\n\n", .{});
}

const HuffmanTable = struct {
    tbl_num: usize,
    data_len: u16,
    data_raw: []u8,

    class: u4,
    dst_id: u4,
    counts: [16]u8,
    symbols: []u8,
    table: std.AutoHashMap(u32, u8),

    pub fn deinit(self: *HuffmanTable) void {
        self.table.deinit();
    }

    pub fn init(num: usize, reader: *std.Io.Reader, buf: []u8, allocator: std.mem.Allocator) !HuffmanTable {
        const s1: u8 = try reader.takeByte();
        const s2: u8 = try reader.takeByte();
        const len: u16 = std.mem.readInt(u16, &[2]u8{ s1, s2 }, .big);
        const payload_len = len - 2;
        try reader.readSliceAll(buf[0..payload_len]);
        return initFromPayload(num, buf[0..payload_len], allocator);
    }

    pub fn initFromPayload(num: usize, data: []u8, allocator: std.mem.Allocator) !HuffmanTable {
        var num_of_symbols: usize = 0;
        for (data[1..17]) |s| num_of_symbols += s;

        var ht: HuffmanTable = .{
            .tbl_num = num,
            .data_len = @intCast(data.len + 2),
            .data_raw = data,
            .class = @truncate(data[0] >> 4),
            .dst_id = @truncate(data[0] & 0x0F),
            .counts = data[1..17].*,
            .symbols = data[17 .. 17 + num_of_symbols],
            .table = std.AutoHashMap(u32, u8).init(allocator),
        };
        try ht.build_table();
        return ht;
    }

    fn build_table(self: *HuffmanTable) !void {
        // TODO: Maybe Use ArrayList(.{.code, .value}) instead so its ordered.
        // Although then it would be O(N) instead of O(1)
        var code: u32 = 0;
        var symbol_idx: usize = 0; // this is global as we need to remember what we've proccesed.
        for (self.counts) |length| { // each item from the counts array is the length for the symbols sub set
            for (0..length) |_| { // iterate over the subset from 0 to length
                const symbol = self.symbols[symbol_idx]; // grab the symbol at the symbol_idx
                try self.table.put(code, symbol); // add it to the table
                code += 1; // increment the code
                symbol_idx += 1; // increment the symbol_idx
                std.log.debug("code += 1: {d}\n", .{code});
            }
            code = code << 1; // when we move to next count, we shift left (or append 0 to the right);
            std.log.debug("code = code << 1: {d}\n", .{code});
        }
    }

    fn print_table(self: HuffmanTable) void {
        var it = self.table.iterator();
        std.debug.print("-------------------Huffman Table--------------------\n", .{});
        while (it.next()) |entry| {
            std.debug.print("\tCode: {d:>5} | symbol: {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    pub fn print(self: HuffmanTable) void {
        std.debug.print("Huffman Table {d}: \n", .{self.tbl_num});
        std.debug.print("\tClass table: {d}\n\tTable Destination ID: {d}\n", .{ self.class, self.dst_id });
        std.debug.print("\tCounts: {any}\n", .{self.counts});
        std.debug.print("\tSymbols: {any}\n", .{self.symbols});

        print_bytes(self.data_raw, .small_hex);
        if (std_options.log_level == .info) self.print_table();
    }
};

test "parse DC luminance huffman table" {
    var payload = [_]u8{
        0x00, // class=0 (DC), dest=0
        0x00,
        0x01,
        0x05,
        0x01,
        0x01,
        0x01,
        0x01,
        0x01,
        0x01,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x01,
        0x02,
        0x03,
        0x04,
        0x05,
        0x06,
        0x07,
        0x08,
        0x09,
        0x0A,
        0x0B,
    };

    var ht: HuffmanTable = try .initFromPayload(0, &payload, std.testing.allocator);
    defer ht.deinit();

    try std.testing.expectEqual(@as(usize, 12), ht.table.count());
}
