//! The Files window, as widgets: the title bar, and under it the tree of
//! folders on the left and the open folder on the right: its path (with a
//! button to go up, and buttons for the order of its items and how they
//! are shown), what is in it as a grid of icons or a list (with when each
//! was changed, and its size), and a line about the item picked (or how
//! many there are), with buttons to make a folder and to delete the item
//! picked. The tree and the items scroll.
//!
//! Clicking a folder in the tree or among the items opens it; the arrow
//! beside a folder in the tree opens or closes it there. Clicking anything
//! else among the items picks it.
//!
//! Making a folder asks for its name in the line at the bottom, and
//! deleting asks whether to there too, warning that a folder goes with
//! everything in it.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const fs = @import("fs.zig");
const browser_mod = @import("browser.zig");
const viewer = @import("viewer.zig");

const Browser = browser_mod.Browser;
const Layout = browser_mod.Layout;

/// The smallest the window may be: the tree, and two columns of the
/// grid beside it. Everything is the same size in pixels whatever the
/// window's size; a bigger window shows more.
pub const min_size = [2]u32{ 640, 420 };

/// The most rows the tree shows.
pub const max_tree_rows = 2000;

pub const Files = struct {
    browser: *Browser,
    /// The title bar's buttons (close, and maximize, which shows whether
    /// the window is), and pressing the bar (to move the window).
    on_close: ?ui.Callback = null,
    on_maximize: ?ui.Callback = null,
    on_drag: ?ui.Callback = null,
    maximized: bool = true,
    /// The window's width (a file's bytes are shown as many a row as fit).
    width: f32 = 1600,
    /// The time now, in seconds since 1970 (when items were changed is
    /// shown against it).
    now: i64 = 0,

    pub fn build(self: *const Files, cx: *ui.Context) ui.Widget {
        const t = cx.theme();
        const b = self.browser;

        // The folders in the tree; rows are made only for those that show.
        var items: std.ArrayList(TreeItem) = .empty;
        const root = b.root();
        self.treeItems(cx, &items, root, if (std.mem.eql(u8, root, b.user_files)) "User files" else root, null, !fs.writable(root), 0);
        const open_row: ?usize = for (items.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.path, b.path)) break i;
        } else null;
        const rows = cx.make(ui.LazyGrid{
            .count = items.items.len,
            .cell = .{ .w = std.math.inf(f32), .h = 40 },
            .item = .of(makeTree(cx, self, items.items), Tree.row),
            // The open folder's row is made even when it does not show, for
            // the tree to scroll to it.
            .keep = open_row,
        });
        const tree = cx.make(ui.SizedBox{
            .width = 300,
            .child = cx.make(ui.Decorated{
                .color = t.surface_container,
                .child = cx.make(ui.Column{
                    .cross_axis_alignment = .stretch,
                    .children = &.{
                        // The open folder's row comes into view when it changes.
                        cx.make(ui.Expanded{ .child = cx.make(ui.ScrollView{ .reveal = pathKey(b.path), .child = cx.make(ui.Padding{
                            .padding = .symmetric(8, 8),
                            .child = rows,
                        }) }) }),
                        divider(cx, .horizontal),
                        // Whether the system's files are shown, or only the
                        // user's.
                        cx.make(ui.Padding{ .padding = .symmetric(16, 8), .child = cx.make(ui.Switch{
                            .value = b.show_system,
                            .on_changed = systemCallback(cx, b),
                            .label = "System files",
                        }) }),
                    },
                }),
            }),
        });

        const at_root = b.atRoot() and b.file == null;
        // The path, and under it what the folder is for (if it is one of
        // the system's), or what the file shown holds.
        const file_path = b.filePath(cx.ui.arena());
        const path_text = cx.make(ui.Text{ .text = file_path orelse b.path, .style = .{ .size = 20 }, .wrap = false, .ellipsis = true });
        const description: ?[]const u8 = if (b.file) |*f| (if (f.err == null) viewer.describe(cx, f) else null) else fs.describe(b.path);
        const about = if (description) |d| cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 2, .children = &.{
            path_text,
            cx.make(ui.Text{ .text = d, .style = .{ .size = 15, .color = t.on_surface_variant }, .wrap = false, .ellipsis = true }),
        } }) else path_text;
        // The order of the items and how they are shown, each a button
        // saying which, that changes it (not while a file is shown); in a
        // narrow window, by their icons alone.
        const folder = b.file == null;
        const labels = self.width >= 1000;
        const order_button = cx.make(ui.OutlinedButton{
            .label = if (!labels) "" else if (b.order == .name) "Name" else "Newest",
            .icon = if (b.order == .name) .sort_by_alpha else .schedule,
            .on_press = if (folder) callback(cx, .{ .browser = b }, Act.reorder) else null,
        });
        const layout_button = cx.make(ui.OutlinedButton{
            .label = if (!labels) "" else if (b.layout == .icons) "Icons" else "List",
            .icon = if (b.layout == .icons) .grid_view else .view_list,
            .on_press = if (folder) callback(cx, .{ .browser = b }, Act.relayout) else null,
        });
        const header = cx.make(ui.Padding{ .padding = .symmetric(16, 12), .child = cx.make(ui.Row{ .spacing = 16, .children = &.{
            cx.make(ui.OutlinedButton{ .label = "Up", .icon = .arrow_upward, .on_press = if (at_root) null else callback(cx, .{ .browser = b }, Act.up) }),
            cx.make(ui.Expanded{ .child = about }),
            order_button,
            layout_button,
        } }) });

        const content = if (b.file) |*f|
            viewer.view(cx, f, self.width - 300 - 1).withKey(pathKey(file_path orelse ""))
        else if (b.listing.err) |err|
            message(cx, switch (err) {
                error.AccessDenied => "You are not allowed to look in this folder",
                error.NotFound => "This folder is not there any more",
                else => "This folder cannot be opened",
            })
        else if (b.listing.entries.len == 0)
            message(cx, "This folder is empty")
        else switch (b.layout) {
            // Only the tiles or rows that show are made (a folder can have
            // a thousand items). Another folder, or the other layout,
            // starts again at the top.
            .icons => cx.make(ui.ScrollView{ .child = cx.make(ui.Padding{ .padding = .all(16), .child = cx.make(ui.LazyGrid{
                .count = b.listing.entries.len,
                .cell = .{ .w = 128, .h = 124 },
                .spacing = 8,
                .item = .of(self, Files.tile),
            }) }) }).withKey(pathKey(b.path)),
            .list => cx.make(ui.Column{ .cross_axis_alignment = .stretch, .children = &.{
                listHeader(cx, self.showModified()),
                divider(cx, .horizontal),
                cx.make(ui.Expanded{ .child = cx.make(ui.ScrollView{ .child = cx.make(ui.Padding{ .padding = .symmetric(8, 4), .child = cx.make(ui.LazyGrid{
                    .count = b.listing.entries.len,
                    .cell = .{ .w = std.math.inf(f32), .h = list_row_height },
                    .item = .of(self, Files.listRow),
                }) }) }).withKey(pathKey(b.path) +% 1) }),
            } }),
        };

        const footer = cx.make(ui.Padding{ .padding = .symmetric(16, 10), .child = self.bottomLine(cx) });

        return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .children = &.{
            cx.make(ui.TitleBar{
                .title = "Files",
                .on_close = self.on_close,
                .on_maximize = self.on_maximize,
                .on_drag = self.on_drag,
                .maximized = self.maximized,
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
            .on_press = callback(cx, .{ .browser = b, .index = i }, Act.activate),
        });
    }

    /// Whether the list has room for when items were changed (the names
    /// come first).
    fn showModified(self: *const Files) bool {
        return self.width >= 900;
    }

    /// The list's row for the open folder's item `i`.
    fn listRow(self: *const Files, cx: *ui.Context, i: usize) ui.Widget {
        const b = self.browser;
        const e = b.listing.entries[i];
        var size_buf: [32]u8 = undefined;
        var time_buf: [32]u8 = undefined;
        return cx.make(ListRow{
            .entry = e,
            .modified = if (self.showModified()) cx.fmt("{s}", .{fs.formatTime(&time_buf, e.modified, self.now)}) else null,
            .size = if (e.kind == .file or e.kind == .program) cx.fmt("{s}", .{fs.formatSize(&size_buf, e.size)}) else "",
            .selected = b.selected == i,
            .on_press = callback(cx, .{ .browser = b, .index = i }, Act.activate),
        });
    }

    /// The line at the bottom: about the item picked (or what is in the
    /// folder) with the buttons to make a folder and delete the item; or
    /// asking for the new folder's name, or whether to delete the item.
    fn bottomLine(self: *const Files, cx: *ui.Context) ui.Widget {
        const t = cx.theme();
        const b = self.browser;
        // In a narrow window, the buttons are their icons alone.
        const labels = self.width >= 1000;
        const note_style: ui.TextStyle = .{ .size = 16, .color = t.on_surface_variant };
        const failure_style: ui.TextStyle = .{ .size = 16, .color = t.@"error" };
        const cancel = cx.make(ui.OutlinedButton{ .label = if (labels) "Cancel" else "", .icon = .close, .on_press = callback(cx, .{ .browser = b }, Act.cancel) });
        switch (b.prompt) {
            .none => return cx.make(ui.Row{ .spacing = 12, .children = &.{
                cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = self.status(cx), .style = note_style, .wrap = false, .ellipsis = true }) }),
                cx.make(ui.OutlinedButton{
                    .label = if (labels) "New folder" else "",
                    .icon = .create_new_folder,
                    .on_press = if (b.file == null and b.changeable()) callback(cx, .{ .browser = b }, Act.newFolder) else null,
                }),
                cx.make(ui.OutlinedButton{
                    .label = if (labels) "Delete" else "",
                    .icon = .delete,
                    .on_press = if (b.picked() != null and b.changeable()) callback(cx, .{ .browser = b }, Act.askDelete) else null,
                }),
            } }),
            .new_folder => return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .spacing = 8, .children = &.{
                if (b.failure) |why|
                    cx.make(ui.Text{ .text = cx.fmt("The folder cannot be made: {s}", .{why}), .style = failure_style, .wrap = false, .ellipsis = true })
                else
                    cx.make(ui.Text{ .text = "The new folder's name", .style = note_style, .wrap = false, .ellipsis = true }),
                cx.make(ui.Row{ .spacing = 12, .children = &.{
                    cx.make(ui.Expanded{ .child = cx.make(ui.TextField{
                        .placeholder = "Name",
                        .width = std.math.inf(f32),
                        .max_len = ui.TextField.capacity,
                        .autofocus = true,
                        .on_changed = nameCallback(cx, b),
                        .on_submit = callback(cx, .{ .browser = b }, Act.make),
                    }) }),
                    cx.make(ui.OutlinedButton{ .label = if (labels) "Make" else "", .icon = .check, .on_press = callback(cx, .{ .browser = b }, Act.make) }),
                    cancel,
                } }),
            } }),
            .delete => {
                const e = b.picked() orelse return cx.make(ui.Empty{});
                // A folder goes with everything in it, and says so.
                const contents = e.kind == .folder and !e.link and b.delete_count != 0;
                const question = if (e.kind == .folder and !e.link) (if (b.delete_count) |n| switch (n) {
                    0 => cx.fmt("Delete the empty folder \u{201c}{s}\u{201d}?", .{e.name}),
                    1 => cx.fmt("Delete the folder \u{201c}{s}\u{201d} and the 1 item in it? This cannot be undone.", .{e.name}),
                    else => cx.fmt("Delete the folder \u{201c}{s}\u{201d} and everything in it ({d} items)? This cannot be undone.", .{ e.name, n }),
                } else cx.fmt("Delete the folder \u{201c}{s}\u{201d} and everything in it? This cannot be undone.", .{e.name})) else if (e.link)
                    cx.fmt("Delete the link \u{201c}{s}\u{201d}? What it leads to is kept.", .{e.name})
                else
                    cx.fmt("Delete \u{201c}{s}\u{201d}? This cannot be undone.", .{e.name});
                return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .spacing = 8, .children = &.{
                    cx.make(ui.Row{ .spacing = 8, .children = if (contents) &.{
                        cx.make(ui.Icon{ .icon = .warning, .size = 20, .color = t.@"error" }),
                        cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = question, .style = failure_style }) }),
                    } else &.{
                        cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = question, .style = .{ .size = 16 } }) }),
                    } }),
                    cx.make(ui.Row{ .spacing = 12, .children = &.{
                        cx.make(ui.Expanded{ .child = if (b.failure) |why|
                            cx.make(ui.Text{ .text = cx.fmt("It cannot be deleted: {s}", .{why}), .style = failure_style, .wrap = false, .ellipsis = true })
                        else
                            cx.make(ui.Empty{}) }),
                        cx.make(ui.OutlinedButton{ .label = if (labels) "Delete" else "", .icon = .delete, .on_press = callback(cx, .{ .browser = b }, Act.delete) }),
                        cancel,
                    } }),
                } });
            },
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
            .user_files = item.depth == 0 and std.mem.eql(u8, item.path, b.user_files),
            .selected = selected,
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

    fn reorder(a: *const Act) void {
        a.browser.request(.{ .order = if (a.browser.order == .name) .newest else .name });
    }

    fn relayout(a: *const Act) void {
        a.browser.request(.{ .layout = if (a.browser.layout == .icons) .list else .icons });
    }

    fn newFolder(a: *const Act) void {
        a.browser.request(.{ .prompt = .new_folder });
    }

    fn askDelete(a: *const Act) void {
        a.browser.request(.{ .prompt = .delete });
    }

    fn cancel(a: *const Act) void {
        a.browser.request(.{ .prompt = .none });
    }

    fn make(a: *const Act) void {
        a.browser.request(.make_folder);
    }

    fn delete(a: *const Act) void {
        a.browser.request(.delete);
    }
};

/// The new folder's name goes to the browser as it is typed.
fn nameCallback(cx: *ui.Context, b: *Browser) ?ui.ValueCallback([]const u8) {
    const p = cx.ui.arena().create(Act) catch return null;
    p.* = .{ .browser = b };
    return .of(p, struct {
        fn set(a: *const Act, text: []const u8) void {
            a.browser.setName(text);
        }
    }.set);
}

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

fn message(cx: *ui.Context, text: []const u8) ui.Widget {
    return cx.make(ui.Center{ .child = cx.make(ui.Padding{ .padding = .all(24), .child = cx.make(ui.Text{
        .text = text,
        .style = .{ .size = 20, .color = cx.theme().on_surface_variant },
        .text_align = .center,
    }) }) });
}

fn divider(cx: *ui.Context, axis: ui.Axis) ui.Widget {
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
    user_files: bool = false,
    selected: bool,
    on_open: ?ui.Callback,
    on_toggle: ?ui.Callback,

    pub const State = struct {
        interaction: ui.Interaction = .{},
    };

    pub fn build(self: *const TreeRow, cx: *ui.Context, state: *State) ui.Widget {
        const t = cx.theme();
        const height = 40;
        const highlight: ?gfx.Color = if (self.selected) t.secondary_container else if (state.interaction.hovered) t.on_surface.withAlpha(0.08) else null;
        const arrow = if (self.expandable)
            cx.make(Disclosure{ .expanded = self.expanded, .size = 28, .on_press = self.on_toggle })
        else
            cx.make(ui.SizedBox{ .width = 28, .height = 28 });
        const icon = cx.make(FileIcon{ .kind = .folder, .icon = if (self.user_files) .person else null, .size = 24 });
        const name = cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = self.label, .style = .{ .size = 17 }, .wrap = false, .ellipsis = true }) });
        return cx.make(ui.Pressable{ .on_press = self.on_open, .interaction = &state.interaction, .child = cx.make(ui.Decorated{
            .color = highlight,
            .radius = .all(height / 2),
            .child = cx.make(ui.SizedBox{ .height = height, .child = cx.make(ui.Padding{
                .padding = .{ .left = @round(4 + @as(f32, @floatFromInt(@min(self.depth, 16))) * 18), .right = 12 },
                .child = cx.make(ui.Row{ .spacing = 6, .children = if (self.locked)
                    &.{ arrow, icon, name, cx.make(ui.Icon{ .icon = .lock, .size = 18, .color = t.on_surface_variant }) }
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
    on_press: ?ui.Callback,

    pub const State = struct {
        interaction: ui.Interaction = .{},
    };

    pub fn build(self: *const Tile, cx: *ui.Context, state: *State) ui.Widget {
        const t = cx.theme();
        const highlight: ?gfx.Color = if (self.selected) t.secondary_container else if (state.interaction.hovered) t.on_surface.withAlpha(0.08) else null;
        return cx.make(ui.Pressable{ .on_press = self.on_press, .interaction = &state.interaction, .child = cx.make(ui.Decorated{
            .color = highlight,
            .radius = .all(12),
            .child = cx.make(ui.Padding{ .padding = .all(8), .child = cx.make(ui.Column{ .spacing = 6, .children = &.{
                cx.make(ui.Expanded{ .child = cx.make(ui.Center{ .child = cx.make(FileIcon{ .kind = self.entry.kind, .link = self.entry.link, .locked = self.entry.kind == .folder and !self.entry.writable, .size = 64 }) }) }),
                cx.make(ui.Text{ .text = self.entry.name, .style = .{ .size = 15 }, .text_align = .center, .wrap = false, .ellipsis = true }),
            } }) }),
        }) });
    }
};

const list_row_height = 40;
/// The list's columns' widths, after the name's.
const modified_width = 140;
const size_width = 90;

/// The list's column titles.
fn listHeader(cx: *ui.Context, modified: bool) ui.Widget {
    const style: ui.TextStyle = .{ .size = 14, .color = cx.theme().on_surface_variant };
    return cx.make(ui.Padding{ .padding = .symmetric(20, 8), .child = cx.make(ui.Row{ .spacing = 12, .children = &.{
        cx.make(ui.SizedBox{ .width = 24 }),
        cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = "Name", .style = style, .wrap = false, .ellipsis = true }) }),
        if (modified) cx.make(ui.SizedBox{ .width = modified_width, .child = cx.make(ui.Text{ .text = "Modified", .style = style, .wrap = false }) }) else cx.make(ui.Empty{}),
        cx.make(ui.SizedBox{ .width = size_width, .child = cx.make(ui.Text{ .text = "Size", .style = style, .wrap = false, .text_align = .end }) }),
    } }) });
}

/// An item in the list: its icon, name, when it was changed (if there is
/// room) and its size (for files); pressing it does what pressing its tile
/// does.
pub const ListRow = struct {
    entry: fs.Entry,
    modified: ?[]const u8,
    size: []const u8,
    selected: bool,
    on_press: ?ui.Callback,

    pub const State = struct {
        interaction: ui.Interaction = .{},
    };

    pub fn build(self: *const ListRow, cx: *ui.Context, state: *State) ui.Widget {
        const t = cx.theme();
        const highlight: ?gfx.Color = if (self.selected) t.secondary_container else if (state.interaction.hovered) t.on_surface.withAlpha(0.08) else null;
        const detail: ui.TextStyle = .{ .size = 15, .color = t.on_surface_variant };
        return cx.make(ui.Pressable{ .on_press = self.on_press, .interaction = &state.interaction, .child = cx.make(ui.Decorated{
            .color = highlight,
            .radius = .all(list_row_height / 2),
            .child = cx.make(ui.Padding{ .padding = .symmetric(12, 0), .child = cx.make(ui.Row{ .spacing = 12, .cross_axis_alignment = .center, .children = &.{
                cx.make(FileIcon{ .kind = self.entry.kind, .link = self.entry.link, .locked = self.entry.kind == .folder and !self.entry.writable, .size = 24 }),
                cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = self.entry.name, .style = .{ .size = 16 }, .wrap = false, .ellipsis = true }) }),
                if (self.modified) |m| cx.make(ui.SizedBox{ .width = modified_width, .child = cx.make(ui.Text{ .text = m, .style = detail, .wrap = false, .ellipsis = true }) }) else cx.make(ui.Empty{}),
                cx.make(ui.SizedBox{ .width = size_width, .child = cx.make(ui.Text{ .text = self.size, .style = detail, .wrap = false, .text_align = .end }) }),
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
    u.pointerButton(p, ui.btn_left, true);
    u.pointerButton(p, ui.btn_left, false);
}

/// The sizes to lay out at: the smallest the window may be, as narrow
/// and as short as it may be, a restored window's first size on a 1080p
/// screen, and maximized on a 720p and a 1080p screen. Everything is the
/// same size in pixels in each.
const test_sizes = [_][2]u32{
    min_size,
    .{ min_size[0], 1036 },
    .{ 1920, min_size[1] },
    .{ 960, 518 },
    .{ 1280, 668 },
    .{ 1920, 1036 },
};

test "the tree and the grid fit, from the smallest window to the biggest" {
    var t: fs.TestTree = .{};
    try t.init();
    defer t.deinit();
    var b = try Browser.init(testing.allocator, t.path);
    defer b.deinit();
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    for (test_sizes) |size| {
        u.frame(size[0], size[1], 0, Files{ .browser = &b, .width = @floatFromInt(size[0]) });
        try testing.expect(!overflows(u.root.?));
    }
    // The tree: the user's files and its folders, and nothing above it; the switch for
    // the system's files.
    try testing.expect(findText(u.root.?, "User files") != null);
    try testing.expect(findText(u.root.?, "z-link") != null);
    try testing.expect(findText(u.root.?, "tmp") == null);
    try testing.expect(findText(u.root.?, "System files") != null);
    // Fits with them shown, too.
    try b.showSystem(true);
    for (test_sizes) |size| {
        u.frame(size[0], size[1], 0, Files{ .browser = &b, .width = @floatFromInt(size[0]) });
        try testing.expect(!overflows(u.root.?));
    }
    // The grid, and how many items there are.
    try testing.expect(findText(u.root.?, "b-file") != null);
    try testing.expect(findText(u.root.?, "5 items") != null);

    // A file shown fits too: text, and bytes (as many a row as fit).
    b.request(.{ .activate = 2 });
    _ = b.apply();
    try testing.expect(b.file.?.kind == .text);
    for (test_sizes) |size| {
        u.frame(size[0], size[1], 0, Files{ .browser = &b, .width = @floatFromInt(size[0]) });
        try testing.expect(!overflows(u.root.?));
    }
    try b.showSystem(true);
    try b.open("/proc/self");
    for (b.listing.entries, 0..) |e, i| if (std.mem.eql(u8, e.name, "auxv")) b.request(.{ .activate = i });
    _ = b.apply();
    try testing.expect(b.file.?.kind == .binary);
    for (test_sizes) |size| {
        u.frame(size[0], size[1], 0, Files{ .browser = &b, .width = @floatFromInt(size[0]) });
        try testing.expect(!overflows(u.root.?));
        try testing.expect(findType(u.root.?, viewer.HexRow) != null);
    }
    // Back to the user's files, the folder.
    try b.showSystem(false);

    // Folders that cannot be changed have a lock, in the tree and the grid.
    try b.showSystem(false);
    u.frame(1600, 900, 0, Files{ .browser = &b });
    try testing.expect(findIcon(u.root.?, .lock) == null);
    b.listing.entries[0].writable = false;
    b.expanded.getPtr(t.path).?.entries[0].writable = false;
    u.frame(1600, 900, 0, Files{ .browser = &b });
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
            uu.frame(1600, 900, n.*, Files{ .browser = bb });
        }
    }.draw;
    Frame(u, &b, &now);

    // A file is shown in place of the grid, with what it holds under its
    // path, and the line at the bottom says what it is; Up goes back.
    click(u, tile(u, "b-file").?);
    Frame(u, &b, &now);
    try testing.expectEqual(@as(?usize, 2), b.selected);
    try testing.expect(findText(u.root.?, "b-file  ·  File  ·  5 bytes") != null);
    try testing.expect(findText(u.root.?, "hello") != null);
    try testing.expect(findText(u.root.?, "Text, 1 line") != null);
    var path_buf: [128]u8 = undefined;
    try testing.expect(findText(u.root.?, try std.fmt.bufPrint(&path_buf, "{s}/b-file", .{t.path})) != null);
    try testing.expect(!overflows(u.root.?));
    click(u, up(findText(u.root.?, "Up").?, ui.OutlinedButton).?);
    Frame(u, &b, &now);
    try testing.expect(b.file == null);
    try testing.expect(tile(u, "A-folder") != null);

    // A folder in the grid opens.
    click(u, tile(u, "A-folder").?);
    Frame(u, &b, &now);
    try testing.expect(std.mem.endsWith(u8, b.path, "/A-folder"));
    try testing.expect(findText(u.root.?, "This folder is empty") != null);

    // Up goes back, as far as the user's files (where it is disabled).
    click(u, up(findText(u.root.?, "Up").?, ui.OutlinedButton).?);
    Frame(u, &b, &now);
    try testing.expectEqualStrings(t.path, b.path);
    try testing.expect(up(findText(u.root.?, "Up").?, ui.OutlinedButton).?.widget.as(ui.OutlinedButton).?.on_press == null);

    // Only folders with folders in them have an arrow.
    try testing.expect(findDisclosure(up(findText(u.root.?, "A-folder").?, TreeRow).?) == null);
    try testing.expect(findDisclosure(up(findText(u.root.?, "z-link").?, TreeRow).?) == null);

    // The arrow closes the user's files in the tree (its folders go).
    const user_row = up(findText(u.root.?, "User files").?, TreeRow).?;
    try testing.expect(findText(user_row.parent.?, "z-link") != null);
    click(u, findDisclosure(user_row).?);
    Frame(u, &b, &now);
    try testing.expect(!b.isExpanded(t.path));
    try testing.expect(findText(up(findText(u.root.?, "User files").?, ui.ScrollView).?, "z-link") == null);

    // The switch shows the system's files: the tree starts at /, and a
    // folder above the user's files opens.
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
    // Off again: back to the user's files.
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

test "the order and the layout: the newest first, and a list" {
    var t: fs.TestTree = .{};
    try t.init();
    defer t.deinit();
    var b = try Browser.init(testing.allocator, t.path);
    defer b.deinit();
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    var n: u64 = 0;
    const Frame = struct {
        fn draw(uu: *ui.Ui, bb: *Browser, nn: *u64, size: [2]u32) void {
            _ = bb.apply();
            nn.* += 1;
            uu.frame(size[0], size[1], nn.*, Files{ .browser = bb, .now = 1791331200, .width = @floatFromInt(size[0]) });
        }
    }.draw;
    Frame(u, &b, &n, .{ 1600, 900 });
    // By name, as icons, to begin with; each button changes it.
    click(u, up(findText(u.root.?, "Name").?, ui.OutlinedButton).?);
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expectEqual(fs.Order.newest, b.order);
    try testing.expect(findText(u.root.?, "Newest") != null);
    click(u, up(findText(u.root.?, "Icons").?, ui.OutlinedButton).?);
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expectEqual(Layout.list, b.layout);

    // The list: its columns, and a row for each item with its size.
    try testing.expect(findText(u.root.?, "Modified") != null);
    try testing.expect(findType(u.root.?, Tile) == null);
    const row = up(findText(u.root.?, "b-file").?, ListRow).?;
    try testing.expect(findText(row, "5 bytes") != null);
    // Clicking a row picks (and shows) it, as a tile does.
    click(u, row);
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expectEqualStrings("b-file", b.listing.entries[b.selected.?].name);
    // While a file is shown, the order and layout stay as they are.
    try testing.expect(up(findText(u.root.?, "List").?, ui.OutlinedButton).?.widget.as(ui.OutlinedButton).?.on_press == null);
    b.request(.up);
    Frame(u, &b, &n, .{ 1600, 900 });
    for (test_sizes) |size| {
        Frame(u, &b, &n, size);
        try testing.expect(!overflows(u.root.?));
    }
    // A narrow window has no room for when items were changed.
    Frame(u, &b, &n, min_size);
    try testing.expect(findText(u.root.?, "Modified") == null);
    try testing.expect(findText(u.root.?, "b-file") != null);
    Frame(u, &b, &n, .{ 1600, 900 });
    // Back to icons.
    click(u, up(findText(u.root.?, "List").?, ui.OutlinedButton).?);
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expect(tile(u, "b-file") != null);
}

test "making a folder, and deleting: asked at the bottom, warning that a folder goes with what is in it" {
    var t: fs.TestTree = .{};
    try t.init();
    defer t.deinit();
    var b = try Browser.init(testing.allocator, t.path);
    defer b.deinit();
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    var n: u64 = 0;
    const Frame = struct {
        fn draw(uu: *ui.Ui, bb: *Browser, nn: *u64, size: [2]u32) void {
            _ = bb.apply();
            nn.* += 1;
            uu.frame(size[0], size[1], nn.*, Files{ .browser = bb, .width = @floatFromInt(size[0]) });
        }
    }.draw;
    Frame(u, &b, &n, .{ 1600, 900 });
    // Nothing picked: nothing to delete.
    const delete_button = up(findText(u.root.?, "Delete").?, ui.OutlinedButton).?;
    try testing.expect(delete_button.widget.as(ui.OutlinedButton).?.on_press == null);

    // New folder asks for a name, and the field takes the keyboard.
    click(u, up(findText(u.root.?, "New folder").?, ui.OutlinedButton).?);
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expect(findText(u.root.?, "The new folder's name") != null);
    for (test_sizes) |size| {
        Frame(u, &b, &n, size);
        try testing.expect(!overflows(u.root.?));
    }
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expect(u.focused != null and u.focused.?.widget.is(ui.TextField));
    // Typing a name and Enter makes the folder, which is picked.
    u.keyEvent(30, true);
    u.keyEvent(30, false);
    u.keyEvent(28, true);
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expectEqual(browser_mod.Prompt.none, b.prompt);
    try testing.expectEqualStrings("a", b.picked().?.name);
    try testing.expect(tile(u, "a") != null);

    // The name of something there already is not taken, and it says why.
    b.request(.{ .prompt = .new_folder });
    Frame(u, &b, &n, .{ 1600, 900 });
    u.keyEvent(30, true);
    u.keyEvent(28, true);
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expect(findText(u.root.?, "The folder cannot be made: there is already something with that name") != null);
    click(u, up(findText(u.root.?, "Cancel").?, ui.OutlinedButton).?);
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expectEqual(browser_mod.Prompt.none, b.prompt);

    // Deleting a folder with things in it warns that they go too.
    try t.write("a/one", "1", 0o644);
    try t.write("a/two", "2", 0o644);
    click(u, up(findText(u.root.?, "Delete").?, ui.OutlinedButton).?);
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expect(findText(u.root.?, "Delete the folder \u{201c}a\u{201d} and everything in it (2 items)? This cannot be undone.") != null);
    try testing.expect(findIcon(u.root.?, .warning) != null);
    for (test_sizes) |size| {
        Frame(u, &b, &n, size);
        try testing.expect(!overflows(u.root.?));
    }
    Frame(u, &b, &n, .{ 1600, 900 });
    // The prompt's Delete button (the one beside Cancel).
    const cancel = up(findText(u.root.?, "Cancel").?, ui.OutlinedButton).?;
    const row = cancel.parent.?;
    click(u, row.children.items[row.children.items.len - 2]);
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expect(tile(u, "a") == null);
    try testing.expect(findText(u.root.?, "5 items") != null);

    // An empty folder, a file and a link say so, without the warning.
    try testing.expectEqualStrings("z-link", b.listing.entries[1].name);
    b.selected = 1;
    b.request(.{ .prompt = .delete });
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expect(findText(u.root.?, "Delete the link \u{201c}z-link\u{201d}? What it leads to is kept.") != null);
    try testing.expect(findIcon(u.root.?, .warning) == null);
    b.selected = 0;
    b.request(.{ .prompt = .delete });
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expect(findText(u.root.?, "Delete the empty folder \u{201c}A-folder\u{201d}?") != null);
    b.selected = 2;
    b.request(.{ .prompt = .delete });
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expect(findText(u.root.?, "Delete \u{201c}b-file\u{201d}? This cannot be undone.") != null);
}
