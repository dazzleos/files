//! Copying and moving a file or folder (and everything in it) into a
//! folder, on a thread of its own, so the window keeps responding while a
//! big copy goes to a slow USB drive. The window reads how far it has got
//! (`progress`), and can ask it to stop (`cancel`).
//!
//! A move within a filesystem is a rename, done at once. Otherwise
//! everything is copied: first what there is is added up (for the
//! progress), then folders are made and files copied (with their
//! permissions and when they were changed), and links are made again as
//! links. A move then deletes what was copied, if all of it was. Devices
//! and the like are left out.
//!
//! What is made is named as the original, or, if something of that name
//! is there already, "<name> (copy)", "<name> (copy 2)" and so on: nothing
//! is ever replaced.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const fs = @import("fs.zig");

const Atomic = std.atomic.Value;

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

const chunk = 256 * 1024;

/// For tests: a pause after each chunk copied, to stop in the middle.
pub var test_chunk_delay_ms: u32 = 0;

pub const Copier = struct {
    gpa: std.mem.Allocator,
    /// What is copied (or moved), the folder it goes into, and the name it
    /// has there.
    source: []u8,
    into: []u8,
    name: []u8,
    move: bool,
    thread: ?std.Thread = null,

    // Shared with the thread.
    /// Still adding up what there is to copy.
    counting: Atomic(bool) = .init(true),
    /// In KiB (the Pi 1 has no 64-bit atomics), rounded up per file.
    total_kib: Atomic(u32) = .init(0),
    done_kib: Atomic(u32) = .init(0),
    finished: Atomic(bool) = .init(false),
    stop: Atomic(bool) = .init(false),

    // The thread's, read once it has finished.
    /// What could not be copied (other than what stops it all, `err`).
    skipped: usize = 0,
    err: ?Error = null,
    cancelled: bool = false,

    /// Starts copying (or moving) `source` into the folder `into`.
    pub fn start(gpa: std.mem.Allocator, source: []const u8, into: []const u8, move: bool) Error!*Copier {
        if (fs.within(into, source)) return error.IntoItself;
        if (stat(source) == null) return error.NotFound;
        const c = gpa.create(Copier) catch return error.Unexpected;
        c.* = .{ .gpa = gpa, .source = &.{}, .into = &.{}, .name = &.{}, .move = move };
        errdefer c.deinit();
        c.source = gpa.dupe(u8, source) catch return error.Unexpected;
        c.into = gpa.dupe(u8, into) catch return error.Unexpected;
        c.name = freeName(gpa, into, fs.baseName(source)) catch return error.Unexpected;
        // Moving within a filesystem: renamed, and done.
        if (move) {
            const dest = fs.join(gpa, into, c.name) catch return error.Unexpected;
            defer gpa.free(dest);
            var from_buf: [4096]u8 = undefined;
            var to_buf: [4096]u8 = undefined;
            const from = std.fmt.bufPrintZ(&from_buf, "{s}", .{source}) catch return error.Unexpected;
            const to = std.fmt.bufPrintZ(&to_buf, "{s}", .{dest}) catch return error.Unexpected;
            switch (linux.errno(linux.rename(from, to))) {
                .SUCCESS => {
                    c.finish();
                    return c;
                },
                .XDEV => {},
                .ACCES, .PERM, .ROFS => return error.AccessDenied,
                .NOENT => return error.NotFound,
                else => return error.Unexpected,
            }
        }
        c.thread = std.Thread.spawn(.{ .stack_size = 1 << 20 }, run, .{c}) catch return error.Unexpected;
        return c;
    }

    /// Waits for the thread (stopping it first), and frees everything.
    pub fn deinit(c: *Copier) void {
        if (c.thread) |t| {
            c.stop.store(true, .release);
            t.join();
        }
        const gpa = c.gpa;
        gpa.free(c.source);
        gpa.free(c.into);
        gpa.free(c.name);
        gpa.destroy(c);
    }

    pub fn done(c: *const Copier) bool {
        return c.finished.load(.acquire);
    }

    /// Asks it to stop; a file part copied is deleted (what was copied
    /// before stays).
    pub fn cancel(c: *Copier) void {
        c.stop.store(true, .release);
    }

    /// Bytes copied, and of how many (while `counting`, not all yet), to
    /// the KiB.
    pub fn progress(c: *const Copier) struct { done: u64, total: u64, counting: bool } {
        return .{ .done = @as(u64, c.done_kib.load(.monotonic)) * 1024, .total = @as(u64, c.total_kib.load(.monotonic)) * 1024, .counting = c.counting.load(.monotonic) };
    }

    fn finish(c: *Copier) void {
        c.counting.store(false, .monotonic);
        c.finished.store(true, .release);
    }

    fn stopping(c: *Copier) bool {
        return c.stop.load(.acquire);
    }

    /// The thread: counts, copies, and (for a move) deletes the original.
    fn run(c: *Copier) void {
        defer c.finish();
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        c.count(a, c.source);
        c.counting.store(false, .monotonic);
        const dest = fs.join(a, c.into, c.name) catch return c.fail(error.Unexpected);
        const buf = a.alloc(u8, chunk) catch return c.fail(error.Unexpected);
        c.copy(a, c.source, dest, buf, true);
        if (c.stopping() and c.err == null) {
            c.cancelled = true;
            return;
        }
        // Everything was copied: the original goes.
        if (c.move and c.err == null and c.skipped == 0) fs.delete(fs.parent(c.source), fs.baseName(c.source)) catch |err| {
            c.err = if (err == error.AccessDenied) error.AccessDenied else error.Unexpected;
        };
    }

    fn fail(c: *Copier, err: Error) void {
        if (c.err == null) c.err = err;
        c.stop.store(true, .release);
    }

    fn skip(c: *Copier) void {
        c.skipped += 1;
    }

    /// Adds up the bytes of the files at and in `path`.
    fn count(c: *Copier, a: std.mem.Allocator, path: []const u8) void {
        if (c.stopping()) return;
        const st = stat(path) orelse return;
        switch (st.kind) {
            .file => _ = c.total_kib.fetchAdd(kib(st.size), .monotonic),
            .folder => {
                const names = list(a, path) catch return;
                for (names) |name| {
                    const child = fs.join(a, path, name) catch return;
                    c.count(a, child);
                }
            },
            else => {},
        }
    }

    /// Copies what is at `from` to `to` (a folder with what is in it). The
    /// top (`top`) failing stops everything; anything in it failing is
    /// left out.
    fn copy(c: *Copier, a: std.mem.Allocator, from: []const u8, to: []const u8, buf: []u8, top: bool) void {
        if (c.stopping()) return;
        const st = stat(from) orelse return if (top) c.fail(error.NotFound) else c.skip();
        var to_buf: [4096]u8 = undefined;
        var from_buf: [4096]u8 = undefined;
        const to_z = std.fmt.bufPrintZ(&to_buf, "{s}", .{to}) catch return c.skip();
        const from_z = std.fmt.bufPrintZ(&from_buf, "{s}", .{from}) catch return c.skip();
        switch (st.kind) {
            .folder => {
                switch (linux.errno(linux.mkdir(to_z, st.mode | 0o700))) {
                    .SUCCESS => {},
                    else => |e| return if (top or e == .NOSPC) c.fail(errorFrom(e)) else c.skip(),
                }
                const names = list(a, from) catch return c.skip();
                for (names) |name| {
                    const f = fs.join(a, from, name) catch return c.fail(error.Unexpected);
                    const t = fs.join(a, to, name) catch return c.fail(error.Unexpected);
                    c.copy(a, f, t, buf, false);
                }
            },
            .file => c.copyFile(from_z, to_z, st, buf, top),
            .link => {
                var target: [4096]u8 = undefined;
                const n = sys.check(linux.readlink(from_z, &target, target.len - 1)) catch return c.skip();
                target[n] = 0;
                // Not every filesystem has links (FAT has none).
                if (linux.errno(linux.symlink(target[0..n :0], to_z)) != .SUCCESS) c.skip();
            },
            .other => c.skip(),
        }
    }

    fn copyFile(c: *Copier, from: [:0]const u8, to: [:0]const u8, st: Stat, buf: []u8, top: bool) void {
        const src = sys.open(from, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }) catch return if (top) c.fail(error.AccessDenied) else c.skip();
        defer sys.close(src);
        const rc = linux.open(to, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, st.mode);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            else => |e| return if (top or e == .NOSPC) c.fail(errorFrom(e)) else c.skip(),
        }
        const dst: linux.fd_t = @intCast(rc);
        var whole = false;
        defer {
            sys.close(dst);
            // A file part copied goes.
            if (!whole) _ = linux.unlink(to);
        }
        var copied: u64 = 0;
        var reported: u32 = 0;
        while (true) {
            if (c.stopping()) return;
            const n = linux.read(src, buf.ptr, buf.len);
            if (linux.errno(n) != .SUCCESS) return c.skip();
            if (n == 0) break;
            var written: usize = 0;
            while (written < n) {
                const w = linux.write(dst, buf[written..].ptr, n - written);
                switch (linux.errno(w)) {
                    .SUCCESS => written += w,
                    .INTR => {},
                    .NOSPC => return c.fail(error.NoSpace),
                    else => return c.skip(),
                }
            }
            copied += n;
            const now = kib(copied);
            _ = c.done_kib.fetchAdd(now - reported, .monotonic);
            reported = now;
            if (test_chunk_delay_ms > 0) sys.sleepMs(test_chunk_delay_ms);
        }
        // All of it: as the original was.
        sys.setFileTimes(dst, null, st.mtime.sec, st.mtime.nsec) catch {};
        whole = true;
    }
};

/// Bytes in KiB, rounded up.
fn kib(bytes: u64) u32 {
    return std.math.lossyCast(u32, (bytes + 1023) / 1024);
}

const Kind = enum { folder, file, link, other };

/// What is at a path (not following links).
const Stat = struct {
    kind: Kind,
    size: u64,
    mode: u32,
    mtime: linux.statx_timestamp,
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

/// The names in the folder at `path` (in `a`).
fn list(a: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return error.NameTooLong;
    const dir = try sys.open(z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    defer sys.close(dir);
    var names: std.ArrayList([]const u8) = .empty;
    var dents: [4096]u8 align(8) = undefined;
    while (true) {
        const n = try sys.check(linux.getdents64(dir, &dents, dents.len));
        if (n == 0) return names.items;
        var at: usize = 0;
        while (at < n) {
            const reclen = std.mem.readInt(u16, dents[at + 16 ..][0..2], .little);
            const name = std.mem.sliceTo(dents[at + 19 .. at + reclen], 0);
            at += reclen;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            try names.append(a, try a.dupe(u8, name));
        }
    }
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
/// the folder `dir` yet (in `gpa`).
pub fn freeName(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    var n: usize = 1;
    while (n < 1000) : (n += 1) {
        const candidate = switch (n) {
            1 => try gpa.dupe(u8, name),
            2 => try std.fmt.allocPrint(gpa, "{s} (copy)", .{name}),
            else => try std.fmt.allocPrint(gpa, "{s} (copy {d})", .{ name, n - 1 }),
        };
        const full = try fs.join(gpa, dir, candidate);
        defer gpa.free(full);
        if (stat(full) == null) return candidate;
        gpa.free(candidate);
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

/// Waits for a copy to finish (for tests).
pub fn wait(c: *const Copier) void {
    while (!c.done()) sys.sleepMs(1);
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

fn readAll(buf: []u8, path: []const u8) ![]const u8 {
    var z: [256]u8 = undefined;
    return sys.readFile(try std.fmt.bufPrintZ(&z, "{s}", .{path}), buf) orelse error.NotFound;
}

test "copying a folder with what is in it, under a free name" {
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
    wait(c);
    try testing.expect(c.err == null);
    try testing.expectEqual(@as(usize, 0), c.skipped);
    const p = c.progress();
    // big and run, in KiB.
    try testing.expectEqual(@as(u64, (chunk / 1024 + 1 + 1) * 1024), p.total);
    try testing.expectEqual(p.total, p.done);
    try testing.expect(!p.counting);
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
    wait(c2);
    try testing.expectError(error.IntoItself, Copier.start(testing.allocator, folder, try std.fmt.bufPrint(&pbuf, "{s}/inner", .{folder}), false));
}

test "moving within a filesystem renames; stopping leaves no part of a file" {
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

    try t.write("big", "y" ** (8 * chunk), 0o644);
    const big = try std.fmt.bufPrint(&buf, "{s}/big", .{t.path});
    test_chunk_delay_ms = 20;
    defer test_chunk_delay_ms = 0;
    const c = try Copier.start(testing.allocator, big, into, false);
    defer c.deinit();
    while (c.progress().done == 0) sys.sleepMs(1);
    c.cancel();
    wait(c);
    try testing.expect(c.cancelled);
    try testing.expect(stat(try std.fmt.bufPrint(&pbuf, "{s}/big", .{into})) == null);
}
