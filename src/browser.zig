//! What the Files window shows: the open folder (and what is in it), the
//! item picked in it (and what is in it, if it is a file: see
//! content.zig), and the folders opened in the tree (with the folders
//! in each, read when it is opened). Everything is within a root: the
//! user's files (`user_files`: /data/user, on the SD card) unless the
//! system's files are shown too, when it is /; nothing above it is opened.
//!
//! The window's widgets ask for changes (`request`); they are made between
//! frames (`apply`), so nothing a widget of the last frame points to (an
//! entry's name, say) is freed while events still go to it.

const std = @import("std");
const fs = @import("fs.zig");
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
};

pub const Browser = struct {
    gpa: std.mem.Allocator,
    /// Where the user's files are, and where the window starts.
    user_files: []const u8,
    /// The system's files are shown too: the root is / rather than `user_files`.
    show_system: bool = false,
    /// The open folder.
    path: []u8,
    listing: fs.Listing,
    /// The item picked in it.
    selected: ?usize = null,
    /// The file shown (the item picked), and what is in it.
    file: ?content.Content = null,
    /// The folders open in the tree, and the folders in each.
    expanded: std.StringHashMapUnmanaged(fs.Listing) = .empty,
    /// What was asked for since the last `apply`, and room for its path.
    pending: ?Action = null,
    pending_path: std.ArrayList(u8) = .empty,

    /// Starts at `user_files` (which must last as long as the browser), showing
    /// only what is in it.
    pub fn init(gpa: std.mem.Allocator, user_files: []const u8) !Browser {
        var b: Browser = .{ .gpa = gpa, .user_files = user_files, .path = try gpa.dupe(u8, user_files), .listing = fs.Listing.read(gpa, user_files) };
        try b.expand(user_files);
        return b;
    }

    /// The folder at the top of the tree; nothing above it is opened.
    pub fn root(b: *const Browser) []const u8 {
        return if (b.show_system) "/" else b.user_files;
    }

    pub fn atRoot(b: *const Browser) bool {
        return std.mem.eql(u8, b.path, b.root());
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
        b.gpa.free(b.path);
        b.pending_path.deinit(b.gpa);
    }

    /// Asks for `action` to be done at the next `apply` (the path is
    /// copied). A later request replaces an earlier one.
    pub fn request(b: *Browser, action: Action) void {
        var a = action;
        switch (a) {
            inline .open, .toggle => |path, tag| {
                b.pending_path.clearRetainingCapacity();
                b.pending_path.appendSlice(b.gpa, path) catch return;
                a = @unionInit(Action, @tagName(tag), b.pending_path.items);
            },
            else => {},
        }
        b.pending = a;
    }

    /// Does what was asked. Returns whether anything was.
    pub fn apply(b: *Browser) bool {
        const a = b.pending orelse return false;
        b.pending = null;
        switch (a) {
            .open => |path| b.open(path) catch {},
            .toggle => |path| b.toggle(path) catch {},
            .activate => |i| b.activate(i) catch {},
            .up => if (b.file != null) b.closeFile() else if (!b.atRoot()) b.open(fs.parent(b.path)) catch {},
            .show_system => |on| b.showSystem(on) catch {},
        }
        return true;
    }

    /// Shows the system's files too, or only the user's (going back to the user's files if the
    /// open folder is not among them).
    pub fn showSystem(b: *Browser, on: bool) !void {
        b.show_system = on;
        try b.expand(b.root());
        if (!fs.within(b.path, b.root())) try b.open(b.user_files) else try b.expandTo(b.path);
    }

    /// Shows the folder at `path` (if it is within the root), opening the
    /// folders above it in the tree.
    pub fn open(b: *Browser, path: []const u8) !void {
        if (!fs.within(path, b.root())) return;
        const new = try b.gpa.dupe(u8, path);
        b.gpa.free(b.path);
        b.path = new;
        b.closeFile();
        b.listing.deinit();
        b.listing = fs.Listing.read(b.gpa, new);
        b.selected = null;
        try b.expandTo(new);
    }

    fn activate(b: *Browser, i: usize) !void {
        if (i >= b.listing.entries.len) return;
        const e = b.listing.entries[i];
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
        var end: usize = 0;
        while (end < path.len) {
            const ancestor = if (end == 0) "/" else path[0..end];
            if (fs.within(ancestor, b.root()) and !b.isExpanded(ancestor)) try b.expand(ancestor);
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
