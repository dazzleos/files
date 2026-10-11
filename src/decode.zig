//! Images in files, decoded to pixels the toolkit can show (0xAARRGGBB,
//! straight alpha): PNG (every colour type and depth, not interlaced),
//! BMP (uncompressed: 8-bit with a palette, 24- and 32-bit) and binary
//! PPM and PGM. Images bigger than the GPU takes are made smaller.

const std = @import("std");
const gfx = @import("gfx");

pub const Format = enum {
    png,
    bmp,
    pnm,

    pub fn label(f: Format) []const u8 {
        return switch (f) {
            .png => "PNG image",
            .bmp => "BMP image",
            .pnm => "PPM image",
        };
    }
};

pub const Error = gfx.png.Error;

pub const Decoded = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    /// Its size in the file, if it was made smaller.
    full: ?[2]u32 = null,
};

/// The most pixels decoded (before being made smaller).
pub const max_pixels = gfx.png.max_pixels;
/// The biggest image shown, across or down (the GPU's limit).
pub const max_size = 2048;

/// The format the data is in, by how it starts.
pub fn sniff(data: []const u8) ?Format {
    if (std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n")) return .png;
    if (data.len > 26 and std.mem.startsWith(u8, data, "BM")) return .bmp;
    if (data.len > 3 and data[0] == 'P' and (data[1] == '5' or data[1] == '6') and std.ascii.isWhitespace(data[2])) return .pnm;
    return null;
}

pub fn decode(gpa: std.mem.Allocator, format: Format, data: []const u8) Error!Decoded {
    const img = switch (format) {
        .png => blk: {
            const p = try gfx.png.decode(gpa, data);
            break :blk Decoded{ .pixels = p.pixels, .width = p.width, .height = p.height };
        },
        .bmp => try bmp(gpa, data),
        .pnm => try pnm(gpa, data),
    };
    return shrink(gpa, img);
}

fn le16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

fn le32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

fn argb(r: u8, g: u8, b: u8, a: u8) u32 {
    return @as(u32, a) << 24 | @as(u32, r) << 16 | @as(u32, g) << 8 | b;
}

fn alloc(gpa: std.mem.Allocator, width: u32, height: u32) Error![]u32 {
    if (width == 0 or height == 0) return error.Malformed;
    if (@as(u64, width) * height > max_pixels) return error.TooBig;
    return gpa.alloc(u32, @as(usize, width) * height);
}

const paeth = gfx.png.paeth;

// --- BMP ----------------------------------------------------------------------

fn bmp(gpa: std.mem.Allocator, data: []const u8) Error!Decoded {
    if (data.len < 54) return error.Malformed;
    const offset = le32(data, 10);
    const header = le32(data, 14);
    if (header < 40) return error.Unsupported;
    const w: i32 = @bitCast(le32(data, 18));
    const h: i32 = @bitCast(le32(data, 22));
    const bits = le16(data, 28);
    const compression = le32(data, 30);
    // Uncompressed, or (for 32 bits) with the usual masks.
    if (!(compression == 0 or (compression == 3 and bits == 32))) return error.Unsupported;
    if (bits != 8 and bits != 24 and bits != 32) return error.Unsupported;
    if (w <= 0 or h == 0) return error.Malformed;
    const width: u32 = @intCast(w);
    const height: u32 = @intCast(@abs(h));
    const top_down = h < 0;
    const stride = (@as(usize, width) * bits / 8 + 3) / 4 * 4;
    if (offset > data.len or stride * height > data.len - offset) return error.Malformed;
    var palette: [256]u32 = @splat(0xff000000);
    if (bits == 8) {
        const colors = @min(if (le32(data, 46) == 0) 256 else le32(data, 46), 256);
        const at = 14 + header;
        if (at + colors * 4 > data.len) return error.Malformed;
        for (0..colors) |i| palette[i] = argb(data[at + i * 4 + 2], data[at + i * 4 + 1], data[at + i * 4], 255);
    }
    // 32 bits with masks: where each channel is (alpha only with a
    // header that has its mask); otherwise blue, green, red, unused.
    var masks = [4]u32{ 0x00ff0000, 0x0000ff00, 0x000000ff, 0 };
    if (bits == 32 and compression == 3) {
        const channels: usize = if (header >= 56) 4 else 3;
        if (14 + 40 + channels * 4 > data.len) return error.Malformed;
        for (masks[0..channels], 0..) |*m, i| m.* = le32(data, 54 + i * 4);
    }
    const pixels = try alloc(gpa, width, height);
    for (0..height) |y| {
        const src = data[offset + (if (top_down) y else height - 1 - y) * stride ..];
        for (0..width) |x| pixels[y * width + x] = switch (bits) {
            8 => palette[src[x]],
            24 => argb(src[x * 3 + 2], src[x * 3 + 1], src[x * 3], 255),
            else => blk: {
                const v = le32(src, x * 4);
                break :blk argb(channel(v, masks[0]), channel(v, masks[1]), channel(v, masks[2]), if (masks[3] == 0) 255 else channel(v, masks[3]));
            },
        };
    }
    return .{ .pixels = pixels, .width = width, .height = height };
}

/// The channel under `mask` in `v`, as 8 bits.
fn channel(v: u32, mask: u32) u8 {
    if (mask == 0) return 0;
    const shift: u5 = @intCast(@ctz(mask));
    const max = mask >> shift;
    return @intCast(@as(u64, (v & mask) >> shift) * 255 / max);
}

// --- PPM and PGM --------------------------------------------------------------

fn pnm(gpa: std.mem.Allocator, data: []const u8) Error!Decoded {
    const rgb = data[1] == '6';
    var at: usize = 2;
    var fields: [3]u32 = undefined;
    for (&fields) |*f| {
        // Whitespace and comments, then a number.
        while (at < data.len) {
            if (data[at] == '#') {
                while (at < data.len and data[at] != '\n') at += 1;
            } else if (std.ascii.isWhitespace(data[at])) at += 1 else break;
        }
        const start = at;
        while (at < data.len and std.ascii.isDigit(data[at])) at += 1;
        f.* = std.fmt.parseInt(u32, data[start..at], 10) catch return error.Malformed;
    }
    at += 1; // one whitespace byte before the pixels
    const width, const height, const max = fields;
    if (max == 0 or max > 65535) return error.Malformed;
    const wide = max > 255;
    const channels: usize = if (rgb) 3 else 1;
    const per = channels * @as(usize, if (wide) 2 else 1);
    if (at > data.len or @as(u64, width) * height * per > data.len - at) return error.Malformed;
    const pixels = try alloc(gpa, width, height);
    const px = data[at..];
    for (pixels, 0..) |*p, i| {
        var v: [3]u8 = undefined;
        for (0..channels) |k| {
            const raw: u32 = if (wide) std.mem.readInt(u16, px[(i * channels + k) * 2 ..][0..2], .big) else px[i * channels + k];
            v[k] = @intCast(raw * 255 / max);
        }
        p.* = if (rgb) argb(v[0], v[1], v[2], 255) else argb(v[0], v[0], v[0], 255);
    }
    return .{ .pixels = pixels, .width = width, .height = height };
}

// --- Making smaller -----------------------------------------------------------

/// The image at most `max_size` across and down: each pixel the average of
/// a square of the original's (weighted by how opaque they are).
fn shrink(gpa: std.mem.Allocator, img: Decoded) Error!Decoded {
    if (img.width <= max_size and img.height <= max_size) return img;
    defer gpa.free(img.pixels);
    const f = (@max(img.width, img.height) + max_size - 1) / max_size;
    const w = @max(img.width / f, 1);
    const h = @max(img.height / f, 1);
    const out = try gpa.alloc(u32, @as(usize, w) * h);
    for (0..h) |y| for (0..w) |x| {
        var sum: [4]u64 = @splat(0);
        for (0..f) |dy| for (0..f) |dx| {
            const p = img.pixels[(y * f + dy) * img.width + x * f + dx];
            const a: u64 = p >> 24;
            sum[0] += a;
            sum[1] += a * ((p >> 16) & 0xff);
            sum[2] += a * ((p >> 8) & 0xff);
            sum[3] += a * (p & 0xff);
        };
        const n = @as(u64, f) * f;
        const a = sum[0];
        out[y * w + x] = if (a == 0) 0 else argb(@intCast(sum[1] / a), @intCast(sum[2] / a), @intCast(sum[3] / a), @intCast(a / n));
    };
    return .{ .pixels = out, .width = w, .height = h, .full = .{ img.width, img.height } };
}

// --- Tests ----------------------------------------------------------------------

const testing = std.testing;

/// A PNG of `raw` (filtered rows), with the zlib stream stored, not
/// compressed.
fn makePng(gpa: std.mem.Allocator, w: u32, h: u32, depth: u8, color: u8, raw: []const u8, extra: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = depth;
    ihdr[9] = color;
    @memset(ihdr[10..], 0);
    try chunk(gpa, &out, "IHDR", &ihdr);
    try out.appendSlice(gpa, extra);
    // zlib: header, one stored block, Adler-32.
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(gpa);
    try z.appendSlice(gpa, &.{ 0x78, 0x01, 0x01 });
    var lens: [4]u8 = undefined;
    std.mem.writeInt(u16, lens[0..2], @intCast(raw.len), .little);
    std.mem.writeInt(u16, lens[2..4], ~@as(u16, @intCast(raw.len)), .little);
    try z.appendSlice(gpa, &lens);
    try z.appendSlice(gpa, raw);
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(raw), .big);
    try z.appendSlice(gpa, &adler);
    try chunk(gpa, &out, "IDAT", z.items);
    try chunk(gpa, &out, "IEND", "");
    return out.toOwnedSlice(gpa);
}

fn chunk(gpa: std.mem.Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, body: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(body.len), .big);
    try out.appendSlice(gpa, &len);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, body);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(body);
    std.mem.writeInt(u32, &len, crc.final(), .big);
    try out.appendSlice(gpa, &len);
}

test "PNGs: RGBA with every filter, palettes, and grey at low depths" {
    const gpa = testing.allocator;
    // 2x5 RGBA, a row per filter (none, sub, up, average, Paeth), each
    // row decoding to red then translucent green.
    const want = [2]u32{ 0xffff0000, 0x8000ff00 };
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    const plain = [8]u8{ 255, 0, 0, 255, 0, 255, 0, 128 };
    for (0..5) |f| {
        try raw.append(gpa, @intCast(f));
        var row: [8]u8 = undefined;
        for (&row, 0..) |*b, i| {
            const a: u8 = if (i >= 4) plain[i - 4] else 0;
            const up: u8 = if (f > 0) plain[i] else 0; // the row above is the same
            const c: u8 = if (i >= 4 and f > 0) plain[i - 4] else 0;
            b.* = plain[i] -% switch (f) {
                0 => 0,
                1 => a,
                2 => up,
                3 => @as(u8, @intCast((@as(u16, a) + up) / 2)),
                else => paeth(a, up, c),
            };
        }
        try raw.appendSlice(gpa, &row);
    }
    const file = try makePng(gpa, 2, 5, 8, 6, raw.items, "");
    defer gpa.free(file);
    try testing.expectEqual(Format.png, sniff(file).?);
    const img = try decode(gpa, .png, file);
    defer gpa.free(img.pixels);
    try testing.expectEqual(@as(u32, 2), img.width);
    for (0..5) |y| try testing.expectEqualSlices(u32, &want, img.pixels[y * 2 ..][0..2]);

    // A palette (2 bits a pixel), its second colour see-through.
    var extra: std.ArrayList(u8) = .empty;
    defer extra.deinit(gpa);
    try chunk(gpa, &extra, "PLTE", &.{ 0, 0, 0, 255, 255, 255, 0, 0, 255 });
    try chunk(gpa, &extra, "tRNS", &.{ 255, 0 });
    const pal = try makePng(gpa, 3, 1, 2, 3, &.{ 0, 0b00_01_10_00 }, extra.items);
    defer gpa.free(pal);
    const p = try decode(gpa, .png, pal);
    defer gpa.free(p.pixels);
    try testing.expectEqualSlices(u32, &.{ 0xff000000, 0x00ffffff, 0xff0000ff }, p.pixels);

    // Grey, 1 bit: black and white.
    const grey = try makePng(gpa, 2, 1, 1, 0, &.{ 0, 0b0100_0000 }, "");
    defer gpa.free(grey);
    const g = try decode(gpa, .png, grey);
    defer gpa.free(g.pixels);
    try testing.expectEqualSlices(u32, &.{ 0xff000000, 0xffffffff }, g.pixels);

    // Interlaced, or cut short: not shown.
    var bad = try gpa.dupe(u8, grey);
    defer gpa.free(bad);
    bad[8 + 8 + 12] = 1;
    try testing.expectError(error.Unsupported, decode(gpa, .png, bad));
    try testing.expectError(error.Malformed, decode(gpa, .png, file[0 .. file.len - 30]));
}

test "BMPs and PPMs" {
    const gpa = testing.allocator;
    // 2x2, 24-bit, bottom row first: blue, green / red, white.
    var b: [54 + 16]u8 = @splat(0);
    @memcpy(b[0..2], "BM");
    std.mem.writeInt(u32, b[10..14], 54, .little);
    std.mem.writeInt(u32, b[14..18], 40, .little);
    std.mem.writeInt(i32, b[18..22], 2, .little);
    std.mem.writeInt(i32, b[22..26], 2, .little);
    std.mem.writeInt(u16, b[28..30], 24, .little);
    @memcpy(b[54..], &[16]u8{ 0, 0, 255, 255, 255, 255, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0 });
    try testing.expectEqual(Format.bmp, sniff(&b).?);
    const img = try decode(gpa, .bmp, &b);
    defer gpa.free(img.pixels);
    try testing.expectEqualSlices(u32, &.{ 0xff0000ff, 0xff00ff00, 0xffff0000, 0xffffffff }, img.pixels);

    // 32-bit with masks, alpha included (a V4 header): one see-through
    // red pixel.
    var v4: [14 + 108 + 4]u8 = @splat(0);
    @memcpy(v4[0..2], "BM");
    std.mem.writeInt(u32, v4[10..14], 14 + 108, .little);
    std.mem.writeInt(u32, v4[14..18], 108, .little);
    std.mem.writeInt(i32, v4[18..22], 1, .little);
    std.mem.writeInt(i32, v4[22..26], 1, .little);
    std.mem.writeInt(u16, v4[28..30], 32, .little);
    std.mem.writeInt(u32, v4[30..34], 3, .little);
    for ([_]u32{ 0x00ff0000, 0x0000ff00, 0x000000ff, 0xff000000 }, 0..) |m, i| std.mem.writeInt(u32, v4[54 + i * 4 ..][0..4], m, .little);
    std.mem.writeInt(u32, v4[122..126], 0x80ff0000, .little);
    const v = try decode(gpa, .bmp, &v4);
    defer gpa.free(v.pixels);
    try testing.expectEqual(@as(u32, 0x80ff0000), v.pixels[0]);

    const ppm = "P6\n# a comment\n2 1\n255\n\xff\x00\x00\x00\x00\xff";
    try testing.expectEqual(Format.pnm, sniff(ppm).?);
    const p = try decode(gpa, .pnm, ppm);
    defer gpa.free(p.pixels);
    try testing.expectEqualSlices(u32, &.{ 0xffff0000, 0xff0000ff }, p.pixels);
    const pgm = try decode(gpa, .pnm, "P5 2 1 255\n\x00\x80");
    defer gpa.free(pgm.pixels);
    try testing.expectEqualSlices(u32, &.{ 0xff000000, 0xff808080 }, pgm.pixels);
    try testing.expectError(error.Malformed, decode(gpa, .pnm, "P6 2 1 255\n\x00"));
    try testing.expect(sniff("hello") == null);
}

test "big images are made smaller to show" {
    const gpa = testing.allocator;
    const w = max_size * 2 + 2;
    const pixels = try gpa.alloc(u32, w * 4);
    for (pixels, 0..) |*p, i| p.* = if (i % 2 == 0) 0xffffffff else 0xff000000;
    const img = try shrink(gpa, .{ .pixels = pixels, .width = w, .height = 4 });
    defer gpa.free(img.pixels);
    try testing.expectEqual(@as(u32, (w + 2) / 3), img.width);
    try testing.expectEqual(@as(u32, 1), img.height);
    try testing.expectEqual([2]u32{ w, 4 }, img.full.?);
    // Black and white averaged: grey.
    const c = img.pixels[0] & 0xff;
    try testing.expect(c > 0x60 and c < 0xb0);
}
