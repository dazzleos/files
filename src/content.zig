//! What is in a file, to show it: read (its first `max_read` bytes, for
//! files that are bigger) and told apart by what it holds rather than its
//! name: an image (see decode.zig), a font, text, or anything else, shown
//! as bytes.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const gfx = @import("gfx");
const font = @import("font");
const decode = @import("decode.zig");
const video = @import("video");

/// The most read of a file.
pub const max_read = 8 * 1024 * 1024;

pub const Kind = union(enum) {
    /// Valid UTF-8 with no control characters but tabs and line breaks:
    /// its lines (tabs made spaces).
    text: []const []const u8,
    image: struct { format: decode.Format, image: gfx.Image, full: ?[2]u32 },
    /// A video, decoded in hardware.
    video: *video.Player,
    /// A font (TrueType outlines).
    font: font.Font,
    binary,
    empty,
};

pub const Content = struct {
    arena: std.heap.ArenaAllocator,
    /// What was read.
    data: []const u8 = &.{},
    /// The file is bigger than what was read.
    truncated: bool = false,
    /// Why it could not be read, if it could not.
    err: ?sys.Error = null,
    kind: Kind = .empty,

    /// Reads the file at `path`. It always gives content: with `err` if
    /// the file cannot be read.
    pub fn read(gpa: std.mem.Allocator, path: []const u8) Content {
        var c: Content = .{ .arena = .init(gpa) };
        c.readInto(path) catch |e| {
            c.err = e;
            c.data = &.{};
            c.kind = .empty;
        };
        return c;
    }

    pub fn deinit(c: *Content) void {
        if (c.kind == .video) c.kind.video.destroy();
        c.arena.deinit();
    }

    fn readInto(c: *Content, path: []const u8) sys.Error!void {
        const a = c.arena.allocator();
        const path_z = a.dupeZ(u8, path) catch return error.OutOfMemory;
        // Not waiting for files that would (in /proc, say).
        const fd = try sys.open(path_z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true });
        var keep_fd = false;
        defer if (!keep_fd) sys.close(fd);

        // Videos stream from their open file descriptor, so even files
        // larger than `max_read` can play.
        var stx: linux.Statx = undefined;
        if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .SIZE = true }, &stx)) == .SUCCESS and
            (stx.mode & linux.S.IFMT) == linux.S.IFREG and stx.size >= 8)
        {
            var head: [64]u8 = undefined;
            const rc = linux.pread(fd, &head, head.len, 0);
            if (linux.errno(rc) == .SUCCESS and rc >= 8 and video.looksLikeVideo(head[0..rc])) {
                if (video.Player.open(c.arena.child_allocator, fd, stx.size, true, sys.nowNs())) |player| {
                    keep_fd = true;
                    c.kind = .{ .video = player };
                    return;
                } else |_| {}
            }
        }

        var data: std.ArrayList(u8) = .empty;
        // Until the end (files in /proc and /sys say they are empty).
        while (data.items.len <= max_read) {
            data.ensureUnusedCapacity(a, 64 * 1024) catch return error.OutOfMemory;
            const room = data.unusedCapacitySlice();
            const want = @min(room.len, max_read + 1 - data.items.len);
            const rc = linux.read(fd, room.ptr, want);
            if (linux.errno(rc) == .AGAIN) break;
            const n = try sys.check(rc);
            if (n == 0) break;
            data.items.len += n;
        }
        c.truncated = data.items.len > max_read;
        c.data = data.items[0..@min(data.items.len, max_read)];
        c.kind = classify(a, c.data, c.truncated);
    }
};

fn classify(a: std.mem.Allocator, data: []const u8, truncated: bool) Kind {
    if (data.len == 0) return .empty;
    if (!truncated) if (decode.sniff(data)) |format| {
        if (decode.decode(a, format, data)) |d| {
            return .{ .image = .{ .format = format, .image = .init(d.pixels, d.width, d.height), .full = d.full } };
        } else |_| return .binary;
    };
    if (!truncated and isFont(data)) if (font.Font.init(data)) |f| {
        // It must have outlines to show.
        if (f.glyphIndex('a') != 0 or f.glyphIndex('A') != 0) return .{ .font = f };
    } else |_| {};
    if (lines(a, data, truncated)) |l| return .{ .text = l };
    return .binary;
}

fn isFont(data: []const u8) bool {
    return std.mem.startsWith(u8, data, "\x00\x01\x00\x00") or std.mem.startsWith(u8, data, "true");
}

/// The text's lines (without their breaks, tabs as spaces), or null if
/// it is not text: not UTF-8 (though text `truncated` may end inside a
/// character), or with control characters other than tabs, line breaks
/// and form feeds.
fn lines(a: std.mem.Allocator, data: []const u8, truncated: bool) ?[]const []const u8 {
    var text = data;
    // A character cut short at the end of what was read.
    var cut: usize = 0;
    while (truncated and cut < 3 and cut < text.len and !std.unicode.utf8ValidateSlice(text[0 .. text.len - cut])) cut += 1;
    text = text[0 .. text.len - cut];
    if (!std.unicode.utf8ValidateSlice(text)) return null;
    for (text) |b| if (b < 0x20 and b != '\t' and b != '\n' and b != '\r' and b != 0x0c or b == 0x7f) return null;
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        var line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.indexOfScalar(u8, line, '\t') != null) line = untab(a, line) catch return null;
        out.append(a, line) catch return null;
    }
    // A last break ends the last line rather than starting another.
    if (out.items.len > 1 and out.items[out.items.len - 1].len == 0) out.items.len -= 1;
    return out.items;
}

/// Tabs as spaces, to the next multiple of 4 characters.
fn untab(a: std.mem.Allocator, line: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var column: usize = 0;
    for (line) |b| {
        if (b == '\t') {
            const n = 4 - column % 4;
            try out.appendNTimes(a, ' ', n);
            column += n;
        } else {
            try out.append(a, b);
            // Columns are characters, not bytes.
            if (b & 0xc0 != 0x80) column += 1;
        }
    }
    return out.items;
}

const testing = std.testing;

fn writeFile(path: []const u8, data: []const u8) !void {
    var z: [128]u8 = undefined;
    const fd = try sys.open(try std.fmt.bufPrintZ(&z, "{s}", .{path}), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true });
    defer sys.close(fd);
    _ = linux.fchmod(fd, 0o644);
    _ = linux.write(fd, data.ptr, data.len);
}

test "files are told apart by what they hold" {
    const gpa = testing.allocator;
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/dazzle-content-test-{d}", .{linux.getpid()});
    var z: [64]u8 = undefined;
    defer _ = linux.unlink(std.fmt.bufPrintZ(&z, "{s}", .{path}) catch unreachable);

    try writeFile(path, "first\r\n\tindented\ncafé\n");
    var text = Content.read(gpa, path);
    defer text.deinit();
    const l = text.kind.text;
    try testing.expectEqual(@as(usize, 3), l.len);
    try testing.expectEqualStrings("first", l[0]);
    try testing.expectEqualStrings("    indented", l[1]);
    try testing.expectEqualStrings("café", l[2]);

    try writeFile(path, "\x00\x01\x02binary");
    var bin = Content.read(gpa, path);
    defer bin.deinit();
    try testing.expect(bin.kind == .binary);
    try testing.expectEqual(@as(usize, 9), bin.data.len);

    try writeFile(path, "P6 1 1 255\n\xff\x00\x00");
    var img = Content.read(gpa, path);
    defer img.deinit();
    try testing.expectEqual(@as(u32, 0xffff0000), img.kind.image.image.pixels[0]);

    try writeFile(path, @embedFile("FiraSans-Regular.ttf"));
    var f = Content.read(gpa, path);
    defer f.deinit();
    try testing.expect(f.kind == .font);

    const mp4 = try video.buildTestMp4(
        gpa,
        &.{ 0x67, 0x42, 0xc0, 0x1e, 0xd9, 0x01, 0x41, 0xfb, 0x80 },
        &.{ 0x68, 0xce, 0x3c, 0x80 },
        &.{ 0, 0, 0, 4, 0x65, 0x88, 0x84, 0x21 },
        &.{ 0, 0, 0, 4, 0x41, 0x9a, 0x24, 0x6c },
    );
    defer gpa.free(mp4);
    try writeFile(path, mp4);
    var vid = Content.read(gpa, path);
    defer vid.deinit();
    try testing.expect(vid.kind == .video);
    try testing.expectEqual(@as(u32, 320), vid.kind.video.stream.width);
    try testing.expectEqual(@as(u32, 240), vid.kind.video.stream.height);

    try writeFile(path, "");
    var empty = Content.read(gpa, path);
    defer empty.deinit();
    try testing.expect(empty.kind == .empty);

    var missing = Content.read(gpa, "/nonexistent-dazzle-file");
    defer missing.deinit();
    try testing.expectEqual(@as(?sys.Error, error.NotFound), missing.err);

    // /proc's files say they are empty, but are read to their end.
    var proc = Content.read(gpa, "/proc/self/status");
    defer proc.deinit();
    try testing.expect(proc.kind == .text);
    try testing.expect(proc.kind.text.len > 5);
}

test "text cut short inside a character is still text" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try testing.expect(lines(arena.allocator(), "caf\xc3", true) != null);
    try testing.expect(lines(arena.allocator(), "caf\xc3", false) == null);
    try testing.expect(lines(arena.allocator(), "bad \xff byte", true) == null);
    try testing.expect(lines(arena.allocator(), "bell \x07", false) == null);
}
