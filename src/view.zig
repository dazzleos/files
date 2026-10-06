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

/// Sizes are designed for a screen whose maximized windows are 900 pixels
/// high (and 1600 wide), and scale with it: the scale is the maximized
/// window's, kept when the window is restored so text stays the same size.
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

        // The folders in the tree; rows are made only for those that show.
        var items: std.ArrayList(TreeItem) = .empty;
        const root = b.root();
        self.treeItems(cx, &items, root, if (std.mem.eql(u8, root, b.home)) "Home" else root, null, !fs.writable(root), 0);
        const open_row: ?usize = for (items.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.path, b.path)) break i;
        } else null;
        const rows = cx.make(ui.LazyGrid{
            .count = items.items.len,
            .cell = .{ .w = std.math.inf(f32), .h = @round(40 * s) },
            .item = .of(makeTree(cx, self, items.items), Tree.row),
            // The open folder's row is made even when it does not show, for
            // the tree to scroll to it.
            .keep = open_row,
        });
        const tree = cx.make(ui.SizedBox{
            .width = @round(300 * s),
            .child = cx.make(ui.Decorated{
                .color = t.surface_container,
                .child = cx.make(ui.Column{
                    .cross_axis_alignment = .stretch,
                    .children = &.{
                        // The open folder's row comes into view when it changes.
                        cx.make(ui.Expanded{ .child = cx.make(ui.ScrollView{ .reveal = pathKey(b.path), .child = cx.make(ui.Padding{
                            .padding = .symmetric(@round(8 * s), @round(8 * s)),
                            .child = rows,
                        }) }) }),
                        divider(cx, .horizontal),
                        // Whether the system's files are shown, or only the
                        // user's.
                        cx.make(ui.Padding{ .padding = .symmetric(@round(16 * s), @round(8 * s)), .child = cx.make(ui.Switch{
                            .value = b.show_system,
                            .on_changed = systemCallback(cx, b),
                            .label = "System files",
                        }) }),
                    },
                }),
            }),
        });

        const at_root = b.atRoot();
        // The path, and under it what the folder is for (if it is one of
        // the system's).
        const path_text = cx.make(ui.Text{ .text = b.path, .style = .{ .size = 20 * s }, .wrap = false, .ellipsis = true });
        const about = if (fs.describe(b.path)) |d| cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = @round(2 * s), .children = &.{
            path_text,
            cx.make(ui.Text{ .text = d, .style = .{ .size = 15 * s, .color = t.on_surface_variant }, .wrap = false, .ellipsis = true }),
        } }) else path_text;
        const header = cx.make(ui.Padding{ .padding = .symmetric(@round(16 * s), @round(12 * s)), .child = cx.make(ui.Row{ .spacing = @round(16 * s), .children = &.{
            cx.make(ui.OutlinedButton{ .label = "Up", .icon = .arrow_upward, .on_press = if (at_root) null else callback(cx, .{ .browser = b }, Act.up) }),
            cx.make(ui.Expanded{ .child = about }),
        } }) });

        const content = if (b.listing.err) |err|
            message(cx, s, switch (err) {
                error.AccessDenied => "You are not allowed to look in this folder",
                error.NotFound => "This folder is not there any more",
                else => "This folder cannot be opened",
            })
        else if (b.listing.entries.len == 0)
            message(cx, s, "This folder is empty")
        else
            // Only the tiles that show are made (a folder can have a
            // thousand items). Another folder starts again at the top.
            cx.make(ui.ScrollView{ .child = cx.make(ui.Padding{ .padding = .all(@round(16 * s)), .child = cx.make(ui.LazyGrid{
                .count = b.listing.entries.len,
                .cell = .{ .w = @round(128 * s), .h = @round(124 * s) },
                .spacing = @round(8 * s),
                .item = .of(self, Files.tile),
            }) }) }).withKey(pathKey(b.path));

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

    /// The folder at `path` in the tree, and the folders in it if it is
    /// open. `subfolders` is whether there are folders in it, if known;
    /// `locked`, whether it cannot be changed.
    fn treeItems(self: *const Files, cx: *ui.Context, items: *std.ArrayList(TreeItem), path: []const u8, label: []const u8, subfolders: ?bool, locked: bool, depth: usize) void {
        const b = self.browser;
        if (items.items.len >= max_tree_rows) return;
        const a = cx.ui.arena();
        const expanded = b.isExpanded(path);
        items.append(a, .{
            .path = path,
            .label = label,
            .depth = depth,
            .expanded = expanded,
            // An arrow only if opening it in the tree shows something.
            .expandable = if (expanded) b.subfolders(path).len > 0 else subfolders orelse true,
            .locked = locked,
        }) catch return;
        if (!expanded) return;
        for (b.subfolders(path)) |e| {
            const child = fs.join(a, path, e.name) catch return;
            self.treeItems(cx, items, child, e.name, e.subfolders, !e.writable, depth + 1);
        }
    }

    /// The grid's tile for the open folder's item `i`.
    fn tile(self: *const Files, cx: *ui.Context, i: usize) ui.Widget {
        const b = self.browser;
        return cx.make(Tile{
            .entry = b.listing.entries[i],
            .selected = b.selected == i,
            .scale = self.scale,
            .on_press = callback(cx, .{ .browser = b, .index = i }, Act.activate),
        });
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

/// A folder in the tree.
const TreeItem = struct {
    path: []const u8,
    label: []const u8,
    depth: usize,
    expanded: bool,
    expandable: bool,
    locked: bool,
};

/// The tree's folders, for its list to make rows of (made in the frame's
/// arena).
const Tree = struct {
    files: *const Files,
    items: []const TreeItem,

    fn row(t: *const Tree, cx: *ui.Context, i: usize) ui.Widget {
        const b = t.files.browser;
        const item = t.items[i];
        const selected = std.mem.eql(u8, item.path, b.path);
        const w = cx.make(TreeRow{
            .label = item.label,
            .depth = item.depth,
            .expanded = item.expanded,
            .expandable = item.expandable,
            .locked = item.locked,
            .home = item.depth == 0 and std.mem.eql(u8, item.path, b.home),
            .selected = selected,
            .scale = t.files.scale,
            .on_open = callback(cx, .{ .browser = b, .path = item.path }, Act.open),
            .on_toggle = callback(cx, .{ .browser = b, .path = item.path }, Act.toggle),
        });
        // The open folder's row has a key, for the tree to scroll to it.
        return if (selected) w.withKey(pathKey(item.path)) else w;
    }
};

fn makeTree(cx: *ui.Context, files: *const Files, items: []const TreeItem) *const Tree {
    const t = cx.ui.arena().create(Tree) catch {
        const empty = struct {
            const none: Tree = .{ .files = undefined, .items = &.{} };
        };
        return &empty.none;
    };
    t.* = .{ .files = files, .items = items };
    return t;
}

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

fn systemCallback(cx: *ui.Context, b: *Browser) ?ui.ValueCallback(bool) {
    const p = cx.ui.arena().create(Act) catch return null;
    p.* = .{ .browser = b };
    return .of(p, struct {
        fn set(a: *const Act, on: bool) void {
            a.browser.request(.{ .show_system = on });
        }
    }.set);
}

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

/// A folder in the tree: an arrow that opens or closes it there (if there
/// are folders in it), its icon and its name (with a lock beside it if it
/// cannot be changed), indented by how deep it is.
pub const TreeRow = struct {
    label: []const u8,
    depth: usize,
    expanded: bool,
    expandable: bool = true,
    locked: bool = false,
    /// The user's files: a house rather than a folder.
    home: bool = false,
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
        const arrow = if (self.expandable)
            cx.make(Disclosure{ .expanded = self.expanded, .size = @round(28 * s), .on_press = self.on_toggle })
        else
            cx.make(ui.SizedBox{ .width = @round(28 * s), .height = @round(28 * s) });
        const icon = cx.make(FileIcon{ .kind = .folder, .icon = if (self.home) .home else null, .size = @round(24 * s) });
        const name = cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = self.label, .style = .{ .size = 17 * s }, .wrap = false, .ellipsis = true }) });
        return cx.make(ui.Pressable{ .on_press = self.on_open, .interaction = &state.interaction, .child = cx.make(ui.Decorated{
            .color = highlight,
            .radius = .all(height / 2),
            .child = cx.make(ui.SizedBox{ .height = height, .child = cx.make(ui.Padding{
                .padding = .{ .left = @round(4 * s + @as(f32, @floatFromInt(@min(self.depth, 16))) * 18 * s), .right = @round(12 * s) },
                .child = cx.make(ui.Row{ .spacing = @round(6 * s), .children = if (self.locked)
                    &.{ arrow, icon, name, cx.make(ui.Icon{ .icon = .lock, .size = @round(18 * s), .color = t.on_surface_variant }) }
                else
                    &.{ arrow, icon, name } }),
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
        const t = cx.theme();
        return cx.make(ui.Pressable{ .on_press = self.on_press, .interaction = &state.interaction, .child = cx.make(ui.Decorated{
            .color = if (state.interaction.hovered) t.on_surface.withAlpha(0.08) else null,
            .radius = .all(self.size / 2),
            .child = cx.make(ui.SizedBox{ .width = self.size, .height = self.size, .child = cx.make(ui.Icon{
                .icon = if (self.expanded) .expand_more else .chevron_right,
                .size = @round(self.size * 0.75),
                .color = t.on_surface_variant,
            }) }),
        }) });
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
                cx.make(ui.Expanded{ .child = cx.make(ui.Center{ .child = cx.make(FileIcon{ .kind = self.entry.kind, .link = self.entry.link, .locked = self.entry.kind == .folder and !self.entry.writable, .size = @round(64 * s) }) }) }),
                cx.make(ui.Text{ .text = self.entry.name, .style = .{ .size = 15 * s }, .text_align = .center, .wrap = false, .ellipsis = true }),
            } }) }),
        }) });
    }
};

/// What an item is, as a Material icon (folders in the primary colour);
/// links get a badge in the corner, and folders that cannot be changed
/// (the system's) a lock in the other.
pub const FileIcon = struct {
    kind: fs.Kind,
    link: bool = false,
    locked: bool = false,
    size: f32,
    /// The icon instead of the kind's.
    icon: ?ui.icons.Icon = null,

    pub fn glyph(self: *const FileIcon) ui.icons.Icon {
        return self.icon orelse switch (self.kind) {
            .folder => .folder,
            .file => .description,
            .program => .terminal,
            .device => .memory,
            // A pipe or socket, or a link to nothing.
            .other => if (self.link) .link_off else .help_outline,
        };
    }

    pub fn build(self: *const FileIcon, cx: *ui.Context) ui.Widget {
        const t = cx.theme();
        const main = cx.make(ui.Icon{ .icon = self.glyph(), .size = self.size, .color = if (self.kind == .folder) t.primary else t.on_surface_variant });
        const link = self.link and self.kind != .other;
        if (!link and !self.locked) return main;
        return cx.make(ui.SizedBox{ .width = self.size, .height = self.size, .child = cx.make(ui.Overlay{ .children = &.{
            main,
            if (link) self.badge(cx, .link, .bottom_left) else cx.make(ui.Empty{}),
            if (self.locked) self.badge(cx, .lock, .bottom_right) else cx.make(ui.Empty{}),
        } }) });
    }

    /// A small icon on a disc, in a corner.
    fn badge(self: *const FileIcon, cx: *ui.Context, icon: ui.icons.Icon, corner: ui.Alignment) ui.Widget {
        const t = cx.theme();
        const d = @round(self.size * 0.4);
        return cx.make(ui.Align{ .alignment = corner, .child = cx.make(ui.Decorated{
            .color = t.surface_container_highest,
            .radius = .all(d / 2),
            .child = cx.make(ui.SizedBox{ .width = d, .height = d, .child = cx.make(ui.Icon{ .icon = icon, .size = @round(d * 0.7), .color = t.on_surface }) }),
        }) });
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

/// The sizes the shell gives windows, and the size of a maximized one
/// (which sets the scale): maximized and restored on a 1080p screen and a
/// 720p one.
const shell_sizes = [_][4]u32{
    .{ 1920, 1036, 1920, 1036 },
    .{ 960, 518, 1920, 1036 },
    .{ 1280, 668, 1280, 668 },
    .{ 640, 334, 1280, 668 },
};

test "the tree and the grid fit, at the shell's sizes" {
    var t: fs.TestTree = .{};
    try t.init();
    defer t.deinit();
    var b = try Browser.init(testing.allocator, t.path);
    defer b.deinit();
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    for (shell_sizes) |size| {
        u.frame(size[0], size[1], 0, Files{ .browser = &b, .scale = scaleFor(size[2], size[3]), .bar_scale = @as(f32, @floatFromInt(size[2])) / 1920 });
        try testing.expect(!overflows(u.root.?));
    }
    // The tree: home and its folders, and nothing above it; the switch for
    // the system's files.
    try testing.expect(findText(u.root.?, "Home") != null);
    try testing.expect(findText(u.root.?, "z-link") != null);
    try testing.expect(findText(u.root.?, "tmp") == null);
    try testing.expect(findText(u.root.?, "System files") != null);
    // Fits with them shown, too.
    try b.showSystem(true);
    for (shell_sizes) |size| {
        u.frame(size[0], size[1], 0, Files{ .browser = &b, .scale = scaleFor(size[2], size[3]), .bar_scale = @as(f32, @floatFromInt(size[2])) / 1920 });
        try testing.expect(!overflows(u.root.?));
    }
    // The grid, and how many items there are.
    try testing.expect(findText(u.root.?, "b-file") != null);
    try testing.expect(findText(u.root.?, "5 items") != null);

    // Folders that cannot be changed have a lock, in the tree and the grid.
    try b.showSystem(false);
    u.frame(1600, 900, 0, Files{ .browser = &b, .scale = 1 });
    try testing.expect(findIcon(u.root.?, .lock) == null);
    b.listing.entries[0].writable = false;
    b.expanded.getPtr(t.path).?.entries[0].writable = false;
    u.frame(1600, 900, 0, Files{ .browser = &b, .scale = 1 });
    try testing.expect(findIcon(up(findText(u.root.?, "A-folder").?, TreeRow).?, .lock) != null);
    try testing.expect(findIcon(up(findText(u.root.?, "z-link").?, TreeRow).?, .lock) == null);
    try testing.expect(findIcon(tile(u, "A-folder").?, .lock) != null);
    try testing.expect(tile(u, "A-folder").?.widget.as(Tile).?.entry.writable == false);
    try testing.expect(!overflows(u.root.?));
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

    // Up goes back, as far as home (where it is disabled).
    click(u, up(findText(u.root.?, "Up").?, ui.OutlinedButton).?);
    Frame(u, &b, &now);
    try testing.expectEqualStrings(t.path, b.path);
    try testing.expect(up(findText(u.root.?, "Up").?, ui.OutlinedButton).?.widget.as(ui.OutlinedButton).?.on_press == null);

    // Only folders with folders in them have an arrow.
    try testing.expect(findDisclosure(up(findText(u.root.?, "A-folder").?, TreeRow).?) == null);
    try testing.expect(findDisclosure(up(findText(u.root.?, "z-link").?, TreeRow).?) == null);

    // The arrow closes home in the tree (its folders go).
    const home_row = up(findText(u.root.?, "Home").?, TreeRow).?;
    try testing.expect(findText(home_row.parent.?, "z-link") != null);
    click(u, findDisclosure(home_row).?);
    Frame(u, &b, &now);
    try testing.expect(!b.isExpanded(t.path));
    try testing.expect(findText(up(findText(u.root.?, "Home").?, ui.ScrollView).?, "z-link") == null);

    // The switch shows the system's files: the tree starts at /, and a
    // folder above home opens.
    click(u, up(findText(u.root.?, "System files").?, ui.Switch).?);
    Frame(u, &b, &now);
    try testing.expect(b.show_system);
    try testing.expect(findText(u.root.?, "/") != null);
    // The host may have many folders, and only the rows that show are
    // made: scroll the tree down from the top until /tmp's row shows.
    const tree = up(findType(u.root.?, TreeRow).?, ui.ScrollView).?;
    const scroll = tree.state(ui.ScrollView.State);
    _ = scroll.scrollTo(0);
    Frame(u, &b, &now);
    const tmp = while (true) {
        if (findText(tree, "tmp")) |text| if (up(text, TreeRow)) |row| {
            const y = row.position()[1] - tree.position()[1];
            if (y >= 0 and y + row.size.h <= tree.size.h) break row;
        };
        try testing.expect(scroll.scrollTo(scroll.offset + 40));
        Frame(u, &b, &now);
    };
    click(u, tmp);
    Frame(u, &b, &now);
    try testing.expectEqualStrings("/tmp", b.path);
    // A system folder says what it is for.
    try testing.expect(findText(u.root.?, "Everything on this computer") == null);
    b.request(.{ .open = "/" });
    Frame(u, &b, &now);
    try testing.expect(findText(u.root.?, "Everything on this computer") != null);
    try testing.expect(!overflows(u.root.?));
    // Off again: back home.
    click(u, up(findText(u.root.?, "System files").?, ui.Switch).?);
    Frame(u, &b, &now);
    try testing.expect(!b.show_system);
    try testing.expectEqualStrings(t.path, b.path);
}

/// The first icon (depth first) that is `icon`.
fn findIcon(n: *ui.Node, icon: ui.icons.Icon) ?*ui.Node {
    if (n.widget.as(ui.Icon)) |i| if (i.icon == icon) return n;
    for (n.children.items) |ch| if (findIcon(ch, icon)) |f| return f;
    return null;
}

fn findType(n: *ui.Node, comptime T: type) ?*ui.Node {
    if (n.widget.is(T)) return n;
    for (n.children.items) |ch| if (findType(ch, T)) |f| return f;
    return null;
}

/// The grid's tile for `name`.
fn tile(u: *ui.Ui, name: []const u8) ?*ui.Node {
    const grid = up(findType(u.root.?, Tile) orelse return null, ui.LazyGrid) orelse return null;
    return up(findText(grid, name) orelse return null, Tile);
}

fn findDisclosure(n: *ui.Node) ?*ui.Node {
    if (n.widget.is(Disclosure)) return n;
    for (n.children.items) |ch| if (findDisclosure(ch)) |d| return d;
    return null;
}
