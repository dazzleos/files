//! What the Files window shows: the open folder (and what is in it), the
//! item picked in it, and the folders opened in the tree (with the folders
//! in each, read when it is opened).
//!
//! The window's widgets ask for changes (`request`); they are made between
//! frames (`apply`), so nothing a widget of the last frame points to (an
//! entry's name, say) is freed while events still go to it.

const std = @import("std");
const fs = @import("fs.zig");

pub const Action = union(enum) {
    /// Show this folder.
    open: []const u8,
    /// Open or close this folder in the tree.
    toggle: []const u8,
    /// An item in the open folder (an index into its entries): a folder is
    /// opened, anything else picked.
    activate: usize,
    /// The folder holding the open one.
    up,
};

pub const Browser = struct {
    gpa: std.mem.Allocator,
    /// The open folder.
    path: []u8,
    listing: fs.Listing,
    /// The item picked in it.
    selected: ?usize = null,
    /// The folders open in the tree, and the folders in each.
    expanded: std.StringHashMapUnmanaged(fs.Listing) = .empty,
    /// What was asked for since the last `apply`, and room for its path.
    pending: ?Action = null,
    pending_path: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, start: []const u8) !Browser {
        var b: Browser = .{ .gpa = gpa, .path = try gpa.dupe(u8, start), .listing = fs.Listing.read(gpa, start) };
        try b.expandTo(start);
        try b.expand(start);
        return b;
    }

    pub fn deinit(b: *Browser) void {
        var it = b.expanded.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit();
            b.gpa.free(e.key_ptr.*);
        }
        b.expanded.deinit(b.gpa);
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
            .up => b.open(fs.parent(b.path)) catch {},
        }
        return true;
    }

    /// Shows the folder at `path`, opening the folders above it in the
    /// tree.
    pub fn open(b: *Browser, path: []const u8) !void {
        const new = try b.gpa.dupe(u8, path);
        b.gpa.free(b.path);
        b.path = new;
        b.listing.deinit();
        b.listing = fs.Listing.read(b.gpa, new);
        b.selected = null;
        try b.expandTo(new);
    }

    fn activate(b: *Browser, i: usize) !void {
        if (i >= b.listing.entries.len) return;
        const e = b.listing.entries[i];
        if (e.kind != .folder) {
            b.selected = i;
            return;
        }
        const path = try fs.join(b.gpa, b.path, e.name);
        defer b.gpa.free(path);
        try b.open(path);
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

    /// Opens the folders above `path` (not `path` itself) in the tree.
    fn expandTo(b: *Browser, path: []const u8) !void {
        var end: usize = 0;
        while (end < path.len) {
            const ancestor = if (end == 0) "/" else path[0..end];
            if (!b.isExpanded(ancestor)) try b.expand(ancestor);
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

test "opening folders, from the tree and the grid, and going up" {
    var t: fs.TestTree = .{};
    try t.init();
    defer t.deinit();
    var b = try Browser.init(testing.allocator, t.path);
    defer b.deinit();
    // The folders above the start are open in the tree, and so is it.
    try testing.expect(b.isExpanded("/"));
    try testing.expect(b.isExpanded("/tmp"));
    try testing.expect(b.isExpanded(t.path));
    try testing.expectEqual(@as(usize, 2), b.subfolders(t.path).len);
    try testing.expectEqual(@as(usize, 5), b.listing.entries.len);

    // A file is picked; a folder is opened.
    b.request(.{ .activate = 2 });
    try testing.expect(b.apply());
    try testing.expectEqual(@as(?usize, 2), b.selected);
    b.request(.{ .activate = 0 });
    _ = b.apply();
    try testing.expect(std.mem.endsWith(u8, b.path, "/A-folder"));
    try testing.expectEqual(@as(?usize, null), b.selected);
    try testing.expectEqual(@as(usize, 0), b.listing.entries.len);
    try testing.expect(!b.apply());

    // Up, and closing and opening a folder in the tree.
    b.request(.up);
    _ = b.apply();
    try testing.expectEqualStrings(t.path, b.path);
    b.request(.{ .toggle = t.path });
    _ = b.apply();
    try testing.expect(!b.isExpanded(t.path));
    try testing.expectEqual(@as(usize, 0), b.subfolders(t.path).len);
    b.request(.{ .toggle = t.path });
    _ = b.apply();
    try testing.expect(b.isExpanded(t.path));

    // Opening a folder from the tree opens the folders above it.
    b.request(.{ .toggle = "/tmp" });
    _ = b.apply();
    try testing.expect(!b.isExpanded("/tmp"));
    var sub_buf: [128]u8 = undefined;
    const sub = try std.fmt.bufPrint(&sub_buf, "{s}/A-folder", .{t.path});
    b.request(.{ .open = sub });
    _ = b.apply();
    try testing.expect(b.isExpanded("/tmp"));
    try testing.expectEqualStrings(sub, b.path);
}
