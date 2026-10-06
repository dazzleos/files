//! What is in a folder: its entries, read with getdents64 and statx (which
//! follows symbolic links, so a link to a folder can be opened like one).
//! Names starting with a dot are left out.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");

pub const Kind = enum {
    folder,
    file,
    /// A file anyone may run.
    program,
    /// A character or block device (in /dev).
    device,
    /// A pipe or socket, or a link to nothing.
    other,
};

pub const Entry = struct {
    name: []const u8,
    kind: Kind,
    /// A symbolic link (to something of `kind`).
    link: bool = false,
    /// In bytes, for files.
    size: u64 = 0,
    /// For folders: whether there are folders in it, if that is known.
    subfolders: ?bool = null,
};

/// The most entries read from one folder.
pub const max_entries = 1000;

pub const Listing = struct {
    arena: std.heap.ArenaAllocator,
    /// Folders first, then the rest; each by name, ignoring case.
    entries: []Entry = &.{},
    /// Why it could not be read, if it could not.
    err: ?sys.Error = null,
    /// There were more than `max_entries`; this many.
    total: usize = 0,

    /// Reads the folder at `path`. It always gives a listing: an empty one,
    /// with `err`, if the folder cannot be read.
    pub fn read(gpa: std.mem.Allocator, path: []const u8) Listing {
        var l: Listing = .{ .arena = .init(gpa) };
        l.readInto(path) catch |e| {
            l.entries = &.{};
            l.err = e;
        };
        return l;
    }

    pub fn deinit(l: *Listing) void {
        l.arena.deinit();
    }

    /// The folders in it (they come first).
    pub fn folders(l: *const Listing) []const Entry {
        for (l.entries, 0..) |e, i| if (e.kind != .folder) return l.entries[0..i];
        return l.entries;
    }

    fn readInto(l: *Listing, path: []const u8) sys.Error!void {
        const a = l.arena.allocator();
        const path_z = a.dupeZ(u8, path) catch return error.OutOfMemory;
        const dir = try sys.open(path_z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
        defer sys.close(dir);
        var entries: std.ArrayList(Entry) = .empty;
        var buf: [4096]u8 align(8) = undefined;
        while (true) {
            const n = try sys.check(linux.getdents64(dir, &buf, buf.len));
            if (n == 0) break;
            var at: usize = 0;
            while (at < n) {
                const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
                const d_type = buf[at + 18];
                // The name is NUL-terminated in the buffer.
                const name_z: [*:0]const u8 = @ptrCast(&buf[at + 19]);
                const name = std.mem.span(name_z);
                at += reclen;
                if (name.len == 0 or name[0] == '.') continue;
                l.total += 1;
                if (entries.items.len == max_entries) continue;
                var e: Entry = .{ .name = a.dupe(u8, name) catch return error.OutOfMemory, .kind = .other, .link = d_type == dt_lnk };
                var stx: linux.Statx = undefined;
                if (linux.errno(linux.statx(dir, name_z, 0, .{ .TYPE = true, .MODE = true, .SIZE = true, .NLINK = true }, &stx)) == .SUCCESS) {
                    e.kind = kindOf(stx.mode);
                    if (e.kind == .file or e.kind == .program) e.size = stx.size;
                    if (e.kind == .folder and stx.mask.NLINK) e.subfolders = hasSubfolders(stx.nlink);
                }
                entries.append(a, e) catch return error.OutOfMemory;
            }
        }
        std.mem.sort(Entry, entries.items, {}, before);
        l.entries = entries.items;
    }
};

const dt_lnk = 10;

/// Whether a folder with `nlink` links has folders in it: each has a link
/// to it (its ".."), as do its own "." and its name in its parent. Some
/// filesystems (btrfs) do not count them: unknown.
fn hasSubfolders(nlink: u32) ?bool {
    return if (nlink < 2) null else nlink > 2;
}

fn kindOf(mode: u16) Kind {
    return switch (mode & linux.S.IFMT) {
        linux.S.IFDIR => .folder,
        linux.S.IFREG => if (mode & 0o001 != 0) .program else .file,
        linux.S.IFCHR, linux.S.IFBLK => .device,
        else => .other,
    };
}

/// Folders first, then by name, ignoring case.
fn before(_: void, a: Entry, b: Entry) bool {
    const af = a.kind == .folder;
    const bf = b.kind == .folder;
    if (af != bf) return af;
    return switch (std.ascii.orderIgnoreCase(a.name, b.name)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.lessThan(u8, a.name, b.name),
    };
}

/// `name` in the folder `dir`.
pub fn join(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (std.mem.eql(u8, dir, "/")) return std.fmt.allocPrint(gpa, "/{s}", .{name});
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
}

/// The folder holding `path` ("/" for "/" itself).
pub fn parent(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "/";
    return if (i == 0) "/" else path[0..i];
}

/// The last part of `path` ("/" for "/").
pub fn baseName(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "/")) return "/";
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[i + 1 ..];
}

/// Whether `path` is `ancestor` or inside it.
pub fn within(path: []const u8, ancestor: []const u8) bool {
    if (std.mem.eql(u8, ancestor, "/")) return path.len > 0 and path[0] == '/';
    return std.mem.startsWith(u8, path, ancestor) and (path.len == ancestor.len or path[ancestor.len] == '/');
}

/// A size for people: "512 bytes", "12.3 kB", "4.0 MB".
pub fn formatSize(buf: []u8, size: u64) []const u8 {
    if (size < 1000) return std.fmt.bufPrint(buf, "{d} {s}", .{ size, if (size == 1) "byte" else "bytes" }) catch "";
    const units = [_][]const u8{ "kB", "MB", "GB", "TB" };
    var v: f64 = @floatFromInt(size);
    var i: usize = 0;
    v /= 1000;
    while (v >= 1000 and i + 1 < units.len) : (i += 1) v /= 1000;
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[i] }) catch "";
}

const testing = std.testing;

test "paths" {
    const gpa = testing.allocator;
    const a = try join(gpa, "/", "proc");
    defer gpa.free(a);
    try testing.expectEqualStrings("/proc", a);
    const b = try join(gpa, "/proc", "self");
    defer gpa.free(b);
    try testing.expectEqualStrings("/proc/self", b);
    try testing.expectEqualStrings("/", parent("/proc"));
    try testing.expectEqualStrings("/proc", parent("/proc/self"));
    try testing.expectEqualStrings("/", parent("/"));
    try testing.expectEqualStrings("self", baseName("/proc/self"));
    try testing.expectEqualStrings("/", baseName("/"));
    try testing.expect(within("/proc/self", "/proc"));
    try testing.expect(within("/proc", "/proc"));
    try testing.expect(!within("/procfs", "/proc"));
    try testing.expect(within("/proc", "/"));
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1 byte", formatSize(&buf, 1));
    try testing.expectEqualStrings("999 bytes", formatSize(&buf, 999));
    try testing.expectEqualStrings("12.3 kB", formatSize(&buf, 12345));
    try testing.expectEqualStrings("4.0 MB", formatSize(&buf, 4_000_000));
}

/// A folder of test files, removed by `deinit`.
pub const TestTree = struct {
    path_buf: [64]u8 = undefined,
    path: []const u8 = "",

    /// Makes `<tmp>/b-file` (5 bytes), `<tmp>/A-folder/`, `<tmp>/c-tool`
    /// (executable), `<tmp>/.hidden`, `<tmp>/z-link` (to A-folder) and
    /// `<tmp>/broken` (a link to nothing).
    pub fn init(t: *TestTree) !void {
        t.path = try std.fmt.bufPrint(&t.path_buf, "/tmp/dazzle-files-test-{d}", .{linux.getpid()});
        var z: [128]u8 = undefined;
        _ = linux.mkdir(try std.fmt.bufPrintZ(&z, "{s}", .{t.path}), 0o755);
        _ = linux.mkdir(try std.fmt.bufPrintZ(&z, "{s}/A-folder", .{t.path}), 0o755);
        try t.write("b-file", "hello", 0o644);
        try t.write("c-tool", "#!/bin/sh\n", 0o755);
        try t.write(".hidden", "", 0o644);
        _ = linux.symlink("A-folder", try std.fmt.bufPrintZ(&z, "{s}/z-link", .{t.path}));
        _ = linux.symlink("nowhere", try std.fmt.bufPrintZ(&z, "{s}/broken", .{t.path}));
    }

    fn write(t: *TestTree, name: []const u8, data: []const u8, mode: linux.mode_t) !void {
        var z: [128]u8 = undefined;
        const fd = try sys.open(try std.fmt.bufPrintZ(&z, "{s}/{s}", .{ t.path, name }), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true });
        defer sys.close(fd);
        _ = linux.fchmod(fd, mode);
        _ = linux.write(fd, data.ptr, data.len);
    }

    pub fn deinit(t: *TestTree) void {
        var z: [128]u8 = undefined;
        for ([_][]const u8{ "b-file", "c-tool", ".hidden", "z-link", "broken" }) |name| {
            _ = linux.unlink(std.fmt.bufPrintZ(&z, "{s}/{s}", .{ t.path, name }) catch continue);
        }
        _ = linux.rmdir(std.fmt.bufPrintZ(&z, "{s}/A-folder", .{t.path}) catch return);
        _ = linux.rmdir(std.fmt.bufPrintZ(&z, "{s}", .{t.path}) catch return);
    }
};

test "a listing has folders first, then files by name, with their kinds" {
    var t: TestTree = .{};
    try t.init();
    defer t.deinit();
    var l = Listing.read(testing.allocator, t.path);
    defer l.deinit();
    try testing.expect(l.err == null);
    const want = [_]struct { []const u8, Kind, bool }{
        .{ "A-folder", .folder, false },
        .{ "z-link", .folder, true },
        .{ "b-file", .file, false },
        .{ "broken", .other, true },
        .{ "c-tool", .program, false },
    };
    try testing.expectEqual(want.len, l.entries.len);
    for (want, l.entries) |w, e| {
        try testing.expectEqualStrings(w[0], e.name);
        try testing.expectEqual(w[1], e.kind);
        try testing.expectEqual(w[2], e.link);
    }
    try testing.expectEqual(@as(u64, 5), l.entries[2].size);
    try testing.expectEqual(@as(usize, 2), l.folders().len);
    // A-folder (and the link to it) has no folders in it.
    try testing.expectEqual(@as(?bool, false), l.entries[0].subfolders);
    try testing.expectEqual(@as(?bool, false), l.entries[1].subfolders);
    try testing.expectEqual(@as(?bool, null), l.entries[2].subfolders);
    // The test folder has.
    var tmp = Listing.read(testing.allocator, parent(t.path));
    defer tmp.deinit();
    for (tmp.entries) |e| if (std.mem.eql(u8, e.name, baseName(t.path))) {
        try testing.expect(e.subfolders orelse true);
    };
    try testing.expectEqual(@as(?bool, null), hasSubfolders(1));

    // A folder that is not there gives an empty listing, saying why.
    var missing = Listing.read(testing.allocator, "/nonexistent-dazzle-folder");
    defer missing.deinit();
    try testing.expectEqual(@as(?sys.Error, error.NotFound), missing.err);
    try testing.expectEqual(@as(usize, 0), missing.entries.len);
}
