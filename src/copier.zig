//! Copying and moving a file or folder (and everything in it) into a
//! folder, a little at a time (`step`), so the window keeps responding
//! while a big copy goes to a slow USB drive.
//!
//! A move within a filesystem is a rename, done at once. Otherwise
//! everything is copied: first what there is is listed (and its size
//! added up, for the progress), then folders are made and files copied
//! (with their permissions and when they were changed), and links are made
//! again as links. A move then deletes what was copied, if all of it was.
//! Devices and the like are left out.
//!
//! What is made is named as the original, or, if something of that name
//! is there already, "<name> (copy)", "<name> (copy 2)" and so on: nothing
//! is ever replaced.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const fs = @import("fs.zig");

pub const Error = error{
    /// Into itself (or a folder in it).
    IntoItself,
    NotFound,
    AccessDenied,
    /// The drive is full.
    NoSpace,
    Unexpected,
};

pub fn describeError(err: Error) []const u8 {
    return switch (err) {
        error.IntoItself => "a folder cannot go into itself",
        error.NotFound => "it is not there any more",
        error.AccessDenied => "you are not allowed to change that folder",
        error.NoSpace => "there is no space left there",
        error.Unexpected => "something went wrong",
    };
}

const Kind = enum { folder, file, link, other };

/// Something to copy: where it is under what is copied ("" for that
/// itself).
const Item = struct {
    rel: []const u8,
    kind: Kind,
    size: u64,
    mode: u32,
    mtime: linux.statx_timestamp,
};

const chunk = 256 * 1024;

pub const Copier = struct {
    arena: std.heap.ArenaAllocator,
    /// What is copied (or moved), and the folder it goes into.
    source: []const u8,
    into: []const u8,
    /// The name it has there.
    name: []const u8,
    move: bool,
    phase: enum { scan, copy, remove, done } = .scan,
    items: std.ArrayList(Item) = .empty,
    /// Folders still to be listed (indexes into `items`).
    to_scan: std.ArrayList(usize) = .empty,
    /// The next item to copy, and the file being copied, if one is.
    next: usize = 0,
    file: ?struct { src: linux.fd_t, dst: linux.fd_t, item: usize } = null,
    buf: ?[]u8 = null,
    /// How far it has got.
    total_bytes: u64 = 0,
    done_bytes: u64 = 0,
    /// What could not be copied (other than what stops it all, `err`).
    skipped: usize = 0,
    err: ?Error = null,
    cancelled: bool = false,

    /// Starts copying (or moving) `source` into the folder `into`.
    pub fn start(gpa: std.mem.Allocator, source: []const u8, into: []const u8, move: bool) Error!*Copier {
        if (fs.within(into, source)) return error.IntoItself;
        const c = gpa.create(Copier) catch return error.Unexpected;
        c.* = .{ .arena = .init(gpa), .source = "", .into = "", .name = "", .move = move };
        errdefer c.deinit();
        const a = c.arena.allocator();
        c.source = a.dupe(u8, source) catch return error.Unexpected;
        c.into = a.dupe(u8, into) catch return error.Unexpected;
        const top = stat(source) orelse return error.NotFound;
        c.name = freeName(a, into, fs.baseName(source)) catch return error.Unexpected;
        // Moving within a filesystem: renamed, and done.
        if (move) {
            const from = a.dupeZ(u8, source) catch return error.Unexpected;
            const to = c.path("") catch return error.Unexpected;
            switch (linux.errno(linux.rename(from, to))) {
                .SUCCESS => {
                    c.phase = .done;
                    return c;
                },
                .XDEV => {},
                .ACCES, .PERM, .ROFS => return error.AccessDenied,
                .NOENT => return error.NotFound,
                else => return error.Unexpected,
            }
        }
        c.items.append(a, top.item("")) catch return error.Unexpected;
        c.total_bytes = top.item("").size;
        if (top.kind == .folder) c.to_scan.append(a, 0) catch return error.Unexpected;
        return c;
    }

    pub fn deinit(c: *Copier) void {
        c.closeFile(false);
        const gpa = c.arena.child_allocator;
        c.arena.deinit();
        gpa.destroy(c);
    }

    pub fn done(c: *const Copier) bool {
        return c.phase == .done;
    }

    /// Stops; a file part copied is deleted (what was copied before stays).
    pub fn cancel(c: *Copier) void {
        if (c.phase != .done) c.cancelled = true;
        c.closeFile(true);
        c.phase = .done;
    }

    /// Works for about `budget_ns`. Returns whether it has finished.
    pub fn step(c: *Copier, budget_ns: u64) bool {
        const end = sys.nowNs() + budget_ns;
        // At least one piece of work, however short the time.
        while (c.phase != .done) {
            c.work();
            if (sys.nowNs() >= end) break;
        }
        return c.phase == .done;
    }

    fn work(c: *Copier) void {
        switch (c.phase) {
            .scan => c.scanOne(),
            .copy => c.copyOne(),
            .remove => {
                // Everything was copied: the original goes.
                if (c.skipped == 0) fs.delete(fs.parent(c.source), fs.baseName(c.source)) catch |err| {
                    c.err = switch (err) {
                        error.AccessDenied => error.AccessDenied,
                        else => error.Unexpected,
                    };
                };
                c.phase = .done;
            },
            .done => {},
        }
    }

    /// Lists one folder.
    fn scanOne(c: *Copier) void {
        const index = c.to_scan.pop() orelse {
            c.phase = .copy;
            return;
        };
        const a = c.arena.allocator();
        const rel = c.items.items[index].rel;
        const dir_path = (if (rel.len == 0) a.dupeZ(u8, c.source) else std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ c.source, rel }, 0)) catch return c.fail(error.Unexpected);
        const dir = sys.open(dir_path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch {
            c.skipped += 1;
            return;
        };
        defer sys.close(dir);
        var dents: [4096]u8 align(8) = undefined;
        while (true) {
            const n = sys.check(linux.getdents64(dir, &dents, dents.len)) catch break;
            if (n == 0) break;
            var at: usize = 0;
            while (at < n) {
                const reclen = std.mem.readInt(u16, dents[at + 16 ..][0..2], .little);
                const name = std.mem.sliceTo(dents[at + 19 .. at + reclen], 0);
                at += reclen;
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                const child = (if (rel.len == 0) a.dupe(u8, name) else std.fmt.allocPrint(a, "{s}/{s}", .{ rel, name })) catch return c.fail(error.Unexpected);
                const full = std.fmt.allocPrint(a, "{s}/{s}", .{ c.source, child }) catch return c.fail(error.Unexpected);
                const st = stat(full) orelse {
                    c.skipped += 1;
                    continue;
                };
                const item = st.item(child);
                c.items.append(a, item) catch return c.fail(error.Unexpected);
                c.total_bytes += item.size;
                if (item.kind == .folder) c.to_scan.append(a, c.items.items.len - 1) catch return c.fail(error.Unexpected);
            }
        }
    }

    /// Copies (a chunk of) the next item.
    fn copyOne(c: *Copier) void {
        if (c.file != null) return c.copyChunk();
        if (c.next == c.items.items.len) {
            c.phase = if (c.move) .remove else .done;
            return;
        }
        const index = c.next;
        c.next += 1;
        const item = c.items.items[index];
        const a = c.arena.allocator();
        const dst = c.path(item.rel) catch return c.fail(error.Unexpected);
        const src = (if (item.rel.len == 0) a.dupeZ(u8, c.source) else std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ c.source, item.rel }, 0)) catch return c.fail(error.Unexpected);
        switch (item.kind) {
            .folder => switch (linux.errno(linux.mkdir(dst, item.mode | 0o700))) {
                .SUCCESS => {},
                else => |e| if (index == 0) return c.fail(errorFrom(e)) else {
                    c.skipped += 1;
                },
            },
            .file => {
                const from = sys.open(src, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }) catch {
                    c.skipped += 1;
                    return;
                };
                const rc = linux.open(dst, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, item.mode);
                if (linux.errno(rc) != .SUCCESS) {
                    sys.close(from);
                    if (index == 0 or linux.errno(rc) == .NOSPC) return c.fail(errorFrom(linux.errno(rc)));
                    c.skipped += 1;
                    return;
                }
                c.file = .{ .src = from, .dst = @intCast(rc), .item = index };
                c.copyChunk();
            },
            .link => {
                var target: [4096]u8 = undefined;
                const n = sys.check(linux.readlink(src, &target, target.len - 1)) catch {
                    c.skipped += 1;
                    return;
                };
                target[n] = 0;
                // Not every filesystem has links (FAT has none).
                if (linux.errno(linux.symlink(target[0..n :0], dst)) != .SUCCESS) c.skipped += 1;
            },
            .other => c.skipped += 1,
        }
    }

    fn copyChunk(c: *Copier) void {
        const f = c.file.?;
        const buf = c.buf orelse blk: {
            const b = c.arena.allocator().alloc(u8, chunk) catch return c.fail(error.Unexpected);
            c.buf = b;
            break :blk b;
        };
        const n = linux.read(f.src, buf.ptr, buf.len);
        if (linux.errno(n) != .SUCCESS) {
            c.skipped += 1;
            return c.closeFile(true);
        }
        if (n == 0) {
            // All of it: as the original was.
            const item = c.items.items[f.item];
            const sec = std.math.lossyCast(isize, item.mtime.sec);
            const times = [2]linux.timespec{ .{ .sec = sec, .nsec = @intCast(item.mtime.nsec) }, .{ .sec = sec, .nsec = @intCast(item.mtime.nsec) } };
            _ = linux.futimens(f.dst, &times);
            return c.closeFile(false);
        }
        var written: usize = 0;
        while (written < n) {
            const w = linux.write(f.dst, buf[written..].ptr, n - written);
            switch (linux.errno(w)) {
                .SUCCESS => written += w,
                .INTR => {},
                else => |e| {
                    c.closeFile(true);
                    if (e == .NOSPC) return c.fail(error.NoSpace);
                    c.skipped += 1;
                    return;
                },
            }
        }
        c.done_bytes += n;
    }

    /// Closes the file being copied (deleting what was written of it, if
    /// `discard`).
    fn closeFile(c: *Copier, discard: bool) void {
        const f = c.file orelse return;
        c.file = null;
        sys.close(f.src);
        sys.close(f.dst);
        if (discard) if (c.path(c.items.items[f.item].rel)) |p| {
            _ = linux.unlink(p);
        } else |_| {};
    }

    fn fail(c: *Copier, err: Error) void {
        c.closeFile(true);
        c.err = err;
        c.phase = .done;
    }

    /// Where `rel` (under what is copied) goes.
    fn path(c: *Copier, rel: []const u8) ![:0]const u8 {
        const a = c.arena.allocator();
        const top = if (std.mem.eql(u8, c.into, "/")) "" else c.into;
        if (rel.len == 0) return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ top, c.name }, 0);
        return std.fmt.allocPrintSentinel(a, "{s}/{s}/{s}", .{ top, c.name, rel }, 0);
    }
};

/// What is at a path (not following links).
const Stat = struct {
    kind: Kind,
    size: u64,
    mode: u32,
    mtime: linux.statx_timestamp,

    fn item(s: Stat, rel: []const u8) Item {
        return .{ .rel = rel, .kind = s.kind, .size = if (s.kind == .file) s.size else 0, .mode = s.mode, .mtime = s.mtime };
    }
};

fn stat(path: []const u8) ?Stat {
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return null;
    var stx: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, z, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .SIZE = true, .MTIME = true }, &stx)) != .SUCCESS) return null;
    const kind: Kind = switch (stx.mode & linux.S.IFMT) {
        linux.S.IFDIR => .folder,
        linux.S.IFREG => .file,
        linux.S.IFLNK => .link,
        else => .other,
    };
    return .{ .kind = kind, .size = stx.size, .mode = stx.mode & 0o777, .mtime = stx.mtime };
}

fn errorFrom(e: linux.E) Error {
    return switch (e) {
        .NOSPC => error.NoSpace,
        .ACCES, .PERM, .ROFS => error.AccessDenied,
        .NOENT => error.NotFound,
        else => error.Unexpected,
    };
}

/// `name`, or "<name> (copy)", "<name> (copy 2)"..., whichever is not in
/// the folder `dir` yet.
pub fn freeName(a: std.mem.Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    var n: usize = 1;
    while (n < 1000) : (n += 1) {
        const candidate = switch (n) {
            1 => try a.dupe(u8, name),
            2 => try std.fmt.allocPrint(a, "{s} (copy)", .{name}),
            else => try std.fmt.allocPrint(a, "{s} (copy {d})", .{ name, n - 1 }),
        };
        const full = try fs.join(a, dir, candidate);
        if (stat(full) == null) return candidate;
    }
    return error.OutOfMemory;
}

/// Whether the folders (or files) at `a` and `b` are on the same
/// filesystem (so moving between them is a rename).
pub fn sameFilesystem(a: []const u8, b: []const u8) bool {
    const da = device(a) orelse return false;
    const db = device(b) orelse return false;
    return da[0] == db[0] and da[1] == db[1];
}

fn device(path: []const u8) ?[2]u32 {
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return null;
    var stx: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, z, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &stx)) != .SUCCESS) return null;
    return .{ stx.dev_major, stx.dev_minor };
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

fn run(c: *Copier) void {
    while (!c.step(std.time.ns_per_ms)) {}
}

fn readAll(buf: []u8, path: []const u8) ![]const u8 {
    var z: [256]u8 = undefined;
    return sys.readFile(try std.fmt.bufPrintZ(&z, "{s}", .{path}), buf) orelse error.NotFound;
}

test "copying a folder with what is in it, under a free name, a little at a time" {
    var t: fs.TestTree = .{};
    try t.init();
    defer t.deinit();
    var buf: [256]u8 = undefined;
    const folder = try std.fmt.bufPrint(&buf, "{s}/A-folder", .{t.path});
    try fs.makeFolder(folder, "inner");
    try t.write("A-folder/inner/big", "x" ** (chunk + 10), 0o644);
    try t.write("A-folder/run", "#!", 0o755);
    var lbuf: [256]u8 = undefined;
    _ = linux.symlink("run", try std.fmt.bufPrintZ(&lbuf, "{s}/A-folder/to-run", .{t.path}));

    // Into the same folder: "A-folder (copy)".
    const c = try Copier.start(testing.allocator, folder, t.path, false);
    defer c.deinit();
    try testing.expectEqualStrings("A-folder (copy)", c.name);
    var steps: usize = 0;
    while (!c.step(0)) steps += 1;
    try testing.expect(steps > 4);
    try testing.expect(c.err == null);
    try testing.expectEqual(@as(usize, 0), c.skipped);
    try testing.expectEqual(@as(u64, chunk + 12), c.total_bytes);
    try testing.expectEqual(c.total_bytes, c.done_bytes);
    var out: [chunk + 64]u8 = undefined;
    var pbuf: [256]u8 = undefined;
    try testing.expectEqual(@as(usize, chunk + 10), (try readAll(&out, try std.fmt.bufPrint(&pbuf, "{s}/A-folder (copy)/inner/big", .{t.path}))).len);
    var link: [64]u8 = undefined;
    const n = linux.readlink(try std.fmt.bufPrintZ(&pbuf, "{s}/A-folder (copy)/to-run", .{t.path}), &link, link.len);
    try testing.expectEqualStrings("run", link[0..n]);
    var stx: linux.Statx = undefined;
    _ = linux.statx(linux.AT.FDCWD, try std.fmt.bufPrintZ(&pbuf, "{s}/A-folder (copy)/run", .{t.path}), 0, .{ .MODE = true }, &stx);
    try testing.expectEqual(@as(u32, 0o755), stx.mode & 0o777);

    // Again: "(copy 2)". And not into itself.
    const c2 = try Copier.start(testing.allocator, folder, t.path, false);
    defer c2.deinit();
    try testing.expectEqualStrings("A-folder (copy 2)", c2.name);
    try testing.expectError(error.IntoItself, Copier.start(testing.allocator, folder, try std.fmt.bufPrint(&pbuf, "{s}/inner", .{folder}), false));
}

test "moving within a filesystem renames; cancelling leaves no part of a file" {
    var t: fs.TestTree = .{};
    try t.init();
    defer t.deinit();
    var buf: [256]u8 = undefined;
    const file = try std.fmt.bufPrint(&buf, "{s}/b-file", .{t.path});
    var into_buf: [256]u8 = undefined;
    const into = try std.fmt.bufPrint(&into_buf, "{s}/A-folder", .{t.path});
    try testing.expect(sameFilesystem(file, into));
    const m = try Copier.start(testing.allocator, file, into, true);
    defer m.deinit();
    try testing.expect(m.done());
    var out: [16]u8 = undefined;
    var pbuf: [256]u8 = undefined;
    try testing.expectEqualStrings("hello", try readAll(&out, try std.fmt.bufPrint(&pbuf, "{s}/b-file", .{into})));
    try testing.expect(stat(file) == null);

    try t.write("big", "y" ** (3 * chunk), 0o644);
    const big = try std.fmt.bufPrint(&buf, "{s}/big", .{t.path});
    const c = try Copier.start(testing.allocator, big, into, false);
    defer c.deinit();
    // Scanned, then one chunk copied.
    _ = c.step(0);
    _ = c.step(0);
    _ = c.step(0);
    try testing.expect(c.file != null);
    c.cancel();
    try testing.expect(stat(try std.fmt.bufPrint(&pbuf, "{s}/big", .{into})) == null);
    run(c);
}
