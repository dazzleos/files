//! What is in a file, shown in the Files window in place of the grid: text
//! a line a row, an image as big as it fits, a font as samples of its
//! letters, and anything else as bytes (in hexadecimal, and as text where
//! they are printable), sixteen a row (or eight or four, in a narrow
//! window). Rows are made only for those that show, so a big file is quick
//! to show.

const std = @import("std");
const sys = @import("sys");
const kete = @import("kete");
const players = @import("players.zig");
const kete_vc4 = @import("kete_vc4");
const gfx = kete.gfx;
const font = kete.font;
const content = @import("content.zig");
const decode = @import("decode.zig");
const video = @import("video");
const audio = @import("audio");
const fs = @import("fs.zig");

const Content = content.Content;

/// What is in `c`, at scale `s`, `width` wide.
pub fn view(cx: *kete.BuildContext, c: *const Content, width: f32) kete.Widget {
    if (c.err) |err| return message(cx, switch (err) {
        error.AccessDenied => "You are not allowed to read this file",
        error.NotFound => "This file is not there any more",
        else => "This file cannot be read",
    });
    return switch (c.kind) {
        .empty => message(cx, "This file is empty"),
        .text => |lines| textView(cx, lines),
        .image => |*img| cx.make(kete.Padding{ .padding = .all(16), .child = cx.make(kete.Align{ .child = cx.make(kete.Image{ .source = .{ .image = &img.image } }) }) }),
        .video => |player| cx.make(players.VideoPlayer{ .player = player }),
        .audio => |player| cx.make(players.AudioPlayer{ .player = player }),
        .font => |*f| fontView(cx, f),
        .binary => hexView(cx, c.data, width),
    };
}

/// What the file holds, in a line: "Text, 120 lines", "PNG image, 640 ×
/// 480", ...
pub fn describe(cx: *kete.BuildContext, c: *const Content) []const u8 {
    if (c.err != null) return "";
    const first = if (c.truncated) cx.fmt(" (the first {d} MB)", .{content.max_read / (1024 * 1024)}) else "";
    return switch (c.kind) {
        .empty => "Empty",
        .text => |lines| cx.fmt("Text, {d} {s}{s}", .{ lines.len, if (lines.len == 1) "line" else "lines", first }),
        .image => |img| if (img.full) |full|
            cx.fmt("{s}, {d} × {d} (shown at {d} × {d})", .{ img.format.label(), full[0], full[1], img.image.width, img.image.height })
        else
            cx.fmt("{s}, {d} × {d}", .{ img.format.label(), img.image.width, img.image.height }),
        .video => |player| blk: {
            var dur_buf: [32]u8 = undefined;
            const dur = video.formatDuration(&dur_buf, player.stream.duration_us);
            break :blk cx.fmt("{s} video, {d} × {d}  ·  {s}", .{
                player.stream.codec.name(),
                player.stream.width,
                player.stream.height,
                dur,
            });
        },
        .audio => |player| blk: {
            var fmt_buf: [64]u8 = undefined;
            var dur_buf: [32]u8 = undefined;
            const fmt = player.header.describe(&fmt_buf);
            const dur = video.formatDuration(&dur_buf, player.durationMs() * 1000);
            break :blk cx.fmt("{s}  ·  {s}", .{ fmt, dur });
        },
        .font => "Font",
        .binary => cx.fmt("Bytes, in hexadecimal and as text{s}", .{first}),
    };
}

fn message(cx: *kete.BuildContext, text: []const u8) kete.Widget {
    return cx.make(kete.Align{ .child = cx.make(kete.Padding{ .padding = .all(24), .child = cx.make(kete.Text{
        .text = text,
        .style = .{ .size = 20, .color = cx.theme().on_surface_variant },
        .text_align = .center,
    }) }) });
}

// --- Text ---------------------------------------------------------------------

/// Lines, for the list to make rows of (made in the frame's arena).
const Lines = struct {
    lines: []const []const u8,

    fn row(l: *const Lines, cx: *kete.BuildContext, i: usize) kete.Widget {
        // Long lines end in "…" (they are not wrapped: rows are all one
        // height).
        return cx.make(kete.Text{ .text = l.lines[i], .style = .{ .size = 16 }, .wrap = false, .ellipsis = true });
    }
};

fn textView(cx: *kete.BuildContext, lines: []const []const u8) kete.Widget {
    const l = cx.arena.create(Lines) catch return cx.make(kete.SizedBox.empty);
    l.* = .{ .lines = lines };
    return cx.make(kete.ScrollView{ .child = cx.make(kete.Padding{ .padding = .all(16), .child = cx.make(kete.Grid.list(lines.len, 22, .of(l, Lines.row))) }) });
}

// --- Fonts --------------------------------------------------------------------

const samples = [_][]const u8{
    "The quick brown fox jumps over the lazy dog",
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    "abcdefghijklmnopqrstuvwxyz",
    "0123456789 !?&@#%()[]{}",
};

const emoji_samples = [_][]const u8{
    "😀 😃 😄 😁 😆 😅 😂 🤣 😊 😇 🙂 🙃 😉",
    "❤️ 🧡 💛 💚 💙 💜 🚀 🌍 ⭐ 🎉 🔥 💡 🎵",
    "👍 👍🏻 👍🏼 👍🏽 👍🏾 👍🏿 🇳🇿 🇬🇧 🇺🇸 🇯🇵",
};

fn fontView(cx: *kete.BuildContext, f: *const font.Font) kete.Widget {
    const a = cx.arena;
    const lines: []const []const u8 = if (f.glyphIndex('A') == 0 and f.glyphIndex(0x1f600) != 0) &emoji_samples else &samples;
    var rows: std.ArrayList(kete.Widget) = .empty;
    for (lines) |sample| rows.append(a, cx.make(kete.Text{ .text = sample, .style = .{ .size = 28, .font = f } })) catch {};
    // The first sample at sizes from small to big.
    for ([_]f32{ 12, 18, 24, 36, 48, 72 }) |size| {
        rows.append(a, cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 2, .children = &.{
            cx.make(kete.Text{ .text = cx.fmt("{d} pixels", .{size}), .style = .{ .size = 14, .color = cx.theme().on_surface_variant } }),
            cx.make(kete.Text{ .text = lines[0], .style = .{ .size = size, .font = f }, .wrap = false, .ellipsis = true }),
        } })) catch {};
    }
    return cx.make(kete.ScrollView{ .child = cx.make(kete.Padding{ .padding = .all(24), .child = cx.make(kete.Column{
        .cross_axis_alignment = .stretch,
        .fill = false,
        .spacing = 16,
        .children = rows.items,
    }) }) });
}

// --- Bytes ----------------------------------------------------------------------

/// Bytes, for the list to make rows of (made in the frame's arena).
const Bytes = struct {
    data: []const u8,
    size: f32,
    pitch: Pitch,

    fn row(b: *const Bytes, cx: *kete.BuildContext, i: usize) kete.Widget {
        const n = b.pitch.per_row;
        const start = i * n;
        return cx.make(HexRow{ .offset = start, .bytes = b.data[start..@min(start + n, b.data.len)], .size = b.size, .pitch = b.pitch });
    }
};

fn hexView(cx: *kete.BuildContext, data: []const u8, width: f32) kete.Widget {
    const b = cx.arena.create(Bytes) catch return cx.make(kete.SizedBox.empty);
    const size = 15;
    const pad = 16;
    // As many bytes a row as fit (beside the scroll bar).
    var pitch: Pitch = .of(cx.ui.font, size);
    for ([_]usize{ 16, 8, 4 }) |n| {
        pitch.per_row = n;
        if (pitch.width() + 2 * pad + 12 <= width) break;
    }
    b.* = .{ .data = data, .size = size, .pitch = pitch };
    return cx.make(kete.ScrollView{ .child = cx.make(kete.Padding{ .padding = .all(pad), .child = cx.make(kete.Grid.list((data.len + pitch.per_row - 1) / pitch.per_row, 22, .of(b, Bytes.row))) }) });
}

/// How far apart characters are, so columns line up (Dazzle's font is not
/// monospaced): each in a cell as wide as the widest it can be.
pub const Pitch = struct {
    /// Hexadecimal digits.
    hex: f32,
    /// Printable ASCII.
    text: f32,
    /// Bytes a row.
    per_row: usize = 16,

    pub fn of(f: ?*const font.Font, size: f32) Pitch {
        const fnt = f orelse return .{ .hex = size * 0.6, .text = size * 0.8 };
        const style: font.Style = .{ .font = fnt, .size = size };
        var p: Pitch = .{ .hex = 0, .text = 0 };
        for ("0123456789abcdef") |c| p.hex = @max(p.hex, font.measure(style, &.{c}));
        var c: u8 = 0x20;
        while (c < 0x7f) : (c += 1) p.text = @max(p.text, font.measure(style, &.{c}));
        return .{ .hex = @ceil(p.hex), .text = @ceil(p.text) };
    }

    /// Where a byte's two digits start (a gap after each eight).
    fn byte(p: Pitch, j: usize) f32 {
        const half: f32 = @floatFromInt(j / 8);
        return p.hex * 10 + @as(f32, @floatFromInt(j)) * p.hex * 2.75 + half * p.hex;
    }

    /// Where the text column starts.
    fn text_start(p: Pitch) f32 {
        return p.byte(p.per_row) + p.hex;
    }

    fn width(p: Pitch) f32 {
        return p.text_start() + @as(f32, @floatFromInt(p.per_row)) * p.text;
    }
};

/// A row of bytes: where it starts in the file (eight hexadecimal
/// digits), its bytes in hexadecimal (a gap after the eighth), and the
/// bytes as text (dots for those that are not printable ASCII).
pub const HexRow = struct {
    offset: usize,
    bytes: []const u8,
    size: f32,
    pitch: Pitch,

    pub fn layout(self: *const HexRow, _: *kete.WidgetNode, c: kete.Constraints) kete.Size {
        return c.constrain(.{ .w = self.pitch.width(), .h = self.size * 1.4 });
    }

    pub fn paint(self: *const HexRow, n: *kete.WidgetNode, p: *kete.Painter) void {
        const f = n.ui.font orelse return;
        const t = n.theme();
        const style: font.Style = .{ .font = f, .size = self.size };
        const baseline = @round((n.size.h + style.ascent() * 0.75) / 2);
        const pitch = self.pitch;
        var digits: [8]u8 = undefined;
        _ = std.fmt.bufPrint(&digits, "{x:0>8}", .{self.offset}) catch return;
        for (digits, 0..) |c, i| self.char(p, style, c, @as(f32, @floatFromInt(i)) * pitch.hex, pitch.hex, baseline, t.on_surface_variant);
        for (self.bytes, 0..) |b, j| {
            const x = pitch.byte(j);
            self.char(p, style, std.fmt.digitToChar(b >> 4, .lower), x, pitch.hex, baseline, t.on_surface);
            self.char(p, style, std.fmt.digitToChar(b & 0xf, .lower), x + pitch.hex, pitch.hex, baseline, t.on_surface);
            const printable = b >= 0x20 and b < 0x7f;
            self.char(p, style, if (printable) b else '.', pitch.text_start() + @as(f32, @floatFromInt(j)) * pitch.text, pitch.text, baseline, if (printable) t.on_surface else t.on_surface_variant);
        }
    }

    /// `c` in the middle of a cell `w` wide at `x`.
    fn char(_: *const HexRow, p: *kete.Painter, style: font.Style, c: u8, x: f32, w: f32, baseline: f32, color: gfx.Color) void {
        if (c == ' ') return;
        const cw = font.measure(style, &.{c});
        _ = p.text(style.size, @round(x + (w - cw) / 2), baseline, &.{c}, color);
    }
};

const testing = std.testing;

test "rows of bytes line up, the text after the bytes" {
    const fira = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const p = Pitch.of(&fira, 15);
    try testing.expect(p.hex > 0 and p.text >= p.hex);
    // A gap after the eighth byte, and the text after the last.
    try testing.expectApproxEqAbs(p.byte(8) - p.byte(7), p.byte(1) - p.byte(0) + p.hex, 0.001);
    try testing.expect(p.text_start() > p.byte(15) + 2 * p.hex);
    // Fewer bytes a row, narrower.
    var eight = p;
    eight.per_row = 8;
    try testing.expect(eight.width() < p.width() / 2 + p.hex * 10);
}

test "video viewer describes the video and renders transport controls" {
    const fira = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &fira);
    defer u.destroy();

    var frames = [_]video.Sample{
        .{ .offset = 0, .size = 8, .pts_us = 0, .keyframe = true },
        .{ .offset = 8, .size = 8, .pts_us = 5_000_000, .keyframe = true },
    };
    var pixels: [64 * 48]u32 = @splat(0xff224466);
    var player: video.Player = .{
        .gpa = testing.allocator,
        .stream = .{
            .gpa = testing.allocator,
            .fd = -1,
            .owns_fd = false,
            .codec = .h264,
            .width = 1280,
            .height = 720,
            .duration_us = 10_000_000,
            .samples = &frames,
            .header = &.{},
        },
        .image = .init(&pixels, 64, 48),
        .hw_unavailable = true,
    };
    const c: Content = .{
        .arena = .init(testing.allocator),
        .kind = .{ .video = &player },
    };

    const Wrapper = struct {
        content: *const Content,
        desc: *[]const u8,
        pub fn build(self: *const @This(), cx: *kete.BuildContext) kete.Widget {
            self.desc.* = describe(cx, self.content);
            return view(cx, self.content, 700);
        }
    };
    var desc: []const u8 = "";
    u.frame(700, 500, 0, Wrapper{ .content = &c, .desc = &desc });
    try testing.expectEqualStrings("H.264 video, 1280 × 720  ·  0:10", desc);

    const Find = struct {
        fn first(node: *kete.WidgetNode, comptime T: type) ?*kete.WidgetNode {
            if (node.widget.is(T)) return node;
            for (node.children.items) |ch| if (first(ch, T)) |n| return n;
            return null;
        }
    };
    try testing.expect(Find.first(u.root.?, kete.Image) != null);
    const seek = Find.first(u.root.?, kete.Slider).?;
    const at = seek.position();
    // kete's Slider's track is inset by its handle's halo at either end.
    const inset: f32 = kete.Slider.halo_radius;
    const click: kete.Point = .{ at[0] + inset + (seek.size.w - inset * 2) * 0.75, at[1] + seek.size.h * 0.5 };
    u.pointerMotion(click);
    u.pointerButton(click, .left, true);
    u.pointerButton(click, .left, false);
    try testing.expectEqual(@as(u64, 5_000_000), player.position_us);
}

test "audio viewer describes WAV files and renders transport controls" {
    const fira = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &fira);
    defer u.destroy();

    var wav_bytes: [44 + 44100 * 4]u8 = @splat(0);
    audio.wav.writePcm16Header(wav_bytes[0..44], 44100, 2, 44100 * 10);
    var player = audio.Player.openBytes(&wav_bytes).?;
    defer player.close();

    const c: Content = .{
        .arena = .init(testing.allocator),
        .kind = .{ .audio = &player },
    };

    const Wrapper = struct {
        content: *const Content,
        desc: *[]const u8,
        pub fn build(self: *const @This(), cx: *kete.BuildContext) kete.Widget {
            self.desc.* = describe(cx, self.content);
            return view(cx, self.content, 700);
        }
    };
    var desc: []const u8 = "";
    u.frame(700, 500, 0, Wrapper{ .content = &c, .desc = &desc });
    try testing.expectEqualStrings("WAV audio, 44.1 kHz stereo  ·  0:10", desc);

    const Find = struct {
        fn first(node: *kete.WidgetNode, comptime T: type) ?*kete.WidgetNode {
            if (node.widget.is(T)) return node;
            for (node.children.items) |ch| if (first(ch, T)) |n| return n;
            return null;
        }
    };
    const seek = Find.first(u.root.?, kete.Slider).?;
    const at = seek.position();
    // kete's Slider's track is inset by its handle's halo at either end.
    const inset: f32 = kete.Slider.halo_radius;
    const click: kete.Point = .{ at[0] + inset + (seek.size.w - inset * 2) * 0.5, at[1] + seek.size.h * 0.5 };
    u.pointerMotion(click);
    u.pointerButton(click, .left, true);
    u.pointerButton(click, .left, false);
    try testing.expectEqual(@as(u64, 5000), player.positionMs());
}
