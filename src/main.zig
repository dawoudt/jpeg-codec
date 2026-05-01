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

var alloc_buffer: [1024 * 1024 * 20]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
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
            var next_byte = try file_reader_intf.takeByte();
            while (next_byte == FILL) // we eat the byte if its a FILL bytes
                next_byte = try file_reader_intf.takeByte();

            std.log.debug("Marker: {X}:\n", .{MARKER});
            if (0xF & (next_byte >> 4) == 0xE) { // APP MARKER
                switch (0xF & next_byte) {
                    0x0 => { // APP0
                        var buf: [1024]u8 = undefined;
                        const out = try read_payload(file_reader_intf, &buf);
                        std.debug.print("APP{d}:\n", .{0xF & next_byte});
                        var c = std.Io.Reader.fixed(out);

                        const identifier = try c.take(5); // null terminated
                        std.debug.print("\tidentifier: {s}\n", .{identifier});

                        if (std.mem.eql(u8, identifier, &JFIF)) { // JFIF
                            const version_bytes = try c.take(2);
                            const major: u8 = version_bytes[0];
                            const minor: u8 = version_bytes[1];
                            std.debug.print("\tversion: {d}.{d:0>2}\n", .{ major, minor });

                            const density = try c.takeByte();
                            std.debug.print("\tdensity: {x}\n", .{density});

                            const Xdensity = try c.takeInt(u16, .big);
                            std.debug.print("\tXdensity: {d}: (hex: {X})\n", .{ Xdensity, Xdensity });

                            const Ydensity = try c.takeInt(u16, .big);
                            std.debug.print("\tYdensity: {d} (hex: {X})\n", .{ Ydensity, Ydensity });

                            const Xthumbnail = try c.takeByte();
                            std.debug.print("\tXthumbnail: {d}\n", .{Xthumbnail});

                            const Ythumbnail = try c.takeByte();
                            std.debug.print("\tYthumbnail: {d}\n", .{Ythumbnail});

                            // Thumbnail data
                            // Uncompressed 24 bit RGB (8 bits per color channel) raster thumbnail data in the order R0, G0, B0, ... Rn-1, Gn-1, Bn-1;
                            // n = Xthumbnail × Ythumbnail
                            // 3 × n
                            if (Xthumbnail != 0 and Ythumbnail != 0) {
                                // start = end;
                                // end = start + (Xthumbnail * Ythumbnail) * 3;
                                const n: usize = @as(usize, Xthumbnail) * @as(usize, Ythumbnail) * 3;
                                const thumbnail_bytes = try c.take(n);
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
                    defer dht.deinit(alloc);
                    dht.print();
                    // dht.print_table();
                },
                DQT => {
                    dqt_num += 1;
                    var buf: [4096]u8 = undefined;
                    const out = try read_payload(file_reader_intf, &buf);
                    var dqt = try QuantizationTable.initFromPayload(dqt_num, out, alloc);
                    defer dqt.deinit(alloc);
                    dqt.print();
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
                    var c = std.Io.Reader.fixed(out);

                    // for (out) |value| {
                    //     std.debug.print("{X:0>2} ", .{value});
                    // }
                    // std.debug.print("\n", .{});

                    const precision = try c.takeByte();
                    std.debug.print("\tPrecision: {d}\n", .{precision});

                    const height = try c.takeInt(u16, .big);
                    std.debug.print("\tHeight: {d}\n", .{height});

                    const width = try c.takeInt(u16, .big);
                    std.debug.print("\tWidth: {d}\n", .{width});

                    const num_of_components = try c.takeByte();
                    std.debug.print("\tNumber of Components: {d}\n", .{num_of_components});
                    var component_counter: usize = 0;
                    while (component_counter < num_of_components) : (component_counter += 1) {
                        const component_id = try c.takeByte();
                        const component: Component = @enumFromInt(component_id);

                        const sample = try c.takeByte();
                        const vertical_sample = sample & 0xF;
                        const horizontal_sample = (sample >> 4) & 0xF;
                        const dct_tbl_num = try c.takeByte();
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
    std.debug.print("\tRaw: {s}: ", .{@tagName(fmt)});
    for (str) |b| {
        switch (fmt) {
            .small_hex, .big_hex => std.debug.print("{" ++ [_]u8{@intFromEnum(fmt)} ++ ":0>2} ", .{b}),
            else => std.debug.print("{" ++ [_]u8{@intFromEnum(fmt)} ++ "} ", .{b}),
        }
    }
    std.debug.print("\n\n", .{});
}

const QuantizationTable = struct {
    tbl_num: usize,
    precision: usize,
    dst_id: u4,
    data_len: u16,
    data_raw: []u8,
    quantization_values: []u8,

    pub fn initFromPayload(num: usize, data: []u8, allocator: std.mem.Allocator) !QuantizationTable {
        const precision_nibble: u4 = @truncate(data[0] >> 4);
        const precision: usize = if (precision_nibble == 0) 64 else 128;

        return .{
            .tbl_num = num,
            .precision = precision,
            .dst_id = @truncate(data[0] & 0x0F),
            .data_len = @intCast(data.len),
            .data_raw = try allocator.dupe(u8, data),
            .quantization_values = try allocator.dupe(u8, data[1 .. precision + 1]),
            // TODO: Define quantization values (can be multiple)
        };
    }

    pub fn deinit(self: *QuantizationTable, allocator: std.mem.Allocator) void {
        allocator.free(self.quantization_values);
        allocator.free(self.data_raw);
    }

    pub fn print(self: QuantizationTable) void {
        std.debug.print("\nQuantization Table {d}: \n", .{self.tbl_num});
        std.debug.print("\tPrecision: {d}\n", .{self.precision});
        std.debug.print("\tTable Destination ID: {d}\n", .{self.dst_id});
        std.debug.print("\tQuantization Values: {any}\n", .{self.quantization_values});
        print_bytes(self.data_raw, .small_hex);
    }
};

const HuffmanTable = struct {
    tbl_num: usize,
    data_len: u16,
    data_raw: []u8,

    class: u4,
    dst_id: u4,
    counts: []u8,
    num_of_symbols: usize,
    symbols: []u8,
    table: std.AutoHashMap(u32, u8),

    pub fn deinit(self: *HuffmanTable, allocator: std.mem.Allocator) void {
        self.table.deinit();
        allocator.free(self.counts);
        allocator.free(self.symbols);
        allocator.free(self.data_raw);
    }

    pub fn init(num: usize, reader: *std.Io.Reader, buf: []u8, allocator: std.mem.Allocator) !HuffmanTable {
        const out = try read_payload(reader, buf);
        return initFromPayload(num, out[0..], allocator);
    }

    pub fn initFromPayload(num: usize, data: []u8, allocator: std.mem.Allocator) !HuffmanTable {
        var num_of_symbols: usize = 0;
        for (data[1..17]) |s| num_of_symbols += s;
        var ht: HuffmanTable = .{
            .tbl_num = num,
            .data_len = @intCast(data.len),
            .data_raw = try allocator.dupe(u8, data),
            .class = @truncate(data[0] >> 4),
            .dst_id = @truncate(data[0] & 0x0F),
            .counts = try allocator.dupe(u8, data[1..17]),
            .symbols = try allocator.dupe(u8, data[17 .. 17 + num_of_symbols]),
            .num_of_symbols = num_of_symbols,
            .table = std.AutoHashMap(u32, u8).init(allocator),
        };
        try ht.build_table();
        return ht;
    }

    fn build_table(self: *HuffmanTable) !void {
        // TODO: Fix so that we CAN parse mutiple tables out of the payload.
        // TODO: Maybe Use ArrayList(.{.code, .value}) instead so its ordered.
        // Although then it would be O(N) instead of O(1)
        var code: u32 = 0;
        var symbol_idx: usize = 0; // this is global as we need to remember what we've proccesed.
        for (self.counts, 1..) |length, bit_len| { // each item from the counts array is the length for the symbols sub set
            for (0..length) |_| { // iterate over the subset from 0 to length
                const symbol = self.symbols[symbol_idx]; // grab the symbol at the symbol_idx
                const key: u32 = @intCast(bit_len << 16 | code);
                try self.table.put(key, symbol); // add it to the table
                code += 1; // increment the code
                symbol_idx += 1; // increment the symbol_idx
                std.log.debug("code += 1: {d}\n", .{code});
            }
            code <<= 1; // when we move to next count, we shift left (or append 0 to the right);
            std.log.debug("code = code << 1: {d}\n", .{code});
        }
    }

    fn print_table(self: HuffmanTable) void {
        var it = self.table.iterator();
        std.debug.print("  ------ Huffman Table Data ------\n", .{});
        std.debug.print("\t  {s: <7}| {s: <10}\n", .{ "code", "symbol" });
        std.debug.print("\t  {s:-<7}+{s:-<10}\n", .{ "", "" });

        while (it.next()) |entry| {
            std.debug.print("\t  {d: <7}| {d: <10}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    pub fn print(self: HuffmanTable) void {
        std.debug.print("Huffman Table {d}: \n", .{self.tbl_num});
        std.debug.print("\tClass table: {d}\n", .{self.class});
        std.debug.print("\tTable Destination ID: {d}\n", .{self.dst_id});
        std.debug.print("\tCounts: {any}\n", .{self.counts});
        std.debug.print("\tNumber of Symbols: {any}\n", .{self.num_of_symbols});
        std.debug.print("\tSymbols: {any}\n", .{self.symbols});

        print_bytes(self.data_raw, .small_hex);
        if (std_options.log_level == .debug) self.print_table();
    }
};

// TODO: Write test for multiple tables extracted from DHT payload.
test "parse DC luminance huffman table - code verification" {
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
    defer ht.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 12), ht.table.count());

    // 00 (len=2, code=0) → 0x00
    try std.testing.expectEqual(@as(u8, 0x00), ht.table.get(2 << 16 | 0).?);
    // 010 (len=3, code=2) → 0x01
    try std.testing.expectEqual(@as(u8, 0x01), ht.table.get(3 << 16 | 2).?);
    // 011 (len=3, code=3) → 0x02
    try std.testing.expectEqual(@as(u8, 0x02), ht.table.get(3 << 16 | 3).?);
    // 100 (len=3, code=4) → 0x03
    try std.testing.expectEqual(@as(u8, 0x03), ht.table.get(3 << 16 | 4).?);
    // 101 (len=3, code=5) → 0x04
    try std.testing.expectEqual(@as(u8, 0x04), ht.table.get(3 << 16 | 5).?);
    // 110 (len=3, code=6) → 0x05
    try std.testing.expectEqual(@as(u8, 0x05), ht.table.get(3 << 16 | 6).?);
    // 1110 (len=4, code=14) → 0x06
    try std.testing.expectEqual(@as(u8, 0x06), ht.table.get(4 << 16 | 14).?);
    // 11110 (len=5, code=30) → 0x07
    try std.testing.expectEqual(@as(u8, 0x07), ht.table.get(5 << 16 | 30).?);
    // 111110 (len=6, code=62) → 0x08
    try std.testing.expectEqual(@as(u8, 0x08), ht.table.get(6 << 16 | 62).?);
    // 1111110 (len=7, code=126) → 0x09
    try std.testing.expectEqual(@as(u8, 0x09), ht.table.get(7 << 16 | 126).?);
    // 11111110 (len=8, code=254) → 0x0A
    try std.testing.expectEqual(@as(u8, 0x0A), ht.table.get(8 << 16 | 254).?);
    // 111111110 (len=9, code=510) → 0x0B
    try std.testing.expectEqual(@as(u8, 0x0B), ht.table.get(9 << 16 | 510).?);
}
