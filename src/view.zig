//! The Files window, as widgets: the title bar, and under it the tree of
//! folders on the left and the open folder on the right: its path (with a
//! button to go up, and buttons for the order of its items and how they
//! are shown), what is in it as a grid of icons or a list (with when each
//! was changed, and its size), and a line about the item picked (or how
//! many there are), with buttons to make a folder and to delete the item
//! picked. The tree and the items scroll.
//!
//! USB drives are in the tree under the user's files, each with a button
//! to eject it (see browser.zig).
//!
//! Items are copied, cut and pasted from a menu (the right button, or a
//! touch held down: on an item, or on the folder around them) or with
//! Ctrl+C, Ctrl+X and Ctrl+V; and dragged onto a folder (among the items,
//! or in the tree) to move them there (to copy them there, with Ctrl
//! held, or if the folder is on another drive). While something is copied,
//! the line at the bottom says how far it has got.
//!
//! Clicking a folder in the tree or among the items opens it; the arrow
//! beside a folder in the tree opens or closes it there. Clicking anything
//! else among the items picks it.
//!
//! Making a folder asks for its name in the line at the bottom, and
//! deleting asks whether to there too, warning that a folder goes with
//! everything in it.

const std = @import("std");
const kete = @import("kete");
const kete_vc4 = @import("kete_vc4");
const sys = @import("sys");
const locale = @import("locale");
const gfx = kete.gfx;
const fs = @import("fs.zig");
const browser_mod = @import("browser.zig");
const viewer = @import("viewer.zig");

const Browser = browser_mod.Browser;
const Layout = browser_mod.Layout;

/// The smallest the window may be: the tree, and two columns of the
/// grid beside it. Everything is the same size in pixels whatever the
/// window's size; a bigger window shows more.
pub const min_size = [2]u32{ 640, 420 };

/// The size the window opens at: the folder tree beside a few columns of files.
pub const open_size = [2]u32{ 1024, 680 };

/// The most rows the tree shows.
pub const max_tree_rows = 2000;

pub const Files = struct {
    browser: *Browser,
    /// The title bar's buttons (close, and maximize, which shows whether
    /// the window is), and pressing the bar (to move the window).
    /// The window's width (a file's bytes are shown as many a row as fit).
    width: f32 = 1600,
    /// The time now, in seconds since 1970 (when items were changed is
    /// shown against it).
    now: i64 = 0,

    pub fn build(self: *const Files, cx: *kete.BuildContext) kete.Widget {
        const t = cx.theme();
        const b = self.browser;

        // The folders in the tree; rows are made only for those that show.
        var items: std.ArrayList(TreeItem) = .empty;
        const root = b.root();
        self.treeItems(cx, &items, root, if (std.mem.eql(u8, root, b.user_files)) "User files" else root, null, !fs.writable(root), 0);
        // The USB drives (with the system's files, they are in /media).
        if (!b.show_system) for (b.drives.entries) |e| {
            if (e.kind != .folder or e.link) continue;
            const path = fs.join(cx.arena, b.media_dir, e.name) catch break;
            self.treeItems(cx, &items, path, e.name, e.subfolders, !e.writable, 0);
        };
        const open_row: ?usize = for (items.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.path, b.path)) break i;
        } else null;
        const rows = cx.make(kete_vc4.LazyGrid{
            .count = items.items.len,
            .cell = .{ .w = std.math.inf(f32), .h = 40 },
            .item = .of(makeTree(cx, self, items.items), Tree.row),
            // The open folder's row is made even when it does not show, for
            // the tree to scroll to it.
            .keep = open_row,
        });
        const tree = cx.make(kete.SizedBox{
            .width = 300,
            .child = cx.make(kete.RoundedBox{
                .color = t.surface_container,
                .child = cx.make(kete.Column{
                    .cross_axis_alignment = .stretch,
                    .children = &.{
                        // The open folder's row comes into view when it changes.
                        cx.make(kete.Expanded{ .child = cx.make(kete.ScrollView{ .reveal = pathKey(b.path), .child = cx.make(kete.Padding{
                            .padding = .symmetric(8, 8),
                            .child = rows,
                        }) }) }),
                        cx.make(kete.HorizontalDivider{}),
                        // Whether the system's files are shown, or only the
                        // user's.
                        cx.make(kete.Padding{ .padding = .symmetric(16, 8), .child = cx.make(kete.SwitchRow{
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
        const file_path = b.filePath(cx.arena);
        const path_text = cx.make(kete.Text{ .text = file_path orelse b.path, .style = .{ .size = 20 }, .wrap = false, .ellipsis = true });
        const description: ?[]const u8 = if (b.file) |*f| (if (f.err == null) viewer.describe(cx, f) else null) else if (b.driveAt(b.path) != null) driveSpace(cx, b.path) else fs.describe(b.path);
        const about = if (description) |d| cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 2, .children = &.{
            path_text,
            cx.make(kete.Text{ .text = d, .style = .{ .size = 15, .color = t.on_surface_variant }, .wrap = false, .ellipsis = true }),
        } }) else path_text;
        // The order of the items and how they are shown, each a button
        // saying which, that changes it (not while a file is shown); in a
        // narrow window, by their icons alone.
        const folder = b.file == null;
        const labels = self.width >= 1000;
        const order_button = cx.make(kete.OutlinedButton{
            .label = if (!labels) "" else if (b.order == .name) "Name" else "Newest",
            .icon = if (b.order == .name) .sort_by_alpha else .schedule,
            .on_press = if (folder) callback(cx, .{ .browser = b }, Act.reorder) else null,
        });
        const layout_button = cx.make(kete.OutlinedButton{
            .label = if (!labels) "" else if (b.layout == .icons) "Icons" else "List",
            .icon = if (b.layout == .icons) .grid_view else .view_list,
            .on_press = if (folder) callback(cx, .{ .browser = b }, Act.relayout) else null,
        });
        const header = cx.make(kete.Padding{ .padding = .symmetric(16, 12), .child = cx.make(kete.Row{ .spacing = 16, .children = &.{
            cx.make(kete.OutlinedButton{ .label = "Up", .icon = .arrow_upward, .on_press = if (at_root) null else callback(cx, .{ .browser = b }, Act.up) }),
            cx.make(kete.Expanded{ .child = about }),
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
            .icons => cx.make(kete.ScrollView{ .child = cx.make(kete.Padding{ .padding = .all(16), .child = cx.make(kete_vc4.LazyGrid{
                .count = b.listing.entries.len,
                .cell = .{ .w = 128, .h = 124 },
                .spacing = 8,
                .item = .of(self, Files.tile),
            }) }) }).withKey(pathKey(b.path)),
            .list => cx.make(kete.Column{ .cross_axis_alignment = .stretch, .children = &.{
                listHeader(cx, self.showModified()),
                cx.make(kete.HorizontalDivider{}),
                cx.make(kete.Expanded{ .child = cx.make(kete.ScrollView{ .child = cx.make(kete.Padding{ .padding = .symmetric(8, 4), .child = cx.make(kete_vc4.LazyGrid{
                    .count = b.listing.entries.len,
                    .cell = .{ .w = std.math.inf(f32), .h = list_row_height },
                    .item = .of(self, Files.listRow),
                }) }) }).withKey(pathKey(b.path) +% 1) }),
            } }),
        };

        const footer = cx.make(kete.Padding{ .padding = .symmetric(16, 10), .child = self.bottomLine(cx) });

        return cx.make(kete.Column{ .cross_axis_alignment = .stretch, .children = &.{
            cx.make(kete.Expanded{ .child = cx.make(kete.Row{ .cross_axis_alignment = .stretch, .children = &.{
                tree,
                cx.make(kete.VerticalDivider{}),
                cx.make(kete.Expanded{ .child = cx.make(kete.Column{ .cross_axis_alignment = .stretch, .children = &.{
                    header,
                    cx.make(kete.HorizontalDivider{}),
                    cx.make(kete.Expanded{ .child = cx.make(kete.Snackbar{
                        .message = b.notice() orelse "",
                        .on_dismiss = callback(cx, .{ .browser = b }, Act.dismissNotice),
                        .child = cx.make(MenuArea{ .browser = b, .child = content }),
                    }) }),
                    cx.make(kete.HorizontalDivider{}),
                    footer,
                } }) }),
            } }) }),
        } });
    }

    /// The folder at `path` in the tree, and the folders in it if it is
    /// open. `subfolders` is whether there are folders in it, if known;
    /// `locked`, whether it cannot be changed.
    fn treeItems(self: *const Files, cx: *kete.BuildContext, items: *std.ArrayList(TreeItem), path: []const u8, label: []const u8, subfolders: ?bool, locked: bool, depth: usize) void {
        const b = self.browser;
        if (items.items.len >= max_tree_rows) return;
        const a = cx.arena;
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
    fn tile(self: *const Files, cx: *kete.BuildContext, i: usize) kete.Widget {
        const b = self.browser;
        return cx.make(Tile{
            .browser = b,
            .index = i,
            .entry = b.listing.entries[i],
            .selected = b.selected == i,
            .on_press = callback(cx, .{ .browser = b, .index = i }, Act.activate),
            .on_drop = itemDrop(cx, b, i),
        });
    }

    /// Whether the list has room for when items were changed (the names
    /// come first).
    fn showModified(self: *const Files) bool {
        return self.width >= 900;
    }

    /// The list's row for the open folder's item `i`.
    fn listRow(self: *const Files, cx: *kete.BuildContext, i: usize) kete.Widget {
        const b = self.browser;
        const e = b.listing.entries[i];
        var size_buf: [32]u8 = undefined;
        var time_buf: [32]u8 = undefined;
        return cx.make(ListRow{
            .browser = b,
            .index = i,
            .on_drop = itemDrop(cx, b, i),
            .entry = e,
            .modified = if (self.showModified()) cx.fmt("{s}", .{locale.formatWhen(&time_buf, e.modified, self.now)}) else null,
            .size = if (e.kind == .file or e.kind == .program) cx.fmt("{s}", .{fs.formatSize(&size_buf, e.size)}) else "",
            .selected = b.selected == i,
            .on_press = callback(cx, .{ .browser = b, .index = i }, Act.activate),
        });
    }

    /// The line at the bottom: about the item picked (or what is in the
    /// folder) with the buttons to make a folder and delete the item; or
    /// asking for the new folder's name, or whether to delete the item.
    fn bottomLine(self: *const Files, cx: *kete.BuildContext) kete.Widget {
        const t = cx.theme();
        const b = self.browser;
        // In a narrow window, the buttons are their icons alone.
        const labels = self.width >= 1200;
        const note_style: kete.TextStyle = .{ .size = 16, .color = t.on_surface_variant };
        const failure_style: kete.TextStyle = .{ .size = 16, .color = t.@"error" };
        const cancel = cx.make(kete.OutlinedButton{ .label = if (labels) "Cancel" else "", .icon = .close, .on_press = callback(cx, .{ .browser = b }, Act.cancel) });
        // Copying: how far it has got, and a button to stop.
        if (b.copier) |c| {
            const verb = if (c.move) "Moving" else "Copying";
            var done_buf: [32]u8 = undefined;
            var total_buf: [32]u8 = undefined;
            const p = c.progress();
            const text = if (p.counting)
                cx.fmt("{s} \u{201c}{s}\u{201d}\u{2026}", .{ verb, c.name })
            else
                cx.fmt("{s} \u{201c}{s}\u{201d}: {s} of {s}", .{ verb, c.name, fs.formatSize(&done_buf, p.done), fs.formatSize(&total_buf, p.total) });
            return cx.make(kete.Row{ .spacing = 12, .children = &.{
                cx.make(kete.Spinner{ .size = 20 }),
                cx.make(kete.Expanded{ .child = cx.make(kete.Text{ .text = text, .style = note_style, .wrap = false, .ellipsis = true }) }),
                cx.make(kete.OutlinedButton{ .label = if (labels) "Stop" else "", .icon = .close, .on_press = callback(cx, .{ .browser = b }, Act.stopCopy) }),
            } });
        }
        switch (b.prompt) {
            .none => return cx.make(kete.Row{
                .spacing = if (labels) 12 else 8,
                .children = &.{
                    cx.make(kete.Expanded{ .child = cx.make(kete.Text{ .text = self.status(cx), .style = note_style, .wrap = false, .ellipsis = true }) }),
                    // What was copied or cut, while there is something.
                    if (b.clip_path != null) cx.make(kete.OutlinedButton{
                        .label = if (labels) "Paste" else "",
                        .icon = .content_paste,
                        .on_press = if (b.canPaste()) callback(cx, .{ .browser = b }, Act.paste) else null,
                    }) else cx.make(kete.SizedBox.empty),
                    if (b.canView()) cx.make(kete.OutlinedButton{
                        .label = if (labels) "View" else "",
                        .icon = .visibility,
                        .on_press = callback(cx, .{ .browser = b }, Act.view),
                    }) else cx.make(kete.SizedBox.empty),
                    // Text files, if there is an editor for them.
                    if (b.canEdit()) cx.make(kete.OutlinedButton{
                        .label = if (labels) "Edit" else "",
                        .icon = .edit,
                        .on_press = callback(cx, .{ .browser = b }, Act.edit),
                    }) else cx.make(kete.SizedBox.empty),
                    if (b.editor() != null) cx.make(kete.OutlinedButton{
                        .label = if (labels) "New text file" else "",
                        .icon = .note_add,
                        .on_press = if (b.file == null and b.changeable()) callback(cx, .{ .browser = b }, Act.newTextFile) else null,
                    }) else cx.make(kete.SizedBox.empty),
                    cx.make(kete.OutlinedButton{
                        .label = if (labels) "New folder" else "",
                        .icon = .create_new_folder,
                        .on_press = if (b.file == null and b.changeable()) callback(cx, .{ .browser = b }, Act.newFolder) else null,
                    }),
                    cx.make(kete.OutlinedButton{
                        .label = if (labels) "Delete" else "",
                        .icon = .delete,
                        .destructive = true,
                        .on_press = if (b.picked() != null and b.changeable()) callback(cx, .{ .browser = b }, Act.askDelete) else null,
                    }),
                },
            }),
            .new_folder, .new_text_file => |p| return cx.make(kete.Column{ .cross_axis_alignment = .stretch, .spacing = 8, .children = &.{
                if (b.failure) |why|
                    cx.make(kete.Text{ .text = cx.fmt("The {s} cannot be made: {s}", .{ if (p == .new_folder) "folder" else "file", why }), .style = failure_style, .wrap = false, .ellipsis = true })
                else
                    cx.make(kete.Text{ .text = if (p == .new_folder) "The new folder's name" else "The new text file's name (.txt is added if it has no ending)", .style = note_style, .wrap = false, .ellipsis = true }),
                cx.make(kete.Row{ .spacing = 12, .children = &.{
                    cx.make(kete.Expanded{ .child = cx.make(kete.TextField{
                        .placeholder = "Name",
                        .width = std.math.inf(f32),
                        .max_len = kete.TextField.capacity,
                        .autofocus = true,
                        .on_changed = nameCallback(cx, b),
                        .on_submit = callback(cx, .{ .browser = b }, Act.make),
                    }) }),
                    cx.make(kete.OutlinedButton{ .label = if (labels) "Make" else "", .icon = .check, .on_press = callback(cx, .{ .browser = b }, Act.make) }),
                    cancel,
                } }),
            } }),
            .delete => {
                const e = b.picked() orelse return cx.make(kete.SizedBox.empty);
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
                return cx.make(kete.Column{ .cross_axis_alignment = .stretch, .spacing = 8, .children = &.{
                    cx.make(kete.Row{ .spacing = 8, .children = if (contents) &.{
                        cx.make(kete.Icon{ .icon = .warning, .size = 20, .color = t.@"error" }),
                        cx.make(kete.Expanded{ .child = cx.make(kete.Text{ .text = question, .style = failure_style }) }),
                    } else &.{
                        cx.make(kete.Expanded{ .child = cx.make(kete.Text{ .text = question, .style = .{ .size = 16 } }) }),
                    } }),
                    cx.make(kete.Row{ .spacing = 12, .children = &.{
                        cx.make(kete.Expanded{ .child = if (b.failure) |why|
                            cx.make(kete.Text{ .text = cx.fmt("It cannot be deleted: {s}", .{why}), .style = failure_style, .wrap = false, .ellipsis = true })
                        else
                            cx.make(kete.SizedBox.empty) }),
                        cx.make(kete.OutlinedButton{ .label = if (labels) "Delete" else "", .icon = .delete, .destructive = true, .on_press = callback(cx, .{ .browser = b }, Act.delete) }),
                        cancel,
                    } }),
                } });
            },
        }
    }

    /// About the item picked, or what is in the folder.
    fn status(self: *const Files, cx: *kete.BuildContext) []const u8 {
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

    fn row(t: *const Tree, cx: *kete.BuildContext, i: usize) kete.Widget {
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
            .drive = b.driveAt(item.path) != null,
            .on_eject = if (b.driveAt(item.path)) |name| callback(cx, .{ .browser = b, .path = name }, Act.eject) else null,
            .selected = selected,
            .on_open = callback(cx, .{ .browser = b, .path = item.path }, Act.open),
            .on_toggle = callback(cx, .{ .browser = b, .path = item.path }, Act.toggle),
            // What is dragged there goes there.
            .on_drop = if (item.locked) null else dropCallback(cx, b, item.path),
        });
        // The open folder's row has a key, for the tree to scroll to it.
        return if (selected) w.withKey(pathKey(item.path)) else w;
    }
};

fn makeTree(cx: *kete.BuildContext, files: *const Files, items: []const TreeItem) *const Tree {
    const t = cx.arena.create(Tree) catch {
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

    fn newTextFile(a: *const Act) void {
        a.browser.request(.{ .prompt = .new_text_file });
    }

    fn view(a: *const Act) void {
        a.browser.request(.view);
    }

    fn edit(a: *const Act) void {
        a.browser.request(.edit);
    }

    fn askDelete(a: *const Act) void {
        a.browser.request(.{ .prompt = .delete });
    }

    fn cancel(a: *const Act) void {
        a.browser.request(.{ .prompt = .none });
    }

    /// Makes the folder, or text file, named.
    fn make(a: *const Act) void {
        a.browser.request(if (a.browser.prompt == .new_text_file) .make_text_file else .make_folder);
    }

    fn delete(a: *const Act) void {
        a.browser.request(.delete);
    }

    fn eject(a: *const Act) void {
        a.browser.request(.{ .eject = a.path });
    }

    fn paste(a: *const Act) void {
        a.browser.request(.paste);
    }

    fn stopCopy(a: *const Act) void {
        a.browser.request(.cancel_copy);
    }

    fn dismissNotice(a: *const Act) void {
        a.browser.request(.dismiss_notice);
    }

    /// Something dragged (an item of the open folder) was dropped on the
    /// folder at `path`: copied there with Ctrl held, else moved.
    fn drop(a: *const Act, index: usize) void {
        a.browser.request(.{ .drop = .{ .index = index, .into = a.path, .copy = a.browser.ctrl_held } });
    }
};

/// The new folder's name goes to the browser as it is typed.
fn nameCallback(cx: *kete.BuildContext, b: *Browser) ?kete.ValueCallback([]const u8) {
    const p = cx.arena.create(Act) catch return null;
    p.* = .{ .browser = b };
    return .of(p, struct {
        fn set(a: *const Act, text: []const u8) void {
            a.browser.setName(text);
        }
    }.set);
}

fn systemCallback(cx: *kete.BuildContext, b: *Browser) ?kete.ValueCallback(bool) {
    const p = cx.arena.create(Act) catch return null;
    p.* = .{ .browser = b };
    return .of(p, struct {
        fn set(a: *const Act, on: bool) void {
            a.browser.request(.{ .show_system = on });
        }
    }.set);
}

/// What the folder at `path` does with what is dropped on it: it goes
/// there, if things can be put there (and nothing is being copied).
fn dropCallback(cx: *kete.BuildContext, b: *Browser, path: []const u8) ?kete.ValueCallback(usize) {
    if (b.copying() or !fs.writable(path)) return null;
    const p = cx.arena.create(Act) catch return null;
    p.* = .{ .browser = b, .path = path };
    return .of(p, Act.drop);
}

/// The drop callback of the open folder's item `i`, if it is a folder.
fn itemDrop(cx: *kete.BuildContext, b: *Browser, i: usize) ?kete.ValueCallback(usize) {
    const e = b.listing.entries[i];
    if (e.kind != .folder or !e.writable) return null;
    const path = fs.join(cx.arena, b.path, e.name) catch return null;
    return dropCallback(cx, b, path);
}

/// The menus' actions: on the browser (which lasts as long as a menu).
const MenuAct = struct {
    fn open(b: *Browser) void {
        if (b.selected) |i| b.request(.{ .activate = i });
    }
    fn copy(b: *Browser) void {
        b.request(.copy);
    }
    fn cut(b: *Browser) void {
        b.request(.cut);
    }
    fn paste(b: *Browser) void {
        b.request(.paste);
    }
    fn delete(b: *Browser) void {
        b.request(.{ .prompt = .delete });
    }
    fn newFolder(b: *Browser) void {
        b.request(.{ .prompt = .new_folder });
    }
    fn newTextFile(b: *Browser) void {
        b.request(.{ .prompt = .new_text_file });
    }
    fn view(b: *Browser) void {
        b.request(.view);
    }
    fn edit(b: *Browser) void {
        b.request(.edit);
    }
};

/// Shows a menu where it is asked for (the right button, or a touch held
/// down): for the open folder's item `index` (which it picks), or, with
/// none, for the folder.
const MenuArea = struct {
    browser: *Browser,
    index: ?usize = null,
    child: ?kete.Widget = null,

    pub fn event(self: *const MenuArea, n: *kete.WidgetNode, e: kete.Event) bool {
        const pos = switch (e) {
            .context => |p| p,
            else => return false,
        };
        const b = self.browser;
        if (b.copying()) return false;
        const origin = n.position();
        const at: kete.Point = .{ origin[0] + pos[0], origin[1] + pos[1] };
        const changeable = b.changeable();
        if (self.index) |i| {
            if (i >= b.listing.entries.len) return false;
            b.request(.{ .pick = i });
            // Text files can be edited, if there is an editor.
            const item = b.listing.entries[i];
            const viewable = item.kind == .file or item.kind == .program;
            const editable = b.editor() != null and item.kind == .file and fs.isTextFile(b.path, item.name);
            const first: kete.MenuItem = if (viewable)
                .{ .label = "View", .on_press = .of(b, MenuAct.view) }
            else
                .{ .label = "Open", .on_press = .of(b, MenuAct.open) };
            n.ui.openMenu(n, at, if (editable) &.{
                first,
                .{ .label = "Edit", .on_press = .of(b, MenuAct.edit) },
                .{ .label = "Copy", .shortcut = "Ctrl+C", .on_press = .of(b, MenuAct.copy) },
                .{ .label = "Cut", .shortcut = "Ctrl+X", .enabled = changeable, .on_press = .of(b, MenuAct.cut) },
                .{ .label = "Delete", .shortcut = "Delete", .destructive = true, .enabled = changeable, .on_press = .of(b, MenuAct.delete) },
            } else &.{
                first,
                .{ .label = "Copy", .shortcut = "Ctrl+C", .on_press = .of(b, MenuAct.copy) },
                .{ .label = "Cut", .shortcut = "Ctrl+X", .enabled = changeable, .on_press = .of(b, MenuAct.cut) },
                .{ .label = "Delete", .shortcut = "Delete", .destructive = true, .enabled = changeable, .on_press = .of(b, MenuAct.delete) },
            });
        } else {
            if (b.file != null) return false;
            n.ui.openMenu(n, at, if (b.editor() != null) &.{
                .{ .label = "Paste", .shortcut = "Ctrl+V", .enabled = b.canPaste(), .on_press = .of(b, MenuAct.paste) },
                .{ .label = "New folder", .enabled = changeable, .on_press = .of(b, MenuAct.newFolder) },
                .{ .label = "New text file", .enabled = changeable, .on_press = .of(b, MenuAct.newTextFile) },
            } else &.{
                .{ .label = "Paste", .shortcut = "Ctrl+V", .enabled = b.canPaste(), .on_press = .of(b, MenuAct.paste) },
                .{ .label = "New folder", .enabled = changeable, .on_press = .of(b, MenuAct.newFolder) },
            });
        }
        return true;
    }
};

fn callback(cx: *kete.BuildContext, act: Act, comptime f: fn (*const Act) void) ?kete.Callback {
    const p = cx.arena.create(Act) catch return null;
    p.* = act;
    return .of(p, f);
}

fn message(cx: *kete.BuildContext, text: []const u8) kete.Widget {
    return cx.make(kete.Align{ .child = cx.make(kete.Padding{ .padding = .all(24), .child = cx.make(kete.Text{
        .text = text,
        .style = .{ .size = 20, .color = cx.theme().on_surface_variant },
        .text_align = .center,
    }) }) });
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
    /// The user's files: a person rather than a folder.
    user_files: bool = false,
    /// A USB drive, with a button to eject it.
    drive: bool = false,
    on_eject: ?kete.Callback = null,
    on_drop: ?kete.ValueCallback(usize) = null,
    selected: bool,
    on_open: ?kete.Callback,
    on_toggle: ?kete.Callback,

    pub const State = struct {
        interaction: kete.PointerInteraction = .{},
    };

    pub fn build(self: *const TreeRow, cx: *kete.BuildContext, state: *State) kete.Widget {
        const t = cx.theme();
        const height = 40;
        const highlight: ?gfx.Color = if (self.selected) t.secondary_container else if (state.interaction.hovered) t.on_surface.withAlpha(0.08) else null;
        const arrow = if (self.expandable)
            cx.make(Disclosure{ .expanded = self.expanded, .size = 28, .on_press = self.on_toggle })
        else
            cx.make(kete.SizedBox{ .width = 28, .height = 28 });
        const icon = if (self.drive)
            cx.make(kete.SizedBox{ .width = 24, .height = 24, .child = cx.make(kete.Icon{ .icon = .usb, .size = 22, .color = t.primary }) })
        else
            cx.make(FileIcon{ .kind = .folder, .icon = if (self.user_files) .person else null, .size = 24 });
        const eject: ?kete.Widget = if (self.on_eject) |on| cx.make(kete.IconButton{ .icon = .eject, .size = 28, .icon_size = 21, .on_press = on }) else null;
        const name = cx.make(kete.Expanded{ .child = cx.make(kete.Text{ .text = self.label, .style = .{ .size = 17 }, .wrap = false, .ellipsis = true }) });
        return cx.make(kete.DropTarget{ .on_drop = self.on_drop, .radius = height / 2, .child = cx.make(kete.Pressable{ .on_press = self.on_open, .interaction = &state.interaction, .child = cx.make(kete.RoundedBox{
            .color = highlight,
            .radius = .all(height / 2),
            .child = cx.make(kete.SizedBox{ .height = height, .child = cx.make(kete.Padding{
                .padding = .{ .left = @round(4 + @as(f32, @floatFromInt(@min(self.depth, 16))) * 18), .right = 12 },
                .child = cx.make(kete.Row{ .spacing = 6, .children = if (eject) |e|
                    &.{ arrow, icon, name, e }
                else if (self.locked)
                    &.{ arrow, icon, name, cx.make(kete.Icon{ .icon = .lock, .size = 18, .color = t.on_surface_variant }) }
                else
                    &.{ arrow, icon, name } }),
            }) }),
        }) }) });
    }
};

/// The arrow beside a folder in the tree: right when closed, down when
/// open.
const Disclosure = struct {
    expanded: bool,
    size: f32,
    on_press: ?kete.Callback,

    pub fn build(self: *const Disclosure, cx: *kete.BuildContext) kete.Widget {
        return cx.make(kete.IconButton{
            .icon = if (self.expanded) .expand_more else .chevron_right,
            .size = self.size,
            .icon_size = @round(self.size * 0.75),
            .on_press = self.on_press,
        });
    }
};

/// What a USB drive holds: "USB drive · 1.2 GB free of 16.0 GB".
fn driveSpace(cx: *kete.BuildContext, path: []const u8) []const u8 {
    var z: [4096]u8 = undefined;
    const space = sys.diskSpace(std.mem.printSentinel(&z, "{s}", .{path}, 0) catch return "USB drive") orelse return "USB drive";
    var free_buf: [32]u8 = undefined;
    var total_buf: [32]u8 = undefined;
    return cx.fmt("USB drive  \u{b7}  {s} free of {s}", .{ fs.formatSize(&free_buf, space.free), fs.formatSize(&total_buf, space.total) });
}

/// An item in the grid: its icon with its name under it.
pub const Tile = struct {
    browser: *Browser,
    /// Its place in the open folder (what dragging it carries).
    index: usize,
    entry: fs.Entry,
    selected: bool,
    on_press: ?kete.Callback,
    /// A folder takes what is dropped on it.
    on_drop: ?kete.ValueCallback(usize) = null,

    pub const State = struct {
        interaction: kete.PointerInteraction = .{},
    };

    pub fn build(self: *const Tile, cx: *kete.BuildContext, state: *State) kete.Widget {
        const t = cx.theme();
        const highlight: ?gfx.Color = if (self.selected) t.secondary_container else if (state.interaction.hovered) t.on_surface.withAlpha(0.08) else null;
        const icon: FileIcon = .{ .kind = self.entry.kind, .link = self.entry.link, .locked = self.entry.kind == .folder and !self.entry.writable, .size = 64 };
        return folderItem(cx, self.browser, self.index, self.on_drop, 12, cx.make(kete.Draggable{
            .data = self.index,
            .label = self.entry.name,
            .icon = icon.glyph(),
            .on_press = self.on_press,
            .interaction = &state.interaction,
            .child = cx.make(kete.RoundedBox{
                .color = highlight,
                .radius = .all(12),
                .child = cx.make(kete.Padding{ .padding = .all(8), .child = cx.make(kete.Column{ .spacing = 6, .children = &.{
                    cx.make(kete.Expanded{ .child = cx.make(kete.Align{ .child = cx.make(icon) }) }),
                    cx.make(kete.Text{ .text = self.entry.name, .style = .{ .size = 15 }, .text_align = .center, .wrap = false, .ellipsis = true }),
                } }) }),
            }),
        }));
    }
};

const list_row_height = 40;
/// The list's columns' widths, after the name's.
const modified_width = 140;
const size_width = 90;

/// The list's column titles.
fn listHeader(cx: *kete.BuildContext, modified: bool) kete.Widget {
    const style: kete.TextStyle = .{ .size = 14, .color = cx.theme().on_surface_variant };
    return cx.make(kete.Padding{ .padding = .symmetric(20, 8), .child = cx.make(kete.Row{ .spacing = 12, .children = &.{
        cx.make(kete.SizedBox{ .width = 24 }),
        cx.make(kete.Expanded{ .child = cx.make(kete.Text{ .text = "Name", .style = style, .wrap = false, .ellipsis = true }) }),
        if (modified) cx.make(kete.SizedBox{ .width = modified_width, .child = cx.make(kete.Text{ .text = "Modified", .style = style, .wrap = false }) }) else cx.make(kete.SizedBox.empty),
        cx.make(kete.SizedBox{ .width = size_width, .child = cx.make(kete.Text{ .text = "Size", .style = style, .wrap = false, .text_align = .end }) }),
    } }) });
}

/// An item in the list: its icon, name, when it was changed (if there is
/// room) and its size (for files); pressing it does what pressing its tile
/// does.
pub const ListRow = struct {
    browser: *Browser,
    index: usize,
    on_drop: ?kete.ValueCallback(usize) = null,
    entry: fs.Entry,
    modified: ?[]const u8,
    size: []const u8,
    selected: bool,
    on_press: ?kete.Callback,

    pub const State = struct {
        interaction: kete.PointerInteraction = .{},
    };

    pub fn build(self: *const ListRow, cx: *kete.BuildContext, state: *State) kete.Widget {
        const t = cx.theme();
        const highlight: ?gfx.Color = if (self.selected) t.secondary_container else if (state.interaction.hovered) t.on_surface.withAlpha(0.08) else null;
        const detail: kete.TextStyle = .{ .size = 15, .color = t.on_surface_variant };
        const icon: FileIcon = .{ .kind = self.entry.kind, .link = self.entry.link, .locked = self.entry.kind == .folder and !self.entry.writable, .size = 24 };
        return folderItem(cx, self.browser, self.index, self.on_drop, list_row_height / 2, cx.make(kete.Draggable{ .data = self.index, .label = self.entry.name, .icon = icon.glyph(), .on_press = self.on_press, .interaction = &state.interaction, .child = cx.make(kete.RoundedBox{
            .color = highlight,
            .radius = .all(list_row_height / 2),
            .child = cx.make(kete.Padding{ .padding = .symmetric(12, 0), .child = cx.make(kete.Row{ .spacing = 12, .cross_axis_alignment = .center, .children = &.{
                cx.make(icon),
                cx.make(kete.Expanded{ .child = cx.make(kete.Text{ .text = self.entry.name, .style = .{ .size = 16 }, .wrap = false, .ellipsis = true }) }),
                if (self.modified) |m| cx.make(kete.SizedBox{ .width = modified_width, .child = cx.make(kete.Text{ .text = m, .style = detail, .wrap = false, .ellipsis = true }) }) else cx.make(kete.SizedBox.empty),
                cx.make(kete.SizedBox{ .width = size_width, .child = cx.make(kete.Text{ .text = self.size, .style = detail, .wrap = false, .text_align = .end }) }),
            } }) }),
        }) }));
    }
};

/// An item of the open folder (`body`, which can be dragged), with its
/// menu, taking what is dropped on it if it is a folder.
fn folderItem(cx: *kete.BuildContext, b: *Browser, index: usize, on_drop: ?kete.ValueCallback(usize), radius: f32, body: kete.Widget) kete.Widget {
    const target = if (on_drop != null) cx.make(kete.DropTarget{ .on_drop = on_drop, .radius = radius, .child = body }) else body;
    return cx.make(MenuArea{ .browser = b, .index = index, .child = target });
}

/// What an item is, as a Material icon (folders in the primary colour);
/// links get a badge in the corner, and folders that cannot be changed
/// (the system's) a lock in the other.
pub const FileIcon = struct {
    kind: fs.Kind,
    link: bool = false,
    locked: bool = false,
    size: f32,
    /// The icon instead of the kind's.
    icon: ?kete.IconName = null,

    pub fn glyph(self: *const FileIcon) kete.IconName {
        return self.icon orelse switch (self.kind) {
            .folder => .folder,
            .file => .description,
            .program => .terminal,
            .device => .memory,
            // A pipe or socket, or a link to nothing.
            .other => if (self.link) .link_off else .help_outline,
        };
    }

    pub fn build(self: *const FileIcon, cx: *kete.BuildContext) kete.Widget {
        const t = cx.theme();
        const main = cx.make(kete.Icon{ .icon = self.glyph(), .size = self.size, .color = if (self.kind == .folder) t.primary else t.on_surface_variant });
        const link = self.link and self.kind != .other;
        if (!link and !self.locked) return main;
        return cx.make(kete.SizedBox{ .width = self.size, .height = self.size, .child = cx.make(kete.Overlay{ .children = &.{
            main,
            if (link) self.badge(cx, .link, .bottom_left) else cx.make(kete.SizedBox.empty),
            if (self.locked) self.badge(cx, .lock, .bottom_right) else cx.make(kete.SizedBox.empty),
        } }) });
    }

    // The badges' icons, which kete's icon font is to have.
    comptime {
        _ = &[_]kete.IconName{ .link, .lock };
    }

    /// A small icon on a disc, in a corner.
    fn badge(self: *const FileIcon, cx: *kete.BuildContext, icon: kete.IconName, corner: kete.Alignment) kete.Widget {
        const t = cx.theme();
        const d = @round(self.size * 0.4);
        return cx.make(kete.Align{ .alignment = corner, .child = cx.make(kete.RoundedBox{
            .color = t.surface_container_highest,
            .radius = .all(d / 2),
            .child = cx.make(kete.SizedBox{ .width = d, .height = d, .child = cx.make(kete.Icon{ .icon = icon, .size = @round(d * 0.7), .color = t.on_surface }) }),
        }) });
    }
};

// --- Tests ---------------------------------------------------------------------

const testing = std.testing;
const font = kete.font;

fn overflows(node: *kete.WidgetNode) bool {
    if (node.overflow.any()) return true;
    for (node.children.items) |ch| if (overflows(ch)) return true;
    return false;
}

fn findText(n: *kete.WidgetNode, text: []const u8) ?*kete.WidgetNode {
    if (n.widget.as(kete.Text)) |t| if (std.mem.eql(u8, t.text, text)) return n;
    for (n.children.items) |ch| if (findText(ch, text)) |f| return f;
    return null;
}

/// The nearest node above `n` (or `n`) whose widget is a `T`.
fn up(n: *kete.WidgetNode, comptime T: type) ?*kete.WidgetNode {
    var at: ?*kete.WidgetNode = n;
    while (at) |a| : (at = a.parent) if (a.widget.is(T)) return a;
    return null;
}

fn click(u: *kete.ui.WindowUi, n: *kete.WidgetNode) void {
    const at = n.position();
    const p: kete.Point = .{ at[0] + n.size.w / 2, at[1] + n.size.h / 2 };
    u.pointerMotion(p);
    u.pointerButton(p, .left, true);
    u.pointerButton(p, .left, false);
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
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
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
    b.request(.view);
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
    b.request(.view);
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
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var now: u64 = 0;
    const Frame = struct {
        fn draw(uu: *kete.ui.WindowUi, bb: *Browser, n: *u64) void {
            _ = bb.apply();
            n.* += 1;
            uu.frame(1600, 900, n.*, Files{ .browser = bb });
        }
    }.draw;
    Frame(u, &b, &now);

    // Clicking a file picks it, showing View at the bottom; View shows
    // the file in place of the grid, and Up goes back.
    click(u, tile(u, "b-file").?);
    Frame(u, &b, &now);
    try testing.expectEqual(@as(?usize, 2), b.selected);
    try testing.expect(b.file == null);
    try testing.expect(findText(u.root.?, "b-file  ·  File  ·  5 bytes") != null);
    try testing.expect(findText(u.root.?, "View") != null);
    click(u, up(findText(u.root.?, "View").?, kete.OutlinedButton).?);
    Frame(u, &b, &now);
    try testing.expect(findText(u.root.?, "hello") != null);
    try testing.expect(findText(u.root.?, "Text, 1 line") != null);
    var path_buf: [128]u8 = undefined;
    try testing.expect(findText(u.root.?, try std.fmt.bufPrint(&path_buf, "{s}/b-file", .{t.path})) != null);
    try testing.expect(!overflows(u.root.?));
    click(u, up(findText(u.root.?, "Up").?, kete.OutlinedButton).?);
    Frame(u, &b, &now);
    try testing.expect(b.file == null);
    try testing.expect(tile(u, "A-folder") != null);

    // A folder in the grid opens.
    click(u, tile(u, "A-folder").?);
    Frame(u, &b, &now);
    try testing.expect(std.mem.endsWith(u8, b.path, "/A-folder"));
    try testing.expect(findText(u.root.?, "This folder is empty") != null);

    // Up goes back, as far as the user's files (where it is disabled).
    click(u, up(findText(u.root.?, "Up").?, kete.OutlinedButton).?);
    Frame(u, &b, &now);
    try testing.expectEqualStrings(t.path, b.path);
    try testing.expect(up(findText(u.root.?, "Up").?, kete.OutlinedButton).?.widget.as(kete.OutlinedButton).?.on_press == null);

    // Only folders with folders in them have an arrow.
    try testing.expect(findDisclosure(up(findText(u.root.?, "A-folder").?, TreeRow).?) == null);
    try testing.expect(findDisclosure(up(findText(u.root.?, "z-link").?, TreeRow).?) == null);

    // The arrow closes the user's files in the tree (its folders go).
    const user_row = up(findText(u.root.?, "User files").?, TreeRow).?;
    try testing.expect(findText(user_row.parent.?, "z-link") != null);
    click(u, findDisclosure(user_row).?);
    Frame(u, &b, &now);
    try testing.expect(!b.isExpanded(t.path));
    try testing.expect(findText(up(findText(u.root.?, "User files").?, kete.ScrollView).?, "z-link") == null);

    // The switch shows the system's files: the tree starts at /, and a
    // folder above the user's files opens.
    click(u, up(findText(u.root.?, "System files").?, kete.SwitchRow).?);
    Frame(u, &b, &now);
    try testing.expect(b.show_system);
    try testing.expect(findText(u.root.?, "/") != null);
    // The host may have many folders, and only the rows that show are
    // made: scroll the tree down from the top until /tmp's row shows.
    const tree = up(findType(u.root.?, TreeRow).?, kete.ScrollView).?;
    const scroll = tree.state(kete.ScrollView.State);
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
    click(u, up(findText(u.root.?, "System files").?, kete.SwitchRow).?);
    Frame(u, &b, &now);
    try testing.expect(!b.show_system);
    try testing.expectEqualStrings(t.path, b.path);
}

/// The first icon (depth first) that is `icon`.
fn findIcon(n: *kete.WidgetNode, icon: kete.IconName) ?*kete.WidgetNode {
    if (n.widget.as(kete.Icon)) |i| if (i.icon == icon) return n;
    for (n.children.items) |ch| if (findIcon(ch, icon)) |f| return f;
    return null;
}

fn findType(n: *kete.WidgetNode, comptime T: type) ?*kete.WidgetNode {
    if (n.widget.is(T)) return n;
    for (n.children.items) |ch| if (findType(ch, T)) |f| return f;
    return null;
}

/// The grid's tile for `name`.
fn tile(u: *kete.ui.WindowUi, name: []const u8) ?*kete.WidgetNode {
    const grid = up(findType(u.root.?, Tile) orelse return null, kete_vc4.LazyGrid) orelse return null;
    return up(findText(grid, name) orelse return null, Tile);
}

fn findDisclosure(n: *kete.WidgetNode) ?*kete.WidgetNode {
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
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var n: u64 = 0;
    const Frame = struct {
        fn draw(uu: *kete.ui.WindowUi, bb: *Browser, nn: *u64, size: [2]u32) void {
            _ = bb.apply();
            nn.* += 1;
            uu.frame(size[0], size[1], nn.*, Files{ .browser = bb, .now = 1791331200, .width = @floatFromInt(size[0]) });
        }
    }.draw;
    Frame(u, &b, &n, .{ 1600, 900 });
    // By name, as icons, to begin with; each button changes it.
    click(u, up(findText(u.root.?, "Name").?, kete.OutlinedButton).?);
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expectEqual(fs.Order.newest, b.order);
    try testing.expect(findText(u.root.?, "Newest") != null);
    click(u, up(findText(u.root.?, "Icons").?, kete.OutlinedButton).?);
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expectEqual(Layout.list, b.layout);

    // The list: its columns, and a row for each item with its size.
    try testing.expect(findText(u.root.?, "Modified") != null);
    try testing.expect(findType(u.root.?, Tile) == null);
    const row = up(findText(u.root.?, "b-file").?, ListRow).?;
    try testing.expect(findText(row, "5 bytes") != null);
    // Clicking a row picks it, as a tile does; View shows it.
    click(u, row);
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expectEqualStrings("b-file", b.listing.entries[b.selected.?].name);
    try testing.expect(b.file == null);
    click(u, up(findText(u.root.?, "View").?, kete.OutlinedButton).?);
    Frame(u, &b, &n, .{ 1600, 900 });
    // While a file is shown, the order and layout stay as they are.
    try testing.expect(up(findText(u.root.?, "List").?, kete.OutlinedButton).?.widget.as(kete.OutlinedButton).?.on_press == null);
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
    click(u, up(findText(u.root.?, "List").?, kete.OutlinedButton).?);
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
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var n: u64 = 0;
    const Frame = struct {
        fn draw(uu: *kete.ui.WindowUi, bb: *Browser, nn: *u64, size: [2]u32) void {
            _ = bb.apply();
            nn.* += 1;
            uu.frame(size[0], size[1], nn.*, Files{ .browser = bb, .width = @floatFromInt(size[0]) });
        }
    }.draw;
    Frame(u, &b, &n, .{ 1600, 900 });
    // Nothing picked: nothing to delete.
    const delete_button = up(findText(u.root.?, "Delete").?, kete.OutlinedButton).?;
    try testing.expect(delete_button.widget.as(kete.OutlinedButton).?.on_press == null);

    // New folder asks for a name, and the field takes the keyboard.
    click(u, up(findText(u.root.?, "New folder").?, kete.OutlinedButton).?);
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expect(findText(u.root.?, "The new folder's name") != null);
    for (test_sizes) |size| {
        Frame(u, &b, &n, size);
        try testing.expect(!overflows(u.root.?));
    }
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expect(u.focused != null and u.focused.?.widget.is(kete.TextField));
    // Typing a name and Enter makes the folder, which is picked.
    u.key(.{ .key = .a, .pressed = true, .char = 'a' });
    u.key(.{ .key = .a, .pressed = false });
    u.key(.{ .key = .enter, .pressed = true });
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expectEqual(browser_mod.Prompt.none, b.prompt);
    try testing.expectEqualStrings("a", b.picked().?.name);
    try testing.expect(tile(u, "a") != null);

    // The name of something there already is not taken, and it says why.
    b.request(.{ .prompt = .new_folder });
    Frame(u, &b, &n, .{ 1600, 900 });
    u.key(.{ .key = .a, .pressed = true, .char = 'a' });
    u.key(.{ .key = .enter, .pressed = true });
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expect(findText(u.root.?, "The folder cannot be made: there is already something with that name") != null);
    click(u, up(findText(u.root.?, "Cancel").?, kete.OutlinedButton).?);
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expectEqual(browser_mod.Prompt.none, b.prompt);

    // Deleting a folder with things in it warns that they go too.
    try t.write("a/one", "1", 0o644);
    try t.write("a/two", "2", 0o644);
    click(u, up(findText(u.root.?, "Delete").?, kete.OutlinedButton).?);
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expect(findText(u.root.?, "Delete the folder \u{201c}a\u{201d} and everything in it (2 items)? This cannot be undone.") != null);
    try testing.expect(findIcon(u.root.?, .warning) != null);
    for (test_sizes) |size| {
        Frame(u, &b, &n, size);
        try testing.expect(!overflows(u.root.?));
    }
    Frame(u, &b, &n, .{ 1600, 900 });
    // The prompt's Delete button (the one beside Cancel).
    const cancel = up(findText(u.root.?, "Cancel").?, kete.OutlinedButton).?;
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

fn noLaunch(program: [:0]const u8, path: [:0]const u8) bool {
    _ = program;
    _ = path;
    return true;
}

test "New text file and Edit: shown only with an editor, and Edit only for text" {
    var t: fs.TestTree = .{};
    try t.init();
    defer t.deinit();
    var b = try Browser.init(testing.allocator, t.path);
    defer b.deinit();
    b.launcher = noLaunch;
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var n: u64 = 0;
    const Frame = struct {
        fn draw(uu: *kete.ui.WindowUi, bb: *Browser, nn: *u64) void {
            _ = bb.apply();
            nn.* += 1;
            uu.frame(1600, 900, nn.*, Files{ .browser = bb, .width = 1600 });
        }
    }.draw;
    b.apps_dir = "/nonexistent";
    b.findEditor();
    Frame(u, &b, &n);
    try testing.expect(findText(u.root.?, "New text file") == null);
    try testing.expect(findText(u.root.?, "Edit") == null);

    // An editor is installed.
    var buf: [256]u8 = undefined;
    const apps = try std.mem.printSentinel(&buf, "{s}/apps", .{t.path}, 0);
    try fs.makeFolder(t.path, "apps");
    try fs.makeFolder(apps, "ed");
    var hbuf: [256]u8 = undefined;
    try sys.files.writeNew(try std.mem.printSentinel(&hbuf, "{s}/ed/ed.handles", .{apps}, 0), "text/plain\n");
    b.apps_dir = apps;
    b.findEditor();
    Frame(u, &b, &n);
    click(u, up(findText(u.root.?, "New text file").?, kete.OutlinedButton).?);
    Frame(u, &b, &n);
    try testing.expect(findTextPrefix(u.root.?, "The new text file's name") != null);
    b.setName("todo");
    click(u, up(findText(u.root.?, "Make").?, kete.OutlinedButton).?);
    Frame(u, &b, &n);
    try testing.expectEqualStrings("todo.txt", b.picked().?.name);
    // Picked, it can be viewed and edited.
    try testing.expect(findText(u.root.?, "View") != null);
    try testing.expect(findText(u.root.?, "Edit") != null);
    // Even with Paste, View, Edit, New text file, New folder, and Delete
    // all shown, the bottom bar fits at every window size.
    b.request(.copy);
    Frame(u, &b, &n);
    for (test_sizes) |size| {
        n += 1;
        u.frame(size[0], size[1], n, Files{ .browser = &b, .width = @floatFromInt(size[0]) });
        try testing.expect(!overflows(u.root.?));
    }
}

test "USB drives in the tree, with what they hold, and ejecting them" {
    var t: fs.TestTree = .{};
    try t.init();
    defer t.deinit();
    var buf: [128]u8 = undefined;
    const media = try std.mem.printSentinel(&buf, "{s}-media", .{t.path}, 0);
    _ = std.os.linux.mkdir(media, 0o755);
    defer sys.files.removeTree(media);
    try fs.makeFolder(media, "HOLIDAY");
    var b = try Browser.init(testing.allocator, t.path);
    defer b.deinit();
    b.media_dir = media;
    b.refreshDrives();
    const Eject = struct {
        fn f(_: []const u8) ?sys.media.Answer {
            return .ejected;
        }
    };
    b.ejector = Eject.f;
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var n: u64 = 0;
    const Frame = struct {
        fn draw(uu: *kete.ui.WindowUi, bb: *Browser, nn: *u64, size: [2]u32) void {
            _ = bb.apply();
            nn.* += 1;
            uu.frame(size[0], size[1], nn.*, Files{ .browser = bb, .width = @floatFromInt(size[0]) });
        }
    }.draw;
    Frame(u, &b, &n, .{ 1600, 900 });
    // After the user's files, with a USB icon and an eject button.
    const row = up(findText(u.root.?, "HOLIDAY").?, TreeRow).?;
    try testing.expect(findIcon(row, .usb) != null);
    try testing.expect(findIcon(row, .eject) != null);
    try testing.expect(findIcon(up(findText(u.root.?, "User files").?, TreeRow).?, .eject) == null);
    // Opened, it says how much space there is.
    click(u, row);
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expect(std.mem.endsWith(u8, b.path, "/HOLIDAY"));
    try testing.expect(findText(u.root.?, "This folder is empty") != null);
    for (test_sizes) |size| {
        Frame(u, &b, &n, size);
        try testing.expect(!overflows(u.root.?));
    }
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expect(findTextPrefix(u.root.?, "USB drive  \u{b7}  ") != null);
    // Ejected: back to the user's files, saying it can be taken out.
    click(u, up(findIcon(up(findText(u.root.?, "HOLIDAY").?, TreeRow).?, .eject).?, kete.IconButton).?);
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expectEqualStrings(t.path, b.path);
    try testing.expect(findText(u.root.?, "You can take out \u{201c}HOLIDAY\u{201d} now") != null);
    // Gone from the tree when its folder goes.
    try fs.delete(media, "HOLIDAY");
    b.refreshDrives();
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expect(findText(u.root.?, "HOLIDAY") == null);
}

fn findTextPrefix(n: *kete.WidgetNode, prefix: []const u8) ?*kete.WidgetNode {
    if (n.widget.as(kete.Text)) |t| if (std.mem.startsWith(u8, t.text, prefix)) return n;
    for (n.children.items) |ch| if (findTextPrefix(ch, prefix)) |f| return f;
    return null;
}

/// Drags from the middle of `from` to the middle of `to`.
fn dragTo(u: *kete.ui.WindowUi, from: *kete.WidgetNode, to: kete.Point) void {
    const at = from.position();
    const start: kete.Point = .{ at[0] + from.size.w / 2, at[1] + from.size.h / 2 };
    u.pointerMotion(start);
    u.pointerButton(start, .left, true);
    u.pointerMotion(.{ start[0] + 20, start[1] });
    u.pointerMotion(to);
    u.pointerButton(to, .left, false);
}

fn middle(n: *kete.WidgetNode) kete.Point {
    const at = n.position();
    return .{ at[0] + n.size.w / 2, at[1] + n.size.h / 2 };
}

test "copying and pasting from the menu, and dragging onto folders" {
    var t: fs.TestTree = .{};
    try t.init();
    defer t.deinit();
    var b = try Browser.init(testing.allocator, t.path);
    defer b.deinit();
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var n: u64 = 0;
    const Frame = struct {
        fn draw(uu: *kete.ui.WindowUi, bb: *Browser, nn: *u64, size: [2]u32) void {
            _ = bb.apply();
            while (bb.poll()) sys.sleepMs(1);
            nn.* += 1;
            uu.frame(size[0], size[1], nn.*, Files{ .browser = bb, .width = @floatFromInt(size[0]) });
        }
    }.draw;
    Frame(u, &b, &n, .{ 1600, 900 });
    // No Paste button until something is copied.
    try testing.expect(findText(u.root.?, "Paste") == null);

    // The right button on b-file: it is picked, and its menu shows.
    const p = middle(tile(u, "b-file").?);
    u.pointerMotion(p);
    u.pointerButton(p, .right, true);
    u.pointerButton(p, .right, false);
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expectEqualStrings("b-file", b.picked().?.name);
    try testing.expect(b.file == null);
    try testing.expect(u.menu != null);
    click(u, findText(u.menu_root.?, "Copy").?);
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expectEqualStrings("b-file", b.clipName().?);
    for (test_sizes) |size| {
        Frame(u, &b, &n, size);
        try testing.expect(!overflows(u.root.?));
    }
    Frame(u, &b, &n, .{ 1600, 900 });
    // Pasted from the button at the bottom.
    click(u, up(findText(u.root.?, "Paste").?, kete.OutlinedButton).?);
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expect(tile(u, "b-file (copy)") != null);

    // Dragged onto A-folder (a tile): moved there.
    dragTo(u, tile(u, "b-file (copy)").?, middle(tile(u, "A-folder").?));
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expect(tile(u, "b-file (copy)") == null);
    var buf: [128]u8 = undefined;
    const folder = try std.fmt.bufPrint(&buf, "{s}/A-folder", .{t.path});
    var l = fs.Listing.read(testing.allocator, folder);
    try testing.expectEqualStrings("b-file (copy)", l.entries[0].name);
    l.deinit();

    // With Ctrl (as the window's keys tell the browser), onto A-folder
    // in the tree: copied.
    b.ctrl_held = true;
    dragTo(u, tile(u, "c-tool").?, middle(up(findText(up(findText(u.root.?, "User files").?, kete.ScrollView).?, "A-folder").?, TreeRow).?));
    b.ctrl_held = false;
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expect(tile(u, "c-tool") != null);
    l = fs.Listing.read(testing.allocator, folder);
    try testing.expectEqual(@as(usize, 2), l.entries.len);
    l.deinit();

    // While copying, the bottom says how far it has got, at every size.
    try t.write("big", &@as([1024 * 1024]u8, @splat('z')), 0o644);
    b.request(.{ .open = t.path });
    _ = b.apply();
    const big = for (b.listing.entries, 0..) |e, i| {
        if (std.mem.eql(u8, e.name, "big")) break i;
    } else unreachable;
    @import("copier.zig").test_chunk_delay_ms = 20;
    defer @import("copier.zig").test_chunk_delay_ms = 0;
    b.request(.{ .drop = .{ .index = big, .into = folder, .copy = true } });
    _ = b.apply();
    while (b.copier.?.progress().done == 0) sys.sleepMs(1);
    for (test_sizes) |size| {
        n += 1;
        u.frame(size[0], size[1], n, Files{ .browser = &b, .width = @floatFromInt(size[0]) });
        try testing.expect(!overflows(u.root.?));
    }
    try testing.expect(findTextPrefix(u.root.?, "Copying \u{201c}big\u{201d}: ") != null);
    b.request(.cancel_copy);
    Frame(u, &b, &n, .{ 1600, 900 });
    try testing.expect(!b.copying());
}
