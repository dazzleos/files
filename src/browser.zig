//! What the Files window shows: the open folder (and what is in it), the
//! item picked in it (and what is in it, if it is a file: see
//! content.zig), and the folders opened in the tree (with the folders
//! in each, read when it is opened). Everything is within a root: the
//! user's files (`user_files`: /data/user, on the SD card) or a USB drive
//! (each a folder of /media), unless the system's files are shown too,
//! when it is /; nothing above it is opened.
//!
//! The window's widgets ask for changes (`request`); they are made between
//! frames (`apply`), so nothing a widget of the last frame points to (an
//! entry's name, say) is freed while events still go to it.

const std = @import("std");
const sys = @import("sys");
const fs = @import("fs.zig");
const copier = @import("copier.zig");
const content = @import("content.zig");

pub const Action = union(enum) {
    /// Show this folder.
    open: []const u8,
    /// Open or close this folder in the tree.
    toggle: []const u8,
    /// An item in the open folder (an index into its entries): a folder
    /// is opened, and a file shown; anything else (a device, say) is only
    /// picked.
    activate: usize,
    /// Back from the file shown to its folder, or else to the folder
    /// holding the open one.
    up,
    /// Show the system's files too (the root is /), or only the user's.
    show_system: bool,
    /// Put the open folder's items in this order.
    order: fs.Order,
    /// Show them so.
    layout: Layout,
    /// Ask for a new folder's name, or whether to delete the item picked
    /// (or neither, any more).
    prompt: Prompt,
    /// Make the folder named `name` in the open folder, and pick it.
    make_folder,
    /// Delete the item picked: a file, or a folder and everything in it.
    delete,
    /// Eject the USB drive of this name (in /media), for it to be taken out.
    eject: []const u8,
    /// Pick an item in the open folder (an index into its entries),
    /// without opening it.
    pick: usize,
    /// Copy the item picked, or cut it (to be moved where it is pasted).
    copy,
    cut,
    /// Copy (or move, if it was cut) what was copied into the open folder.
    paste,
    /// An item of the open folder (an index) was dragged onto the folder
    /// `into`: moved there, or copied if `copy` (or if it is on another
    /// drive).
    drop: Drop,
    /// Stop copying.
    cancel_copy,
};

pub const Drop = struct { index: usize, into: []const u8, copy: bool = false };

/// What the window is asking: nothing, a new folder's name, or whether to
/// delete the item picked.
pub const Prompt = enum { none, new_folder, delete };

/// How the open folder's items are shown: as a grid of icons, or as a list
/// with when each was changed and its size.
pub const Layout = enum { icons, list };

pub const Browser = struct {
    gpa: std.mem.Allocator,
    /// Where the user's files are, and where the window starts.
    user_files: []const u8,
    /// The system's files are shown too: the root is / rather than `user_files`.
    show_system: bool = false,
    /// The order of the open folder's items, and how they are shown.
    order: fs.Order = .name,
    layout: Layout = .icons,
    /// The open folder.
    path: []u8,
    listing: fs.Listing,
    /// The item picked in it.
    selected: ?usize = null,
    /// The file shown (the item picked), and what is in it.
    file: ?content.Content = null,
    /// The folders open in the tree, and the folders in each.
    expanded: std.StringHashMapUnmanaged(fs.Listing) = .empty,
    /// What the window is asking, and why the last change asked for
    /// could not be made (shown with it).
    prompt: Prompt = .none,
    failure: ?[]const u8 = null,
    /// The new folder's name, as it is typed.
    name_buf: [255]u8 = undefined,
    name_len: usize = 0,
    /// How many things are in the folder to be deleted, if it is one.
    delete_count: ?usize = null,
    /// The USB drives plugged in: the folders in `media_dir`.
    media_dir: []const u8 = sys.media.media_dir,
    drives: fs.Listing,
    /// Asks the media manager to eject a drive.
    ejector: *const fn (name: []const u8) ?sys.media.Answer = askEject,
    /// What was copied or cut (its path), to be pasted.
    clip_path: ?[]u8 = null,
    clip_cut: bool = false,
    /// What is being copied or moved, a little each frame (`work`).
    copier: ?*copier.Copier = null,
    /// What happened (to a drive ejected, or to what was copied), said at
    /// the bottom until something else is done.
    notice_buf: [200]u8 = undefined,
    notice_len: usize = 0,
    /// What was asked for since the last `apply`, and room for its path.
    pending: ?Action = null,
    pending_path: std.ArrayList(u8) = .empty,

    /// Starts at `user_files` (which must last as long as the browser), showing
    /// only what is in it.
    pub fn init(gpa: std.mem.Allocator, user_files: []const u8) !Browser {
        var b: Browser = .{
            .gpa = gpa,
            .user_files = user_files,
            .path = try gpa.dupe(u8, user_files),
            .listing = fs.Listing.read(gpa, user_files),
            .drives = fs.Listing.read(gpa, sys.media.media_dir),
        };
        try b.expand(user_files);
        return b;
    }

    /// The folder at the top of the tree; nothing above it is opened.
    pub fn root(b: *const Browser) []const u8 {
        return if (b.show_system) "/" else b.user_files;
    }

    /// The root `path` is within (a part of `path`), if it is within one:
    /// the system's files, the user's files, or a USB drive.
    pub fn rootOf(b: *const Browser, path: []const u8) ?[]const u8 {
        if (b.show_system) return if (fs.within(path, "/")) "/" else null;
        if (fs.within(path, b.user_files)) return b.user_files;
        const media = b.media_dir;
        if (!fs.within(path, media) or path.len == media.len) return null;
        const rest = path[media.len + 1 ..];
        const name = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
        if (!b.isDrive(name)) return null;
        return path[0 .. media.len + 1 + name.len];
    }

    /// Whether a USB drive of this name is plugged in.
    pub fn isDrive(b: *const Browser, name: []const u8) bool {
        for (b.drives.entries) |e| if (e.kind == .folder and !e.link and std.mem.eql(u8, e.name, name)) return true;
        return false;
    }

    /// The name of the USB drive whose folder `path` is, if it is one.
    pub fn driveAt(b: *const Browser, path: []const u8) ?[]const u8 {
        if (!std.mem.eql(u8, fs.parent(path), b.media_dir)) return null;
        const name = path[b.media_dir.len + 1 ..];
        return if (b.isDrive(name)) name else null;
    }

    pub fn atRoot(b: *const Browser) bool {
        const r = b.rootOf(b.path) orelse return true;
        return std.mem.eql(u8, b.path, r);
    }

    pub fn notice(b: *const Browser) ?[]const u8 {
        return if (b.notice_len > 0) b.notice_buf[0..b.notice_len] else null;
    }

    fn say(b: *Browser, comptime fmt: []const u8, args: anytype) void {
        const text: []const u8 = std.fmt.bufPrint(&b.notice_buf, fmt, args) catch "";
        b.notice_len = text.len;
    }

    /// Reads the drives plugged in again (when /media changes). If the
    /// open folder was on one that has gone, the user's files open.
    pub fn refreshDrives(b: *Browser) void {
        b.drives.deinit();
        b.drives = fs.Listing.read(b.gpa, b.media_dir);
        // The tree's folders on drives that have gone close.
        while (true) {
            var it = b.expanded.keyIterator();
            const key = while (it.next()) |k| {
                if (b.rootOf(k.*) == null) break k.*;
            } else break;
            var kv = b.expanded.fetchRemove(key).?;
            kv.value.deinit();
            b.gpa.free(kv.key);
        }
        if (b.rootOf(b.path) == null) b.open(b.user_files) catch {};
    }

    fn eject(b: *Browser, name: []const u8) void {
        if (!b.isDrive(name)) return;
        // Not looking at it any more.
        const path = fs.join(b.gpa, b.media_dir, name) catch return;
        defer b.gpa.free(path);
        if (fs.within(b.path, path)) b.open(b.user_files) catch {};
        switch (b.ejector(name) orelse .failed) {
            .ejected => b.say("You can take out \u{201c}{s}\u{201d} now", .{name}),
            .busy => b.say("\u{201c}{s}\u{201d} is in use: close what is open on it, then eject it again", .{name}),
            .unknown => b.say("\u{201c}{s}\u{201d} is not plugged in", .{name}),
            .failed => b.say("\u{201c}{s}\u{201d} could not be ejected", .{name}),
        }
        b.refreshDrives();
    }

    pub fn deinit(b: *Browser) void {
        var it = b.expanded.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit();
            b.gpa.free(e.key_ptr.*);
        }
        b.expanded.deinit(b.gpa);
        b.closeFile();
        b.listing.deinit();
        b.drives.deinit();
        if (b.copier) |c| {
            c.cancel();
            c.deinit();
        }
        if (b.clip_path) |p| b.gpa.free(p);
        b.gpa.free(b.path);
        b.pending_path.deinit(b.gpa);
    }

    /// Asks for `action` to be done at the next `apply` (the path is
    /// copied). A later request replaces an earlier one.
    pub fn request(b: *Browser, action: Action) void {
        var a = action;
        switch (a) {
            inline .open, .toggle, .eject => |path, tag| {
                b.pending_path.clearRetainingCapacity();
                b.pending_path.appendSlice(b.gpa, path) catch return;
                a = @unionInit(Action, @tagName(tag), b.pending_path.items);
            },
            .drop => |d| {
                b.pending_path.clearRetainingCapacity();
                b.pending_path.appendSlice(b.gpa, d.into) catch return;
                a = .{ .drop = .{ .index = d.index, .into = b.pending_path.items, .copy = d.copy } };
            },
            else => {},
        }
        b.pending = a;
    }

    /// Does what was asked. Returns whether anything was.
    pub fn apply(b: *Browser) bool {
        const a = b.pending orelse return false;
        b.pending = null;
        b.notice_len = 0;
        switch (a) {
            .open => |path| b.open(path) catch {},
            .toggle => |path| b.toggle(path) catch {},
            .activate => |i| b.activate(i) catch {},
            .up => if (b.file != null) b.closeFile() else if (!b.atRoot()) b.open(fs.parent(b.path)) catch {},
            .show_system => |on| b.showSystem(on) catch {},
            .order => |o| b.sortBy(o),
            .layout => |l| b.layout = l,
            .prompt => |p| b.ask(p),
            .make_folder => b.makeFolder(),
            .delete => b.delete(),
            .eject => |name| b.eject(name),
            .pick => |i| if (i < b.listing.entries.len) {
                if (b.selected != i) b.ask(.none);
                b.closeFile();
                b.selected = i;
            },
            .copy, .cut => b.clip(a == .cut),
            .paste => b.paste(),
            .drop => |d| b.drop(d),
            .cancel_copy => if (b.copier) |c| c.cancel(),
        }
        return true;
    }

    /// Whether something is being copied or moved.
    pub fn copying(b: *const Browser) bool {
        return b.copier != null;
    }

    /// Whether there is something to paste, and it can go here.
    pub fn canPaste(b: *const Browser) bool {
        return b.clip_path != null and b.copier == null and b.file == null and b.changeable();
    }

    /// The name of what was copied or cut, if anything was.
    pub fn clipName(b: *const Browser) ?[]const u8 {
        return if (b.clip_path) |p| fs.baseName(p) else null;
    }

    fn clip(b: *Browser, cut: bool) void {
        const e = b.picked() orelse return;
        // Cutting needs leave to delete it here.
        if (cut and !b.changeable()) return;
        const path = fs.join(b.gpa, b.path, e.name) catch return;
        if (b.clip_path) |p| b.gpa.free(p);
        b.clip_path = path;
        b.clip_cut = cut;
        b.say("{s} \u{201c}{s}\u{201d}: paste it where it is to go", .{ if (cut) "Cut" else "Copied", e.name });
    }

    fn paste(b: *Browser) void {
        if (!b.canPaste()) return;
        const from = b.clip_path.?;
        // Cut and pasted where it was: nothing to do.
        if (b.clip_cut and std.mem.eql(u8, fs.parent(from), b.path)) return;
        b.startCopy(from, b.path, b.clip_cut);
    }

    fn drop(b: *Browser, d: Drop) void {
        if (b.copier != null or d.index >= b.listing.entries.len) return;
        const e = b.listing.entries[d.index];
        const from = fs.join(b.gpa, b.path, e.name) catch return;
        defer b.gpa.free(from);
        // Onto itself, or where it already is.
        if (std.mem.eql(u8, from, d.into) or std.mem.eql(u8, b.path, d.into)) return;
        if (!fs.writable(d.into)) {
            b.say("\u{201c}{s}\u{201d} cannot go there: {s}", .{ e.name, copier.describeError(error.AccessDenied) });
            return;
        }
        // To another drive it is copied; within one, moved.
        const move = !d.copy and b.changeable() and copier.sameFilesystem(from, d.into);
        b.startCopy(from, d.into, move);
    }

    fn startCopy(b: *Browser, from: []const u8, into: []const u8, move: bool) void {
        b.ask(.none);
        const c = copier.Copier.start(b.gpa, from, into, move) catch |err| {
            b.say("\u{201c}{s}\u{201d} cannot be {s}: {s}", .{ fs.baseName(from), if (move) "moved" else "copied", copier.describeError(err) });
            return;
        };
        b.copier = c;
        // What was cut is gone once moved.
        if (move and b.clip_path != null and std.mem.eql(u8, b.clip_path.?, from)) {
            b.gpa.free(b.clip_path.?);
            b.clip_path = null;
        }
        if (c.done()) b.finishCopy();
    }

    /// Finishes off the copy if it has finished. Returns whether
    /// something is (still) being copied.
    pub fn poll(b: *Browser) bool {
        const c = b.copier orelse return false;
        if (c.done()) b.finishCopy();
        return b.copier != null;
    }

    fn finishCopy(b: *Browser) void {
        const c = b.copier orelse return;
        b.copier = null;
        defer c.deinit();
        const verb = if (c.move) "moved" else "copied";
        if (c.err) |err| {
            b.say("\u{201c}{s}\u{201d} could not be {s}: {s}", .{ fs.baseName(c.source), verb, copier.describeError(err) });
        } else if (c.skipped > 0) {
            b.say("\u{201c}{s}\u{201d} was {s}, but {d} of the things in it could not be", .{ fs.baseName(c.source), verb, c.skipped });
        } else if (c.cancelled) {
            b.say("Stopped: \u{201c}{s}\u{201d} was only partly {s}", .{ fs.baseName(c.source), verb });
        } else b.say("\u{201c}{s}\u{201d} was {s} to {s}", .{ c.name, verb, c.into });
        // The folders it went from and to are read again; in the open
        // one, what was made is picked.
        b.refreshFolder(c.into);
        if (c.move) {
            b.refreshFolder(fs.parent(c.source));
            b.collapseWithin(c.source);
        }
        const notice_len = b.notice_len;
        if (std.mem.eql(u8, b.path, c.into) or (c.move and std.mem.eql(u8, b.path, fs.parent(c.source)))) {
            b.reload();
            if (std.mem.eql(u8, b.path, c.into)) b.selected = for (b.listing.entries, 0..) |e, i| {
                if (std.mem.eql(u8, e.name, c.name)) break i;
            } else null;
        }
        b.notice_len = notice_len;
    }

    /// Reads a folder open in the tree again.
    fn refreshFolder(b: *Browser, path: []const u8) void {
        if (b.expanded.getPtr(path)) |l| {
            l.deinit();
            l.* = fs.Listing.read(b.gpa, path);
        }
    }

    /// The new folder's name, as it is typed (kept until it is made or
    /// asked for again).
    pub fn setName(b: *Browser, text: []const u8) void {
        const n = @min(text.len, b.name_buf.len);
        @memcpy(b.name_buf[0..n], text[0..n]);
        b.name_len = n;
    }

    pub fn newName(b: *const Browser) []const u8 {
        return b.name_buf[0..b.name_len];
    }

    /// Whether things can be made in, and deleted from, the open folder.
    pub fn changeable(b: *const Browser) bool {
        return b.listing.err == null and fs.writable(b.path);
    }

    /// The item picked, if there is one.
    pub fn picked(b: *const Browser) ?fs.Entry {
        const i = b.selected orelse return null;
        return if (i < b.listing.entries.len) b.listing.entries[i] else null;
    }

    fn ask(b: *Browser, p: Prompt) void {
        b.failure = null;
        b.delete_count = null;
        switch (p) {
            .none => {},
            .new_folder => {
                if (b.file != null or !b.changeable()) return;
                b.name_len = 0;
            },
            .delete => {
                const e = b.picked() orelse return;
                if (!b.changeable()) return;
                if (e.kind == .folder and !e.link) {
                    const path = fs.join(b.gpa, b.path, e.name) catch return;
                    defer b.gpa.free(path);
                    b.delete_count = fs.countItems(path);
                }
            },
        }
        b.prompt = p;
    }

    fn makeFolder(b: *Browser) void {
        if (b.prompt != .new_folder) return;
        fs.makeFolder(b.path, b.newName()) catch |err| {
            b.failure = fs.describeError(err);
            return;
        };
        b.prompt = .none;
        b.failure = null;
        b.reload();
        // The new folder is picked.
        b.selected = for (b.listing.entries, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, b.newName())) break i;
        } else null;
    }

    fn delete(b: *Browser) void {
        if (b.prompt != .delete) return;
        const e = b.picked() orelse return;
        fs.delete(b.path, e.name) catch |err| {
            b.failure = fs.describeError(err);
            // Some of it may have gone.
            if (err == error.NotDeleted) b.delete_count = b.countPicked();
            return;
        };
        // The folders that were in it close in the tree.
        if (e.kind == .folder and !e.link) if (fs.join(b.gpa, b.path, e.name)) |path| {
            defer b.gpa.free(path);
            b.collapseWithin(path);
        } else |_| {};
        b.prompt = .none;
        b.failure = null;
        b.delete_count = null;
        b.reload();
    }

    fn countPicked(b: *const Browser) ?usize {
        const e = b.picked() orelse return null;
        const path = fs.join(b.gpa, b.path, e.name) catch return null;
        defer b.gpa.free(path);
        return fs.countItems(path);
    }

    /// Reads the open folder again (and its folders in the tree), after a
    /// change; nothing is picked.
    fn reload(b: *Browser) void {
        b.closeFile();
        b.listing.deinit();
        b.listing = fs.Listing.read(b.gpa, b.path);
        b.listing.sort(b.order);
        b.selected = null;
        if (b.expanded.getPtr(b.path)) |l| {
            l.deinit();
            l.* = fs.Listing.read(b.gpa, b.path);
        }
    }

    /// Closes the folders at and in `path` in the tree.
    fn collapseWithin(b: *Browser, path: []const u8) void {
        while (true) {
            var it = b.expanded.keyIterator();
            const key = while (it.next()) |k| {
                if (fs.within(k.*, path)) break k.*;
            } else return;
            var kv = b.expanded.fetchRemove(key).?;
            kv.value.deinit();
            b.gpa.free(kv.key);
        }
    }

    /// Puts the open folder's items in `order`; the item picked stays
    /// picked.
    pub fn sortBy(b: *Browser, order: fs.Order) void {
        b.order = order;
        const kept: ?[]const u8 = if (b.selected) |i| (if (i < b.listing.entries.len) b.listing.entries[i].name else null) else null;
        b.listing.sort(order);
        if (kept) |name| b.selected = for (b.listing.entries, 0..) |e, i| {
            if (e.name.ptr == name.ptr) break i;
        } else null;
    }

    /// Shows the system's files too, or only the user's (going back to the user's files if the
    /// open folder is not among them).
    pub fn showSystem(b: *Browser, on: bool) !void {
        b.show_system = on;
        try b.expand(b.root());
        if (b.rootOf(b.path) == null) try b.open(b.user_files) else try b.expandTo(b.path);
    }

    /// Shows the folder at `path` (if it is within the root), opening the
    /// folders above it in the tree.
    pub fn open(b: *Browser, path: []const u8) !void {
        if (b.rootOf(path) == null) return;
        const new = try b.gpa.dupe(u8, path);
        b.gpa.free(b.path);
        b.path = new;
        b.closeFile();
        b.listing.deinit();
        b.listing = fs.Listing.read(b.gpa, new);
        b.listing.sort(b.order);
        b.selected = null;
        b.ask(.none);
        try b.expandTo(new);
    }

    fn activate(b: *Browser, i: usize) !void {
        if (i >= b.listing.entries.len) return;
        const e = b.listing.entries[i];
        if (b.selected != i) b.ask(.none);
        if (e.kind != .folder) {
            b.closeFile();
            b.selected = i;
            // Only files are read: opening a device can do things (start
            // the watchdog, say).
            if (e.kind == .file or e.kind == .program) {
                const path = try fs.join(b.gpa, b.path, e.name);
                defer b.gpa.free(path);
                b.file = content.Content.read(b.gpa, path);
            }
            return;
        }
        const path = try fs.join(b.gpa, b.path, e.name);
        defer b.gpa.free(path);
        try b.open(path);
    }

    /// Stops showing the file (it stays picked).
    pub fn closeFile(b: *Browser) void {
        if (b.file) |*f| f.deinit();
        b.file = null;
    }

    /// The path of the file shown (in `gpa`), if one is.
    pub fn filePath(b: *const Browser, gpa: std.mem.Allocator) ?[]u8 {
        if (b.file == null) return null;
        const i = b.selected orelse return null;
        return fs.join(gpa, b.path, b.listing.entries[i].name) catch null;
    }

    /// Opens the folder at `path` in the tree, or closes it.
    pub fn toggle(b: *Browser, path: []const u8) !void {
        if (b.expanded.fetchRemove(path)) |kv| {
            var l = kv.value;
            l.deinit();
            b.gpa.free(kv.key);
        } else try b.expand(path);
    }

    pub fn isExpanded(b: *const Browser, path: []const u8) bool {
        return b.expanded.contains(path);
    }

    /// The folders in an open folder of the tree.
    pub fn subfolders(b: *const Browser, path: []const u8) []const fs.Entry {
        const l = b.expanded.getPtr(path) orelse return &.{};
        return l.folders();
    }

    /// Opens the folders above `path` (not `path` itself) in the tree, from
    /// the root.
    fn expandTo(b: *Browser, path: []const u8) !void {
        const r = b.rootOf(path) orelse return;
        var end: usize = 0;
        while (end < path.len) {
            const ancestor = if (end == 0) "/" else path[0..end];
            if (fs.within(ancestor, r) and !b.isExpanded(ancestor)) try b.expand(ancestor);
            end = std.mem.indexOfScalarPos(u8, path, end + 1, '/') orelse break;
        }
    }

    fn expand(b: *Browser, path: []const u8) !void {
        if (b.isExpanded(path)) return;
        const key = try b.gpa.dupe(u8, path);
        errdefer b.gpa.free(key);
        var l = fs.Listing.read(b.gpa, path);
        errdefer l.deinit();
        try b.expanded.put(b.gpa, key, l);
    }
};

/// Asks the media manager, giving it time to write what is left.
fn askEject(name: []const u8) ?sys.media.Answer {
    return sys.media.eject(name, 30_000);
}

const testing = std.testing;

test "opening folders, from the tree and the grid, and going up as far as the user's files" {
    var t: fs.TestTree = .{};
    try t.init();
    defer t.deinit();
    var b = try Browser.init(testing.allocator, t.path);
    defer b.deinit();
    // Home is the root, open in the tree; nothing above it.
    try testing.expectEqualStrings(t.path, b.root());
    try testing.expect(b.isExpanded(t.path));
    try testing.expect(!b.isExpanded("/"));
    try testing.expectEqual(@as(usize, 2), b.subfolders(t.path).len);
    try testing.expectEqual(@as(usize, 5), b.listing.entries.len);

    // A file is shown (and picked), and Up goes back to its folder; a
    // folder is opened.
    b.request(.{ .activate = 2 });
    try testing.expect(b.apply());
    try testing.expectEqual(@as(?usize, 2), b.selected);
    try testing.expectEqualStrings("hello", b.file.?.kind.text[0]);
    b.request(.up);
    _ = b.apply();
    try testing.expect(b.file == null);
    try testing.expectEqualStrings(t.path, b.path);
    b.request(.{ .activate = 2 });
    _ = b.apply();
    b.request(.{ .activate = 0 });
    _ = b.apply();
    try testing.expect(std.mem.endsWith(u8, b.path, "/A-folder"));
    try testing.expectEqual(@as(?usize, null), b.selected);
    try testing.expectEqual(@as(usize, 0), b.listing.entries.len);
    try testing.expect(!b.apply());

    // Up, as far as the user's files and no further; nothing outside it opens.
    b.request(.up);
    _ = b.apply();
    try testing.expectEqualStrings(t.path, b.path);
    try testing.expect(b.atRoot());
    b.request(.up);
    _ = b.apply();
    try testing.expectEqualStrings(t.path, b.path);
    b.request(.{ .open = "/tmp" });
    _ = b.apply();
    try testing.expectEqualStrings(t.path, b.path);

    // Closing and opening a folder in the tree.
    b.request(.{ .toggle = t.path });
    _ = b.apply();
    try testing.expect(!b.isExpanded(t.path));
    try testing.expectEqual(@as(usize, 0), b.subfolders(t.path).len);
    b.request(.{ .toggle = t.path });
    _ = b.apply();
    try testing.expect(b.isExpanded(t.path));

    // With the system's files, the root is /: up leaves the user's files, and the
    // folders above what is opened are open in the tree.
    b.request(.{ .show_system = true });
    _ = b.apply();
    try testing.expectEqualStrings("/", b.root());
    try testing.expect(b.isExpanded("/") and b.isExpanded("/tmp"));
    b.request(.up);
    _ = b.apply();
    try testing.expectEqualStrings("/tmp", b.path);
    // Without them again, it goes back to the user's files.
    b.request(.{ .show_system = false });
    _ = b.apply();
    try testing.expectEqualStrings(t.path, b.path);
    try testing.expectEqualStrings(t.path, b.root());
    // From inside the user's files it stays where it is.
    var sub_buf: [128]u8 = undefined;
    const sub = try std.fmt.bufPrint(&sub_buf, "{s}/A-folder", .{t.path});
    b.request(.{ .open = sub });
    _ = b.apply();
    try b.showSystem(true);
    try b.showSystem(false);
    try testing.expectEqualStrings(sub, b.path);
}

test "the newest first, and the item picked stays picked; and the list" {
    var t: fs.TestTree = .{};
    try t.init();
    defer t.deinit();
    // b-file older than c-tool.
    var z: [128]u8 = undefined;
    for ([_]struct { []const u8, isize }{ .{ "b-file", 1_000_000_000 }, .{ "c-tool", 2_000_000_000 } }) |f| {
        const times = [2]std.os.linux.timespec{ .{ .sec = f[1], .nsec = 0 }, .{ .sec = f[1], .nsec = 0 } };
        _ = std.os.linux.utimensat(std.os.linux.AT.FDCWD, try std.fmt.bufPrintZ(&z, "{s}/{s}", .{ t.path, f[0] }), &times, 0);
    }
    var b = try Browser.init(testing.allocator, t.path);
    defer b.deinit();
    // By name: A-folder, z-link (to a folder), b-file, broken, c-tool.
    try testing.expectEqualStrings("b-file", b.listing.entries[2].name);
    b.request(.{ .activate = 2 });
    _ = b.apply();
    b.request(.{ .order = .newest });
    try testing.expect(b.apply());
    try testing.expectEqual(fs.Order.newest, b.order);
    // Folders first still, then c-tool, b-file (still picked), broken.
    try testing.expectEqualStrings("c-tool", b.listing.entries[2].name);
    try testing.expectEqualStrings("b-file", b.listing.entries[b.selected.?].name);
    try testing.expectEqualStrings("broken", b.listing.entries[4].name);
    // A folder opened is in the same order.
    b.request(.{ .open = t.path });
    _ = b.apply();
    try testing.expectEqualStrings("c-tool", b.listing.entries[2].name);

    try testing.expectEqual(Layout.icons, b.layout);
    b.request(.{ .layout = .list });
    _ = b.apply();
    try testing.expectEqual(Layout.list, b.layout);
}

test "making a folder, which is picked; and deleting files, and folders with what is in them" {
    var t: fs.TestTree = .{};
    try t.init();
    defer t.deinit();
    var b = try Browser.init(testing.allocator, t.path);
    defer b.deinit();
    try testing.expect(b.changeable());

    // A name that cannot be, then one that can.
    b.request(.{ .prompt = .new_folder });
    _ = b.apply();
    try testing.expectEqual(Prompt.new_folder, b.prompt);
    b.setName("A-folder");
    b.request(.make_folder);
    _ = b.apply();
    try testing.expectEqual(Prompt.new_folder, b.prompt);
    try testing.expectEqualStrings("there is already something with that name", b.failure.?);
    b.setName("Music");
    b.request(.make_folder);
    _ = b.apply();
    try testing.expectEqual(Prompt.none, b.prompt);
    try testing.expect(b.failure == null);
    try testing.expectEqualStrings("Music", b.picked().?.name);
    // It is in the tree too.
    try testing.expectEqual(@as(usize, 3), b.subfolders(t.path).len);

    // A folder with things in it says how many, and they go with it; the
    // folders open in the tree in it close.
    var buf: [128]u8 = undefined;
    const music = try std.fmt.bufPrint(&buf, "{s}/Music", .{t.path});
    try fs.makeFolder(music, "Albums");
    try t.write("Music/song", "la", 0o644);
    try b.toggle(music);
    try testing.expect(b.isExpanded(music));
    b.request(.{ .prompt = .delete });
    _ = b.apply();
    try testing.expectEqual(Prompt.delete, b.prompt);
    try testing.expectEqual(@as(?usize, 2), b.delete_count);
    b.request(.delete);
    _ = b.apply();
    try testing.expectEqual(Prompt.none, b.prompt);
    try testing.expect(!b.isExpanded(music));
    try testing.expectEqual(@as(usize, 5), b.listing.entries.len);
    try testing.expect(b.selected == null);

    // Picking something else stops asking; a file shown can be deleted.
    b.request(.{ .activate = 3 });
    _ = b.apply();
    b.request(.{ .prompt = .delete });
    _ = b.apply();
    try testing.expect(b.delete_count == null);
    b.request(.{ .activate = 4 });
    _ = b.apply();
    try testing.expectEqual(Prompt.none, b.prompt);
    try testing.expectEqualStrings("c-tool", b.picked().?.name);
    try testing.expect(b.file != null);
    b.request(.{ .prompt = .delete });
    _ = b.apply();
    b.request(.delete);
    _ = b.apply();
    try testing.expect(b.file == null);
    try testing.expectEqual(@as(usize, 4), b.listing.entries.len);

    // Nothing is asked without something picked; a link to a folder goes,
    // not the folder.
    b.request(.{ .prompt = .delete });
    _ = b.apply();
    try testing.expectEqual(Prompt.none, b.prompt);
    try testing.expectEqualStrings("z-link", b.listing.entries[1].name);
    b.selected = 1;
    b.request(.{ .prompt = .delete });
    _ = b.apply();
    b.request(.delete);
    _ = b.apply();
    try testing.expectEqualStrings("A-folder", b.listing.entries[0].name);
    try testing.expectEqual(@as(usize, 3), b.listing.entries.len);
}

test "USB drives: opened like the user's files, ejected, and gone" {
    var t: fs.TestTree = .{};
    try t.init();
    defer t.deinit();
    // A folder of its own stands for /media, with a drive in it.
    var buf: [128]u8 = undefined;
    const media = try std.fmt.bufPrintZ(&buf, "{s}-media", .{t.path});
    _ = std.os.linux.mkdir(media, 0o755);
    defer sys.files.removeTree(media);
    try fs.makeFolder(media, "STICK");
    var photo_buf: [160]u8 = undefined;
    try sys.files.writeNew(try std.fmt.bufPrintZ(&photo_buf, "{s}/STICK/photo", .{media}), "jpeg");
    var b = try Browser.init(testing.allocator, t.path);
    defer b.deinit();
    b.media_dir = media;
    b.refreshDrives();
    const Eject = struct {
        var answer: sys.media.Answer = .ejected;
        var asked: ?[]const u8 = null;
        fn f(name: []const u8) ?sys.media.Answer {
            asked = name;
            return answer;
        }
    };
    b.ejector = Eject.f;

    var drive_buf: [128]u8 = undefined;
    const drive = try std.fmt.bufPrint(&drive_buf, "{s}/STICK", .{media});
    try testing.expectEqualStrings("STICK", b.driveAt(drive).?);
    try testing.expect(b.driveAt(t.path) == null);
    try testing.expectEqualStrings(drive, b.rootOf(drive).?);
    // Its folder opens, and up stops there.
    b.request(.{ .open = drive });
    _ = b.apply();
    try testing.expectEqualStrings(drive, b.path);
    try testing.expectEqualStrings("photo", b.listing.entries[0].name);
    try testing.expect(b.atRoot());
    b.request(.up);
    _ = b.apply();
    try testing.expectEqualStrings(drive, b.path);

    // Busy: it stays, and says so; ejected: the user's files open.
    Eject.answer = .busy;
    b.request(.{ .eject = "STICK" });
    _ = b.apply();
    try testing.expectEqualStrings("STICK", Eject.asked.?);
    try testing.expectEqualStrings("\u{201c}STICK\u{201d} is in use: close what is open on it, then eject it again", b.notice().?);
    try testing.expectEqualStrings(t.path, b.path);
    b.request(.{ .open = drive });
    _ = b.apply();
    try testing.expect(b.notice() == null);
    Eject.answer = .ejected;
    b.request(.{ .eject = "STICK" });
    _ = b.apply();
    try testing.expectEqualStrings("You can take out \u{201c}STICK\u{201d} now", b.notice().?);
    try testing.expectEqualStrings(t.path, b.path);

    // Pulled out while open: back to the user's files.
    b.request(.{ .open = drive });
    _ = b.apply();
    try fs.delete(media, "STICK");
    b.refreshDrives();
    try testing.expectEqualStrings(t.path, b.path);
    try testing.expect(!b.isExpanded(drive));
    b.request(.{ .open = drive });
    _ = b.apply();
    try testing.expectEqualStrings(t.path, b.path);
}

fn finish(b: *Browser) void {
    while (b.poll()) sys.sleepMs(1);
}

test "copying and pasting, cutting and pasting, and dropping onto a folder" {
    var t: fs.TestTree = .{};
    try t.init();
    defer t.deinit();
    var b = try Browser.init(testing.allocator, t.path);
    defer b.deinit();
    // Nothing to paste yet.
    try testing.expect(!b.canPaste());

    // b-file copied and pasted in the same folder: "b-file (copy)", picked.
    b.request(.{ .pick = 2 });
    _ = b.apply();
    try testing.expectEqualStrings("b-file", b.picked().?.name);
    try testing.expect(b.file == null);
    b.request(.copy);
    _ = b.apply();
    try testing.expectEqualStrings("b-file", b.clipName().?);
    try testing.expect(b.canPaste());
    b.request(.paste);
    _ = b.apply();
    try testing.expect(b.copying());
    finish(&b);
    try testing.expectEqualStrings("b-file (copy)", b.picked().?.name);
    try testing.expectEqualStrings("b-file", b.clipName().?);

    // Cut, and pasted into A-folder: moved (and nothing left to paste).
    b.request(.cut);
    _ = b.apply();
    var buf: [128]u8 = undefined;
    const folder = try std.fmt.bufPrint(&buf, "{s}/A-folder", .{t.path});
    b.request(.{ .open = folder });
    _ = b.apply();
    b.request(.paste);
    _ = b.apply();
    finish(&b);
    try testing.expect(b.clip_path == null);
    try testing.expectEqualStrings("b-file (copy)", b.picked().?.name);
    b.request(.{ .open = t.path });
    _ = b.apply();
    for (b.listing.entries) |e| try testing.expect(!std.mem.eql(u8, e.name, "b-file (copy)"));

    // c-tool dropped onto A-folder: moved; with copy, copied.
    const tool = for (b.listing.entries, 0..) |e, i| {
        if (std.mem.eql(u8, e.name, "c-tool")) break i;
    } else unreachable;
    b.request(.{ .drop = .{ .index = tool, .into = folder, .copy = true } });
    _ = b.apply();
    finish(&b);
    try testing.expectEqualStrings("\u{201c}c-tool\u{201d} was copied to " ++ "", b.notice().?[0 .. "\u{201c}c-tool\u{201d} was copied to ".len]);
    b.request(.{ .drop = .{ .index = tool, .into = folder } });
    _ = b.apply();
    finish(&b);
    for (b.listing.entries) |e| try testing.expect(!std.mem.eql(u8, e.name, "c-tool"));
    // Into A-folder went "c-tool" and then "c-tool (copy)", beside "b-file (copy)".
    var l = fs.Listing.read(testing.allocator, folder);
    defer l.deinit();
    try testing.expectEqual(@as(usize, 3), l.entries.len);

    // A folder onto itself does nothing; into a folder in it, it says why.
    b.request(.{ .drop = .{ .index = 0, .into = folder } });
    _ = b.apply();
    try testing.expect(!b.copying());
    var inner_buf: [160]u8 = undefined;
    try fs.makeFolder(folder, "inner");
    b.request(.{ .drop = .{ .index = 0, .into = try std.fmt.bufPrint(&inner_buf, "{s}/inner", .{folder}) } });
    _ = b.apply();
    try testing.expect(!b.copying());
    try testing.expectEqualStrings("\u{201c}A-folder\u{201d} cannot be moved: a folder cannot go into itself", b.notice().?);
}

test "cancelling a copy" {
    var t: fs.TestTree = .{};
    try t.init();
    defer t.deinit();
    try t.write("big", "z" ** (1024 * 1024), 0o644);
    copier.test_chunk_delay_ms = 20;
    defer copier.test_chunk_delay_ms = 0;
    var b = try Browser.init(testing.allocator, t.path);
    defer b.deinit();
    const big = for (b.listing.entries, 0..) |e, i| {
        if (std.mem.eql(u8, e.name, "big")) break i;
    } else unreachable;
    var buf: [128]u8 = undefined;
    b.request(.{ .drop = .{ .index = big, .into = try std.fmt.bufPrint(&buf, "{s}/A-folder", .{t.path}), .copy = true } });
    _ = b.apply();
    try testing.expect(b.copying());
    b.request(.cancel_copy);
    _ = b.apply();
    finish(&b);
    try testing.expectEqualStrings("Stopped: \u{201c}big\u{201d} was only partly copied", b.notice().?);
    var l = fs.Listing.read(testing.allocator, buf[0 .. t.path.len + "/A-folder".len]);
    defer l.deinit();
    try testing.expectEqual(@as(usize, 0), l.entries.len);
}
