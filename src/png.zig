//! Minimal PNG encoder: 24-bit RGB, no filtering, stored deflate blocks.
//!
//! Only `--dump` uses it, so compressed size does not matter.

const std = @import("std");

fn adler32(bytes: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (bytes) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

fn putU32(list: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .big);
    try list.appendSlice(gpa, &buf);
}

fn putChunk(list: *std.ArrayList(u8), gpa: std.mem.Allocator, kind: *const [4]u8, data: []const u8) !void {
    try putU32(list, gpa, @intCast(data.len));
    const start = list.items.len;
    try list.appendSlice(gpa, kind);
    try list.appendSlice(gpa, data);
    const crc = std.hash.Crc32.hash(list.items[start..]);
    try putU32(list, gpa, crc);
}

/// `rgb` is tightly packed RGB, `w * h * 3` bytes.
pub fn encode(gpa: std.mem.Allocator, rgb: []const u8, w: u32, h: u32) ![]u8 {
    std.debug.assert(rgb.len == w * h * 3);

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    try raw.ensureTotalCapacity(gpa, @as(usize, h) * (@as(usize, w) * 3 + 1));
    var y: usize = 0;
    while (y < h) : (y += 1) {
        try raw.append(gpa, 0); // filter: none
        const row = rgb[y * w * 3 ..][0 .. w * 3];
        try raw.appendSlice(gpa, row);
    }

    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(gpa);
    try z.appendSlice(gpa, &.{ 0x78, 0x01 });
    var off: usize = 0;
    while (true) {
        const remaining = raw.items.len - off;
        const len: u16 = @intCast(@min(remaining, 65535));
        const last: u8 = if (remaining <= 65535) 1 else 0;
        try z.append(gpa, last);
        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u16, hdr[0..2], len, .little);
        std.mem.writeInt(u16, hdr[2..4], ~len, .little);
        try z.appendSlice(gpa, &hdr);
        try z.appendSlice(gpa, raw.items[off .. off + len]);
        off += len;
        if (off >= raw.items.len) break;
    }
    try putU32(&z, gpa, adler32(raw.items));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A });

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // colour type: truecolour
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try putChunk(&out, gpa, "IHDR", &ihdr);
    try putChunk(&out, gpa, "IDAT", z.items);
    try putChunk(&out, gpa, "IEND", "");

    return out.toOwnedSlice(gpa);
}
