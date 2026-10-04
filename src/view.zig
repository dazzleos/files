//! The Files window, as widgets: the title bar, and under it the tree of
//! folders on the left and the open folder on the right: its path (with a
//! button to go up), what is in it as a grid of icons, and a line about the
//! item picked (or how many there are). The tree and the grid scroll.
//!
//! Clicking a folder in the tree or the grid opens it; the arrow beside a
//! folder in the tree opens or closes it there. Clicking anything else in
//! the grid picks it.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const fs = @import("fs.zig");
const browser_mod = @import("browser.zig");

const Browser = browser_mod.Browser;

/// Sizes are designed for a window 900 pixels high (and 1600 wide), and
/// scale with it.
pub fn scaleFor(width: u32, height: u32) f32 {
    return std.math.clamp(@min(@as(f32, @floatFromInt(width)) / 1600, @as(f32, @floatFromInt(height)) / 900), 0.6, 2);
}

/// The most rows the tree shows.
pub const max_tree_rows = 2000;

pub const Files = struct {
    browser: *Browser,
    scale: f32,
    /// The title bar's buttons (close, and maximize, which shows whether
    /// the window is), pressing the bar (to move the window), and its scale
    /// (the screen's, so every app's title bar is the same).
    on_close: ?ui.Callback = null,
    on_maximize: ?ui.Callback = null,
    on_drag: ?ui.Callback = null,
    maximized: bool = true,
    bar_scale: f32 = 1,

    pub fn build(self: *const Files, cx: *ui.Context) ui.Widget {
        const s = self.scale;
        const t = cx.theme();
        const b = self.browser;
        const a = cx.ui.arena();

        var rows: std.ArrayList(ui.Widget) = .empty;
        self.treeRows(cx, &rows, "/", "/", 0);
        const tree = cx.make(ui.SizedBox{
            .width = @round(300 * s),
            .child = cx.make(ui.Decorated{
                .color = t.surface_container,
                // The open folder's row comes into view when it changes.
                .child = cx.make(ui.ScrollView{ .reveal = pathKey(b.path), .child = cx.make(ui.Padding{
                    .padding = .symmetric(@round(8 * s), @round(8 * s)),
                    .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .children = rows.items }),
                }) }),
            }),
        });

        const at_root = std.mem.eql(u8, b.path, "/");
        const header = cx.make(ui.Padding{ .padding = .symmetric(@round(16 * s), @round(12 * s)), .child = cx.make(ui.Row{ .spacing = @round(16 * s), .children = &.{
            cx.make(ui.OutlinedButton{ .label = "Up", .on_press = if (at_root) null else callback(cx, .{ .browser = b }, Act.up) }),
            cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = b.path, .style = .{ .size = 20 * s }, .wrap = false, .ellipsis = true }) }),
        } }) });

        const content = if (b.listing.err) |err|
            message(cx, s, switch (err) {
                error.AccessDenied => "You are not allowed to look in this folder",
                error.NotFound => "This folder is not there any more",
                else => "This folder cannot be opened",
            })
        else if (b.listing.entries.len == 0)
            message(cx, s, "This folder is empty")
        else blk: {
            const tiles: []ui.Widget = a.alloc(ui.Widget, b.listing.entries.len) catch &.{};
            for (tiles, b.listing.entries, 0..) |*w, e, i| w.* = cx.make(Tile{
                .entry = e,
                .selected = b.selected == i,
                .scale = s,
                .on_press = callback(cx, .{ .browser = b, .index = i }, Act.activate),
            });
            // Another folder starts again at the top.
            break :blk cx.make(ui.ScrollView{ .child = cx.make(ui.Padding{ .padding = .all(@round(16 * s)), .child = cx.make(ui.Grid{
                .cell = .{ .w = @round(128 * s), .h = @round(124 * s) },
                .spacing = @round(8 * s),
                .children = tiles,
            }) }) }).withKey(pathKey(b.path));
        };

        const footer = cx.make(ui.Padding{ .padding = .symmetric(@round(16 * s), @round(10 * s)), .child = cx.make(ui.Text{
            .text = self.status(cx),
            .style = .{ .size = 16 * s, .color = t.on_surface_variant },
            .wrap = false,
            .ellipsis = true,
        }) });

        return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .children = &.{
            cx.make(ui.TitleBar{
                .title = "Files",
                .on_close = self.on_close,
                .on_maximize = self.on_maximize,
                .on_drag = self.on_drag,
                .maximized = self.maximized,
                .scale = self.bar_scale,
            }),
            cx.make(ui.Expanded{ .child = cx.make(ui.Row{ .cross_axis_alignment = .stretch, .children = &.{
                tree,
                divider(cx, .vertical),
                cx.make(ui.Expanded{ .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .children = &.{
                    header,
                    divider(cx, .horizontal),
                    cx.make(ui.Expanded{ .child = content }),
                    divider(cx, .horizontal),
                    footer,
                } }) }),
            } }) }),
        } });
    }

    /// A row for the folder at `path`, and rows for the folders in it if it
    /// is open.
    fn treeRows(self: *const Files, cx: *ui.Context, rows: *std.ArrayList(ui.Widget), path: []const u8, label: []const u8, depth: usize) void {
        const b = self.browser;
        if (rows.items.len >= max_tree_rows) return;
        const a = cx.ui.arena();
        const expanded = b.isExpanded(path);
        const selected = std.mem.eql(u8, path, b.path);
        const row = cx.make(TreeRow{
            .label = label,
            .depth = depth,
            .expanded = expanded,
            .selected = selected,
            .scale = self.scale,
            .on_open = callback(cx, .{ .browser = b, .path = path }, Act.open),
            .on_toggle = callback(cx, .{ .browser = b, .path = path }, Act.toggle),
        });
        // The open folder's row has a key, for the tree to scroll to it.
        rows.append(a, if (selected) row.withKey(pathKey(path)) else row) catch return;
        if (!expanded) return;
        for (b.subfolders(path)) |e| {
            const child = fs.join(a, path, e.name) catch return;
            self.treeRows(cx, rows, child, e.name, depth + 1);
        }
    }

    /// About the item picked, or what is in the folder.
    fn status(self: *const Files, cx: *ui.Context) []const u8 {
        const l = &self.browser.listing;
        if (l.err != null) return "";
        if (self.browser.selected) |i| if (i < l.entries.len) {
            const e = l.entries[i];
            var size_buf: [32]u8 = undefined;
            const kind = switch (e.kind) {
                .folder => "Folder",
                .file => "File",
                .program => "Program",
                .device => "Device",
                .other => if (e.link) "Broken link" else "Other",
            };
            const link = if (e.link and e.kind != .other) " (link)" else "";
            if (e.kind == .file or e.kind == .program) return cx.fmt("{s}  ·  {s}{s}  ·  {s}", .{ e.name, kind, link, fs.formatSize(&size_buf, e.size) });
            return cx.fmt("{s}  ·  {s}{s}", .{ e.name, kind, link });
        };
        const n = l.entries.len;
        if (l.total > n) return cx.fmt("{d} items, showing the first {d}", .{ l.total, n });
        return cx.fmt("{d} {s}", .{ n, if (n == 1) "item" else "items" });
    }
};

fn pathKey(path: []const u8) u64 {
    return std.hash.Wyhash.hash(0, path);
}

/// What a click asks the browser for (made in the frame's arena).
const Act = struct {
    browser: *Browser,
    path: []const u8 = "",
    index: usize = 0,

    fn open(a: *const Act) void {
        a.browser.request(.{ .open = a.path });
    }

    fn toggle(a: *const Act) void {
        a.browser.request(.{ .toggle = a.path });
    }

    fn activate(a: *const Act) void {
        a.browser.request(.{ .activate = a.index });
    }

    fn up(a: *const Act) void {
        a.browser.request(.up);
    }
};

fn callback(cx: *ui.Context, act: Act, comptime f: fn (*const Act) void) ?ui.Callback {
    const p = cx.ui.arena().create(Act) catch return null;
    p.* = act;
    return .of(p, f);
}

fn message(cx: *ui.Context, s: f32, text: []const u8) ui.Widget {
    return cx.make(ui.Center{ .child = cx.make(ui.Padding{ .padding = .all(@round(24 * s)), .child = cx.make(ui.Text{
        .text = text,
        .style = .{ .size = 20 * s, .color = cx.theme().on_surface_variant },
        .text_align = .center,
    }) }) });
}

fn divider(cx: *ui.Context, axis: ui.widgets.Axis) ui.Widget {
    const line = cx.make(ui.Decorated{ .color = cx.theme().outline_variant });
    return cx.make(if (axis == .vertical) ui.SizedBox{ .width = 1, .child = line } else ui.SizedBox{ .height = 1, .child = line });
}

/// A folder in the tree: an arrow that opens or closes it there, its icon
/// and its name, indented by how deep it is.
pub const TreeRow = struct {
    label: []const u8,
    depth: usize,
    expanded: bool,
    selected: bool,
    scale: f32,
    on_open: ?ui.Callback,
    on_toggle: ?ui.Callback,

    pub const State = struct {
        interaction: ui.Interaction = .{},
    };

    pub fn build(self: *const TreeRow, cx: *ui.Context, state: *State) ui.Widget {
        const s = self.scale;
        const t = cx.theme();
        const height = @round(40 * s);
        const highlight: ?gfx.Color = if (self.selected) t.secondary_container else if (state.interaction.hovered) t.on_surface.withAlpha(0.08) else null;
        return cx.make(ui.Pressable{ .on_press = self.on_open, .interaction = &state.interaction, .child = cx.make(ui.Decorated{
            .color = highlight,
            .radius = .all(height / 2),
            .child = cx.make(ui.SizedBox{ .height = height, .child = cx.make(ui.Padding{
                .padding = .{ .left = @round(4 * s + @as(f32, @floatFromInt(@min(self.depth, 16))) * 18 * s), .right = @round(12 * s) },
                .child = cx.make(ui.Row{ .spacing = @round(6 * s), .children = &.{
                    cx.make(Disclosure{ .expanded = self.expanded, .size = @round(28 * s), .on_press = self.on_toggle }),
                    cx.make(FileIcon{ .kind = .folder, .size = @round(24 * s) }),
                    cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = self.label, .style = .{ .size = 17 * s }, .wrap = false, .ellipsis = true }) }),
                } }),
            }) }),
        }) });
    }
};

/// The arrow beside a folder in the tree: right when closed, down when
/// open.
const Disclosure = struct {
    expanded: bool,
    size: f32,
    on_press: ?ui.Callback,

    pub const State = struct {
        interaction: ui.Interaction = .{},
    };

    pub fn build(self: *const Disclosure, cx: *ui.Context, state: *State) ui.Widget {
        return cx.make(ui.Pressable{ .on_press = self.on_press, .interaction = &state.interaction, .child = cx.make(Arrow{
            .expanded = self.expanded,
            .size = self.size,
            .hovered = state.interaction.hovered,
        }) });
    }
};

const Arrow = struct {
    expanded: bool,
    size: f32,
    hovered: bool,

    pub fn layout(self: *const Arrow, _: *ui.Node, c: ui.Constraints) ui.Size {
        return c.constrain(.{ .w = self.size, .h = self.size });
    }

    pub fn paint(self: *const Arrow, n: *ui.Node, p: *ui.Painter) void {
        const t = &n.ui.theme;
        const c = p.canvas();
        const mid: gfx.Point = .{ n.size.w / 2, n.size.h / 2 };
        if (self.hovered) c.fillCircle(mid, n.size.w / 2, t.on_surface.withAlpha(0.08));
        const r = n.size.w * 0.16;
        const width = @max(n.size.w / 14, 1.5);
        if (self.expanded) {
            c.strokePolyline(&.{ .{ mid[0] - r, mid[1] - r / 2 }, .{ mid[0], mid[1] + r / 2 }, .{ mid[0] + r, mid[1] - r / 2 } }, false, width, t.on_surface_variant);
        } else {
            c.strokePolyline(&.{ .{ mid[0] - r / 2, mid[1] - r }, .{ mid[0] + r / 2, mid[1] }, .{ mid[0] - r / 2, mid[1] + r } }, false, width, t.on_surface_variant);
        }
    }
};

/// An item in the grid: its icon with its name under it.
pub const Tile = struct {
    entry: fs.Entry,
    selected: bool,
    scale: f32,
    on_press: ?ui.Callback,

    pub const State = struct {
        interaction: ui.Interaction = .{},
    };

    pub fn build(self: *const Tile, cx: *ui.Context, state: *State) ui.Widget {
        const s = self.scale;
        const t = cx.theme();
        const highlight: ?gfx.Color = if (self.selected) t.secondary_container else if (state.interaction.hovered) t.on_surface.withAlpha(0.08) else null;
        return cx.make(ui.Pressable{ .on_press = self.on_press, .interaction = &state.interaction, .child = cx.make(ui.Decorated{
            .color = highlight,
            .radius = .all(@round(12 * s)),
            .child = cx.make(ui.Padding{ .padding = .all(@round(8 * s)), .child = cx.make(ui.Column{ .spacing = @round(6 * s), .children = &.{
                cx.make(ui.Expanded{ .child = cx.make(ui.Center{ .child = cx.make(FileIcon{ .kind = self.entry.kind, .link = self.entry.link, .size = @round(64 * s) }) }) }),
                cx.make(ui.Text{ .text = self.entry.name, .style = .{ .size = 15 * s }, .text_align = .center, .wrap = false, .ellipsis = true }),
            } }) }),
        }) });
    }
};

/// A folder, or a page (with a mark for programs and devices), drawn to
/// fill a square; links get an arrow in the corner.
pub const FileIcon = struct {
    kind: fs.Kind,
    link: bool = false,
    size: f32,

    pub fn layout(self: *const FileIcon, _: *ui.Node, c: ui.Constraints) ui.Size {
        return c.constrain(.{ .w = self.size, .h = self.size });
    }

    pub fn paint(self: *const FileIcon, n: *ui.Node, p: *ui.Painter) void {
        const t = &n.ui.theme;
        const c = p.canvas();
        const z = @min(n.size.w, n.size.h);
        const x0 = (n.size.w - z) / 2;
        const y0 = (n.size.h - z) / 2;
        const P = struct {
            x: f32,
            y: f32,
            z: f32,
            fn at(q: @This(), u: f32, v: f32) gfx.Point {
                return .{ q.x + u * q.z, q.y + v * q.z };
            }
            fn rect(q: @This(), u: f32, v: f32, w: f32, h: f32) gfx.Rect {
                return .{ .x = q.x + u * q.z, .y = q.y + v * q.z, .w = w * q.z, .h = h * q.z };
            }
        };
        const q: P = .{ .x = x0, .y = y0, .z = z };
        const line = @max(z / 28, 1);
        switch (self.kind) {
            .folder => {
                const back = t.primary.withAlpha(0.55);
                c.fillRoundedRect(q.rect(0.08, 0.16, 0.36, 0.16), .all(z * 0.04), back);
                c.fillRoundedRect(q.rect(0.08, 0.22, 0.84, 0.62), .all(z * 0.06), back);
                c.fillRoundedRect(q.rect(0.08, 0.32, 0.84, 0.54), .all(z * 0.06), t.primary);
            },
            else => {
                const page = [_]gfx.Point{ q.at(0.2, 0.08), q.at(0.6, 0.08), q.at(0.8, 0.28), q.at(0.8, 0.92), q.at(0.2, 0.92) };
                const fill = if (self.kind == .other) t.surface_container else t.surface_container_highest;
                c.fillPolygon(&page, fill);
                c.strokePolyline(&page, true, line, t.outline);
                c.fillPolygon(&.{ q.at(0.6, 0.08), q.at(0.6, 0.28), q.at(0.8, 0.28) }, t.outline_variant);
                switch (self.kind) {
                    .program => c.fillPolygon(&.{ q.at(0.4, 0.44), q.at(0.64, 0.6), q.at(0.4, 0.76) }, t.primary),
                    .device => {
                        c.fillRoundedRect(q.rect(0.36, 0.46, 0.28, 0.28), .all(z * 0.03), t.primary_container);
                        for ([_]f32{ 0.52, 0.6, 0.68 }) |v| {
                            c.strokePolyline(&.{ q.at(0.3, v), q.at(0.36, v) }, false, line, t.outline);
                            c.strokePolyline(&.{ q.at(0.64, v), q.at(0.7, v) }, false, line, t.outline);
                        }
                    },
                    .file => for ([_]f32{ 0.46, 0.58, 0.7 }) |v| {
                        c.strokePolyline(&.{ q.at(0.32, v), q.at(0.68, v) }, false, line, t.on_surface_variant.withAlpha(0.5));
                    },
                    else => {},
                }
            },
        }
        if (self.link) {
            const mid = q.at(0.24, 0.8);
            const r = z * 0.14;
            c.fillCircle(mid, r, t.surface);
            c.strokeCircle(mid, r, line, t.on_surface_variant);
            const a = r * 0.45;
            c.strokePolyline(&.{ .{ mid[0] - a, mid[1] + a }, .{ mid[0] + a, mid[1] - a } }, false, line, t.on_surface_variant);
            c.strokePolyline(&.{ .{ mid[0] - a * 0.2, mid[1] - a }, .{ mid[0] + a, mid[1] - a }, .{ mid[0] + a, mid[1] + a * 0.2 } }, false, line, t.on_surface_variant);
        }
    }
};

// --- Tests ---------------------------------------------------------------------

const testing = std.testing;
const font = @import("font");

fn overflows(node: *ui.Node) bool {
    if (node.overflow.any()) return true;
    for (node.children.items) |ch| if (overflows(ch)) return true;
    return false;
}

fn findText(n: *ui.Node, text: []const u8) ?*ui.Node {
    if (n.widget.as(ui.Text)) |t| if (std.mem.eql(u8, t.text, text)) return n;
    for (n.children.items) |ch| if (findText(ch, text)) |f| return f;
    return null;
}

/// The nearest node above `n` (or `n`) whose widget is a `T`.
fn up(n: *ui.Node, comptime T: type) ?*ui.Node {
    var at: ?*ui.Node = n;
    while (at) |a| : (at = a.parent) if (a.widget.is(T)) return a;
    return null;
}

fn click(u: *ui.Ui, n: *ui.Node) void {
    const at = n.position();
    const p: ui.Point = .{ at[0] + n.size.w / 2, at[1] + n.size.h / 2 };
    u.pointerMotion(p);
    u.pointerButton(p, ui.widgets.btn_left, true);
    u.pointerButton(p, ui.widgets.btn_left, false);
}

test "the tree and the grid fit, at the shell's sizes" {
    var t: fs.TestTree = .{};
    try t.init();
    defer t.deinit();
    var b = try Browser.init(testing.allocator, t.path);
    defer b.deinit();
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    for ([_][3]u32{ .{ 1920, 1036, 1920 }, .{ 960, 518, 1920 }, .{ 1280, 668, 1280 }, .{ 640, 334, 1280 } }) |size| {
        u.frame(size[0], size[1], 0, Files{ .browser = &b, .scale = scaleFor(size[0], size[1]), .bar_scale = @as(f32, @floatFromInt(size[2])) / 1920 });
        try testing.expect(!overflows(u.root.?));
    }
    // The tree: "/", the folders down to the open one, and its folders.
    try testing.expect(findText(u.root.?, "/") != null);
    try testing.expect(findText(u.root.?, "tmp") != null);
    try testing.expect(findText(u.root.?, std.fs.path.basename(t.path)) != null);
    // The grid, and how many items there are.
    try testing.expect(findText(u.root.?, "b-file") != null);
    try testing.expect(findText(u.root.?, "5 items") != null);
}

test "clicking in the grid and the tree" {
    var t: fs.TestTree = .{};
    try t.init();
    defer t.deinit();
    var b = try Browser.init(testing.allocator, t.path);
    defer b.deinit();
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    var now: u64 = 0;
    const Frame = struct {
        fn draw(uu: *ui.Ui, bb: *Browser, n: *u64) void {
            _ = bb.apply();
            n.* += 1;
            uu.frame(1600, 900, n.*, Files{ .browser = bb, .scale = 1 });
        }
    }.draw;
    Frame(u, &b, &now);

    // A file is picked, and the line under the grid says what it is.
    click(u, tile(u, "b-file").?);
    Frame(u, &b, &now);
    try testing.expectEqual(@as(?usize, 2), b.selected);
    try testing.expect(findText(u.root.?, "b-file  ·  File  ·  5 bytes") != null);

    // A folder in the grid opens.
    click(u, tile(u, "A-folder").?);
    Frame(u, &b, &now);
    try testing.expect(std.mem.endsWith(u8, b.path, "/A-folder"));
    try testing.expect(findText(u.root.?, "This folder is empty") != null);

    // Up goes back.
    click(u, up(findText(u.root.?, "Up").?, ui.OutlinedButton).?);
    Frame(u, &b, &now);
    try testing.expectEqualStrings(t.path, b.path);

    // The arrow closes a folder in the tree (its folders go), and clicking
    // a folder in the tree opens it.
    var row = up(findText(u.root.?, std.fs.path.basename(t.path)).?, TreeRow).?;
    // The host may have many folders above it: scroll the tree to it.
    const tree = up(row, ui.ScrollView).?;
    _ = tree.state(ui.ScrollView.State).scrollTo(row.position()[1] - tree.position()[1] + tree.state(ui.ScrollView.State).offset);
    Frame(u, &b, &now);
    row = up(findText(u.root.?, std.fs.path.basename(t.path)).?, TreeRow).?;
    try testing.expect(findText(row.parent.?, "z-link") != null);
    var arrows: ?*ui.Node = null;
    for (row.children.items) |ch| arrows = arrows orelse findDisclosure(ch);
    click(u, arrows.?);
    Frame(u, &b, &now);
    try testing.expect(!b.isExpanded(t.path));
    try testing.expectEqualStrings(t.path, b.path);
    const tmp = up(findText(u.root.?, "tmp").?, TreeRow).?;
    _ = tree.state(ui.ScrollView.State).scrollTo(tmp.position()[1] - tree.position()[1] + tree.state(ui.ScrollView.State).offset);
    Frame(u, &b, &now);
    click(u, up(findText(u.root.?, "tmp").?, TreeRow).?);
    Frame(u, &b, &now);
    try testing.expectEqualStrings("/tmp", b.path);
}

fn findType(n: *ui.Node, comptime T: type) ?*ui.Node {
    if (n.widget.is(T)) return n;
    for (n.children.items) |ch| if (findType(ch, T)) |f| return f;
    return null;
}

/// The grid's tile for `name`.
fn tile(u: *ui.Ui, name: []const u8) ?*ui.Node {
    const grid = findType(u.root.?, ui.Grid) orelse return null;
    return up(findText(grid, name) orelse return null, Tile);
}

fn findDisclosure(n: *ui.Node) ?*ui.Node {
    if (n.widget.is(Disclosure)) return n;
    for (n.children.items) |ch| if (findDisclosure(ch)) |d| return d;
    return null;
}
