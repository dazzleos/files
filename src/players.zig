//! Playing a sound or a video in the viewer, as kete widgets: what plays
//! (a disc with the file's name and format, or the video's picture) above
//! a bar with Play or Pause, a seek bar and the time, as Dazzle's own
//! toolkit (before kete) had them.

const std = @import("std");
const sys = @import("sys");
const audio = @import("audio");
const video = @import("video");
const kete = @import("kete");

const Context = kete.BuildContext;
const Widget = kete.Widget;
const Node = kete.WidgetNode;
const Event = kete.Event;
const Painter = kete.Painter;
const Constraints = kete.Constraints;
const Size = kete.Size;

/// A sound playing: its disc, name and format, and the transport bar.
pub const AudioPlayer = struct {
    player: *audio.Player,
    title: []const u8 = "",

    pub const State = struct {
        player: ?*audio.Player = null,

        fn onTogglePlay(st: *State) void {
            if (st.player) |p| p.togglePlay();
        }
    };

    pub fn build(self: *const AudioPlayer, cx: *Context, state: *State) Widget {
        const t = cx.theme();
        const p = self.player;
        state.player = p;

        var pos_buf: [32]u8 = undefined;
        var dur_buf: [32]u8 = undefined;
        const pos_str = video.formatDuration(&pos_buf, p.positionMs() * 1000);
        const dur_str = video.formatDuration(&dur_buf, p.durationMs() * 1000);

        var fmt_buf: [64]u8 = undefined;
        const fmt_str = cx.arena.dupe(u8, p.header.describe(&fmt_buf)) catch "WAV audio";

        const label = if (p.playing) "Pause" else if (p.ended) "Replay" else "Play";
        const play_icon: kete.IconName = if (p.playing) .pause else if (p.ended) .restart_alt else .play_arrow;

        const disc = cx.make(kete.RoundedBox{
            .color = t.primary_container,
            .radius = .all(48),
            .child = cx.make(kete.SizedBox{
                .width = 96,
                .height = 96,
                .child = cx.make(kete.Align{ .child = cx.make(kete.Icon{ .icon = .music_note, .size = 48, .color = t.on_primary_container }) }),
            }),
        });

        const card_children: []const Widget = if (self.title.len > 0)
            cx.makeAll(.{
                disc,
                kete.Text{ .text = self.title, .style = .{ .size = 20, .color = t.on_surface }, .wrap = false, .ellipsis = true },
                kete.Text{ .text = fmt_str, .style = .{ .size = 15, .color = t.on_surface_variant }, .wrap = false, .ellipsis = true },
            })
        else
            cx.makeAll(.{
                disc,
                kete.Text{ .text = fmt_str, .style = .{ .size = 16, .color = t.on_surface_variant }, .wrap = false, .ellipsis = true },
            });

        const artwork = cx.make(kete.Align{ .child = cx.make(kete.Column{
            .fill = false,
            .cross_axis_alignment = .center,
            .spacing = 12,
            .children = card_children,
        }) });

        return cx.make(kete.Column{ .cross_axis_alignment = .stretch, .children = cx.makeAll(.{
            kete.Expanded{ .child = artwork },
            transportBar(cx, cx.make(kete.OutlinedButton{
                .label = label,
                .icon = play_icon,
                .on_press = .of(state, State.onTogglePlay),
            }), cx.make(SeekTrack(audio.Player){ .player = p }), cx.fmt("{s} / {s}", .{ pos_str, dur_str })),
        }) });
    }
};

/// A video playing: its picture as big as fits (on black), or why there
/// is none yet, and the transport bar.
pub const VideoPlayer = struct {
    player: *video.Player,

    pub const State = struct {
        /// The picture shown, and the decoder's frame it is (each frame
        /// decoded is a new image, with an id of its own).
        image: ?kete.gfx.Image = null,
        from: u64 = 0,
    };

    const Act = struct {
        player: *video.Player,

        fn toggle(a: *const Act) void {
            a.player.togglePlay(sys.nowNs());
        }
    };

    pub fn build(self: *const VideoPlayer, cx: *Context, state: *State) Widget {
        const player = self.player;
        if (player.image) |img| {
            if (state.image == null or state.from != img.id) {
                state.image = .init(img.pixels, img.width, img.height);
                state.from = img.id;
            }
        } else state.image = null;
        const picture = if (state.image) |*img|
            cx.make(kete.Align{ .child = cx.make(kete.Image{ .source = .{ .image = img } }) })
        else if (player.hw_unavailable)
            cx.make(kete.Align{ .child = cx.make(kete.Padding{ .padding = .all(24), .child = cx.make(kete.Column{
                .fill = false,
                .spacing = 16,
                .children = cx.makeAll(.{
                    kete.Icon{ .icon = .videocam, .size = 64, .color = .rgb(0x938f99) },
                    kete.Text{ .text = "Hardware video decoder not available", .style = .{ .size = 18, .color = .rgb(0xcac4d0) }, .text_align = .center },
                }),
            }) }) })
        else
            cx.make(kete.Align{ .child = cx.make(kete.Spinner{ .size = 32 }) });

        var pos_buf: [32]u8 = undefined;
        var dur_buf: [32]u8 = undefined;
        const pos_str = video.formatDuration(&pos_buf, player.position_us);
        const dur_str = video.formatDuration(&dur_buf, player.stream.duration_us);
        const act = cx.arena.create(Act) catch null;
        if (act) |a| a.* = .{ .player = player };

        const label = if (player.playing) "Pause" else if (player.finished) "Replay" else "Play";
        const ic: kete.IconName = if (player.playing) .pause else if (player.finished) .restart_alt else .play_arrow;

        return cx.make(kete.Column{ .cross_axis_alignment = .stretch, .children = cx.makeAll(.{
            kete.Expanded{ .child = cx.make(kete.RoundedBox{ .color = .rgb(0x000000), .child = picture }) },
            transportBar(cx, cx.make(kete.OutlinedButton{
                .label = label,
                .icon = ic,
                .on_press = if (player.decoder != null and act != null) .of(act.?, Act.toggle) else null,
            }), cx.make(SeekTrack(video.Player){ .player = player }), cx.fmt("{s} / {s}", .{ pos_str, dur_str })),
        }) });
    }
};

/// Play (or Pause), the seek bar and the time, in a row under what plays.
fn transportBar(cx: *Context, play: Widget, seek: Widget, time: []const u8) Widget {
    const t = cx.theme();
    return cx.make(kete.SizedBox{ .height = 64, .child = cx.make(kete.Padding{ .padding = .{ .left = 16, .right = 16 }, .child = cx.make(kete.Row{
        .spacing = 16,
        .children = cx.makeAll(.{
            play,
            kete.Expanded{ .child = seek },
            kete.Text{ .text = time, .style = .{ .size = 15, .color = t.on_surface_variant }, .wrap = false },
        }),
    }) }) });
}

/// How far a player has got, and seeking it, for each kind of player.
fn progressOf(p: anytype) f32 {
    return switch (@TypeOf(p)) {
        *audio.Player => p.progress(),
        *video.Player => if (p.stream.duration_us > 0)
            std.math.clamp(@as(f32, @floatFromInt(p.position_us)) / @as(f32, @floatFromInt(p.stream.duration_us)), 0, 1)
        else
            0,
        else => @compileError("not a player"),
    };
}

fn seekTo(p: anytype, frac: f32) void {
    switch (@TypeOf(p)) {
        *audio.Player => p.seekMs(@intFromFloat(@round(frac * @as(f32, @floatFromInt(p.durationMs()))))),
        *video.Player => p.seekTo(@intFromFloat(@round(frac * @as(f32, @floatFromInt(p.stream.duration_us)))), sys.nowNs()),
        else => @compileError("not a player"),
    }
}

/// Whether it can be seeked (a video whose decoder has not started cannot).
fn seekable(p: anytype) bool {
    return switch (@TypeOf(p)) {
        *audio.Player => true,
        *video.Player => p.decoder != null or p.hw_unavailable,
        else => @compileError("not a player"),
    };
}

/// A player's progress, as a track with a thumb: pressing or dragging it
/// seeks.
pub fn SeekTrack(comptime Player: type) type {
    return struct {
        player: *Player,

        const Self = @This();

        pub const State = struct {
            dragging: bool = false,
        };

        pub fn layout(_: *const Self, _: *Node, c: Constraints) Size {
            return c.constrain(.{ .w = c.max_w, .h = 32 });
        }

        pub fn paint(self: *const Self, n: *Node, p: *Painter) void {
            const t = n.theme();
            const c = p.canvas();
            const pad: f32 = 8;
            const track_w = @max(n.size.w - pad * 2, 0);
            const track_h: f32 = 6;
            const track_y = @round((n.size.h - track_h) / 2);
            const fill_w = track_w * progressOf(self.player);

            c.fillRoundedRect(.{ .x = pad, .y = track_y, .w = track_w, .h = track_h }, .all(3), t.surface_container_highest);
            if (fill_w > 0) c.fillRoundedRect(.{ .x = pad, .y = track_y, .w = fill_w, .h = track_h }, .all(3), t.primary);
            const thumb_r: f32 = 7;
            const thumb_x = pad + fill_w - thumb_r;
            const thumb_y = @round(n.size.h / 2) - thumb_r;
            c.fillRoundedRect(.{ .x = thumb_x, .y = thumb_y, .w = thumb_r * 2, .h = thumb_r * 2 }, .all(thumb_r), if (seekable(self.player)) t.primary else t.outline);
        }

        pub fn cursor(self: *const Self, n: *Node, _: kete.Point) ?kete.PointerCursor {
            if (!seekable(self.player)) return null;
            return if (n.state(State).dragging) .grabbing else .pointer;
        }

        pub fn event(self: *const Self, n: *Node, e: Event) bool {
            if (!seekable(self.player)) return false;
            const st = n.state(State);
            switch (e) {
                .press => |pr| {
                    if (pr.button != .left) return false;
                    st.dragging = true;
                    self.seekAt(n, pr.pos[0]);
                    return true;
                },
                .motion => |pos| if (st.dragging) {
                    self.seekAt(n, pos[0]);
                    return true;
                },
                .release => |rel| if (st.dragging) {
                    st.dragging = false;
                    if (rel.inside) self.seekAt(n, rel.pos[0]);
                    return true;
                },
                else => {},
            }
            return false;
        }

        fn seekAt(self: *const Self, n: *Node, x: f32) void {
            const pad: f32 = 8;
            const track_w = @max(n.size.w - pad * 2, 1);
            seekTo(self.player, std.math.clamp((x - pad) / track_w, 0, 1));
        }
    };
}

// --- Tests ------------------------------------------------------------------

const testing = std.testing;

test "a sound plays, with its transport bar" {
    const f = try kete.font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();

    var wav_bytes: [44 + 4800 * 4]u8 = @splat(0);
    audio.wav.writePcm16Header(wav_bytes[0..44], 4800, 2, 4800);
    var player = audio.Player.openBytes(&wav_bytes).?;
    defer player.close();

    u.frame(640, 400, 1, AudioPlayer{ .player = &player, .title = "chime.wav" });
    try testing.expect(player.playing);
}
