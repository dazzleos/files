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
    /// When it was last changed, in seconds since 1970.
    modified: i64 = 0,
    /// For folders: whether there are folders in it, if that is known.
    subfolders: ?bool = null,
    /// For folders: whether things can be made in it. The system's are
    /// locked.
    writable: bool = true,
};

/// The most entries read from one folder.
pub const max_entries = 1000;

/// The order of a folder's items: folders first either way, then by name
/// (ignoring case), or the most recently changed first.
pub const Order = enum { name, newest };

pub const Listing = struct {
    arena: std.heap.ArenaAllocator,
    /// Folders first, then the rest; each by name, ignoring case (unless
    /// sorted otherwise, `sort`).
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

    /// Puts the items in `order` (they are read by name).
    pub fn sort(l: *Listing, order: Order) void {
        std.mem.sort(Entry, l.entries, order, before);
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
                if (linux.errno(linux.statx(dir, name_z, 0, .{ .TYPE = true, .MODE = true, .SIZE = true, .NLINK = true, .MTIME = true }, &stx)) == .SUCCESS) {
                    e.kind = kindOf(stx.mode);
                    e.modified = stx.mtime.sec;
                    if (e.kind == .file or e.kind == .program) e.size = stx.size;
                    if (e.kind == .folder and stx.mask.NLINK) e.subfolders = hasSubfolders(stx.nlink);
                    if (e.kind == .folder) e.writable = linux.faccessat(dir, name_z, linux.W_OK, 0) == 0;
                }
                entries.append(a, e) catch return error.OutOfMemory;
            }
        }
        l.entries = entries.items;
        l.sort(.name);
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

/// Folders first, then in `order` (by name for ties).
fn before(order: Order, a: Entry, b: Entry) bool {
    const af = a.kind == .folder;
    const bf = b.kind == .folder;
    if (af != bf) return af;
    if (order == .newest and a.modified != b.modified) return a.modified > b.modified;
    return switch (std.ascii.orderIgnoreCase(a.name, b.name)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.lessThan(u8, a.name, b.name),
    };
}

/// Whether things can be made in the folder at `path`.
pub fn writable(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return false;
    return linux.access(z, linux.W_OK) == 0;
}

/// What the folder at `path` is for, in a line, if it is one of the
/// system's (or the user's files).
pub fn describe(path: []const u8) ?[]const u8 {
    for (descriptions) |d| if (std.mem.eql(u8, path, d[0])) return d[1];
    // Each running program has a folder in /proc, named by its number.
    if (std.mem.startsWith(u8, path, "/proc/")) {
        _ = std.fmt.parseInt(u32, path["/proc/".len..], 10) catch return null;
        return "A program that is running";
    }
    return null;
}

const descriptions = [_]struct { []const u8, []const u8 }{
    .{ "/", "Everything on this computer" },
    .{ "/os", "Dazzle itself: what makes the computer work" },
    .{ "/os/shell", "The desktop, and the apps that are part of it" },
    .{ "/os/firmware", "Programs that run inside hardware, like the Wi-Fi adapter" },
    .{ sys.fonts_dir, "The lettering the apps use" },
    .{ "/os/sockets", "Where the system's services listen for apps" },
    .{ sys.system.data_dir, "The SD card's space for files and settings" },
    .{ sys.system.config_dir, "This computer's settings" },
    .{ sys.system.user_dir, "Your files" },
    .{ sys.system.apps_dir, "The apps you have installed" },
    .{ sys.system.update_dir, "Updates of Dazzle, while they are installed" },
    .{ sys.media.media_dir, "The USB drives plugged in" },
    .{ "/dev", "The devices in this computer" },
    .{ "/dev/dri", "The graphics processor" },
    .{ "/dev/input", "Keyboards, mice and other ways of controlling the computer" },
    .{ "/dev/snd", "Sound devices" },
    .{ "/dev/pts", "Text terminals" },
    .{ "/dev/shm", "Memory programs share with each other" },
    .{ "/proc", "The programs that are running, and what Linux knows about them" },
    .{ "/sys", "The hardware, as Linux sees it" },
    .{ "/sys/block", "Storage, like the SD card" },
    .{ "/sys/bus", "The connections hardware is attached by, like USB" },
    .{ "/sys/class", "The hardware, grouped by what it does" },
    .{ "/sys/devices", "All the hardware, as it is connected" },
    .{ "/sys/firmware", "What the computer's firmware told Linux about the hardware" },
    .{ "/sys/fs", "Filesystems: how files are stored" },
    .{ "/sys/kernel", "Linux's own settings" },
    .{ "/sys/module", "The parts of Linux that are loaded" },
    .{ "/sys/power", "Power and sleep" },
};

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

pub const ChangeError = error{
    /// Not a name a folder can have here.
    BadName,
    /// Something of that name is there already.
    Exists,
    AccessDenied,
    /// What was to be deleted is not there any more.
    NotFound,
    /// Part of it could not be deleted.
    NotDeleted,
    Unexpected,
};

/// Why a change could not be made, for people.
pub fn describeError(err: ChangeError) []const u8 {
    return switch (err) {
        error.BadName => "use a name without / that does not start with a dot",
        error.Exists => "there is already something with that name",
        error.AccessDenied => "you are not allowed to change this folder",
        error.NotFound => "it is not there any more",
        error.NotDeleted => "some of what is in it could not be deleted",
        error.Unexpected => "something went wrong",
    };
}

/// Whether `name` can be a new folder's: not empty, no "/", and not
/// starting with a dot (those are hidden, here).
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255 or name[0] == '.') return false;
    return std.mem.indexOfScalar(u8, name, '/') == null and std.mem.indexOfScalar(u8, name, 0) == null;
}

/// Makes the folder `name` in the folder at `dir`.
pub fn makeFolder(dir: []const u8, name: []const u8) ChangeError!void {
    if (!validName(name)) return error.BadName;
    var buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name }) catch return error.BadName;
    return switch (linux.errno(linux.mkdir(path, 0o755))) {
        .SUCCESS => {},
        .EXIST => error.Exists,
        .ACCES, .PERM, .ROFS => error.AccessDenied,
        .NOENT => error.NotFound,
        .NAMETOOLONG => error.BadName,
        else => error.Unexpected,
    };
}

/// Makes the empty file `name` in the folder at `dir`.
pub fn makeFile(dir: []const u8, name: []const u8) ChangeError!void {
    if (!validName(name)) return error.BadName;
    var buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name }) catch return error.BadName;
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o644);
    return switch (linux.errno(rc)) {
        .SUCCESS => sys.close(@intCast(rc)),
        .EXIST => error.Exists,
        .ACCES, .PERM, .ROFS => error.AccessDenied,
        .NOENT => error.NotFound,
        .NAMETOOLONG => error.BadName,
        else => error.Unexpected,
    };
}

/// The endings of the names of files that are plain text.
const text_extensions = [_][]const u8{
    "txt", "text", "md",  "log", "csv",  "tsv", "json", "xml",  "conf", "cfg", "ini",
    "toml", "yaml", "yml", "sh",  "zig", "c",   "h",    "cpp",  "py",   "js",  "css",
    "html", "htm", "rs",  "go",  "lua",  "srt",
};

/// Whether a file named `name` is plain text, by the ending of its name.
pub fn isTextName(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    if (dot == 0) return false;
    const ext = name[dot + 1 ..];
    for (text_extensions) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

/// Deletes `name` from the folder at `dir`: a file, or a folder and
/// everything in it. A link is deleted itself, not what it leads to.
pub fn delete(dir: []const u8, name: []const u8) ChangeError!void {
    var buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name }) catch return error.NotFound;
    var stx: linux.Statx = undefined;
    switch (linux.errno(linux.statx(linux.AT.FDCWD, path, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &stx))) {
        .SUCCESS => {},
        .NOENT => return error.NotFound,
        else => return error.Unexpected,
    }
    if (stx.mode & linux.S.IFMT == linux.S.IFDIR) {
        sys.files.removeTree(path);
        // What could not be deleted is still there.
        return switch (linux.errno(linux.statx(linux.AT.FDCWD, path, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &stx))) {
            .NOENT => {},
            .SUCCESS => if (writable(dir)) error.NotDeleted else error.AccessDenied,
            else => error.Unexpected,
        };
    }
    return switch (linux.errno(linux.unlink(path))) {
        .SUCCESS => {},
        .NOENT => error.NotFound,
        .ACCES, .PERM, .ROFS => error.AccessDenied,
        else => error.Unexpected,
    };
}

/// How many things are in the folder at `path` (hidden ones too), for
/// saying what deleting it deletes; null if it cannot be read.
pub fn countItems(path: []const u8) ?usize {
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return null;
    const dir = sys.open(z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch return null;
    defer sys.close(dir);
    var count: usize = 0;
    var dents: [4096]u8 align(8) = undefined;
    while (true) {
        const n = sys.check(linux.getdents64(dir, &dents, dents.len)) catch return null;
        if (n == 0) return count;
        var at: usize = 0;
        while (at < n) {
            const reclen = std.mem.readInt(u16, dents[at + 16 ..][0..2], .little);
            const name = std.mem.sliceTo(dents[at + 19 .. at + reclen], 0);
            at += reclen;
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) count += 1;
        }
    }
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

test "the newest first, folders still first" {
    var l: Listing = .{ .arena = .init(testing.allocator) };
    defer l.deinit();
    var entries = [_]Entry{
        .{ .name = "b.txt", .kind = .file, .modified = 300 },
        .{ .name = "old", .kind = .folder, .modified = 100 },
        .{ .name = "A.txt", .kind = .file, .modified = 100 },
        .{ .name = "new", .kind = .folder, .modified = 900 },
        .{ .name = "c.txt", .kind = .file, .modified = 300 },
    };
    l.entries = &entries;
    l.sort(.newest);
    const newest = [_][]const u8{ "new", "old", "b.txt", "c.txt", "A.txt" };
    for (newest, l.entries) |want, e| try testing.expectEqualStrings(want, e.name);
    l.sort(.name);
    const by_name = [_][]const u8{ "new", "old", "A.txt", "b.txt", "c.txt" };
    for (by_name, l.entries) |want, e| try testing.expectEqualStrings(want, e.name);
}

test "the system's folders are described" {
    try testing.expectEqualStrings("The devices in this computer", describe("/dev").?);
    try testing.expectEqualStrings("Your files", describe("/data/user").?);
    try testing.expectEqualStrings("A program that is running", describe("/proc/1").?);
    try testing.expect(describe("/proc/self") == null);
    try testing.expect(describe("/dev/null") == null);
    try testing.expect(describe("/data/user/photos") == null);
}

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

test "text files, by name" {
    try testing.expect(isTextName("notes.txt"));
    try testing.expect(isTextName("README.MD"));
    try testing.expect(isTextName("a.b.json"));
    try testing.expect(!isTextName("photo.png"));
    try testing.expect(!isTextName("txt"));
    try testing.expect(!isTextName(".txt"));
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

    pub fn write(t: *TestTree, name: []const u8, data: []const u8, mode: linux.mode_t) !void {
        var z: [128]u8 = undefined;
        const fd = try sys.open(try std.fmt.bufPrintZ(&z, "{s}/{s}", .{ t.path, name }), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true });
        defer sys.close(fd);
        _ = linux.fchmod(fd, mode);
        _ = linux.write(fd, data.ptr, data.len);
    }

    pub fn deinit(t: *TestTree) void {
        var z: [128]u8 = undefined;
        sys.files.removeTree(std.fmt.bufPrintZ(&z, "{s}", .{t.path}) catch return);
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
    // The test's own folders can be changed.
    try testing.expect(l.entries[0].writable);
    try testing.expect(writable(t.path));
    try testing.expect(!writable("/nonexistent-dazzle-folder"));

    // A folder that is not there gives an empty listing, saying why.
    var missing = Listing.read(testing.allocator, "/nonexistent-dazzle-folder");
    defer missing.deinit();
    try testing.expectEqual(@as(?sys.Error, error.NotFound), missing.err);
    try testing.expectEqual(@as(usize, 0), missing.entries.len);
}

test "making folders, and deleting files, links and folders with what is in them" {
    var t: TestTree = .{};
    try t.init();
    defer t.deinit();
    try testing.expect(!validName(""));
    try testing.expect(!validName(".hidden"));
    try testing.expect(!validName("a/b"));
    try testing.expect(validName("Holiday photos"));
    try makeFolder(t.path, "New");
    try testing.expectError(error.Exists, makeFolder(t.path, "New"));
    try testing.expectError(error.BadName, makeFolder(t.path, "../escape"));
    var buf: [128]u8 = undefined;
    const new = try std.fmt.bufPrint(&buf, "{s}/New", .{t.path});
    try makeFolder(new, "inner");
    try t.write("New/inner/note", "hi", 0o644);
    try t.write("New/.dot", "", 0o644);
    try testing.expectEqual(@as(?usize, 2), countItems(new));
    // A link to a folder goes, and the folder stays.
    try delete(t.path, "z-link");
    try testing.expectEqual(@as(?usize, 0), countItems(try std.fmt.bufPrint(&buf, "{s}/A-folder", .{t.path})));
    try delete(t.path, "New");
    try testing.expectError(error.NotFound, delete(t.path, "New"));
    try delete(t.path, "b-file");
    try delete(t.path, "broken");
    var l = Listing.read(testing.allocator, t.path);
    defer l.deinit();
    try testing.expectEqual(@as(usize, 2), l.entries.len);
}
