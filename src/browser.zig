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
const linux = std.os.linux;
const sys = @import("sys");
const fs = @import("fs.zig");
const copier = @import("copier.zig");
const content = @import("content.zig");
const appearance = @import("appearance");

const watch_mask = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO | linux.IN.CLOSE_WRITE | linux.IN.ATTRIB | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF;

pub const Action = union(enum) {
    /// Show this folder.
    open: []const u8,
    /// Open or close this folder in the tree.
    toggle: []const u8,
    /// An item in the open folder (an index into its entries): a folder
    /// is opened; anything else (a file, a device, say) is picked.
    activate: usize,
    /// Show the contents of the item picked (a file) in Files.
    view,
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
    /// Make the text file named `name` in the open folder, pick it, and
    /// open it in the text editor.
    make_text_file,
    /// Open the item picked (a text file) in the text editor.
    edit,
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
    /// Dismiss the notice snackbar.
    dismiss_notice,
    /// Make the image shown the desktop's background.
    set_background,
};

pub const Drop = struct { index: usize, into: []const u8, copy: bool = false };

/// What the window is asking: nothing, a new folder's or text file's
/// name, or whether to delete the item picked.
pub const Prompt = enum { none, new_folder, new_text_file, delete };

/// Starts the app `program` with the file at `path`. Returns whether it
/// could be.
pub const Launcher = *const fn (program: [:0]const u8, path: [:0]const u8) bool;

/// The environment apps started from Files get ("NAME=value"): where the
/// compositor is (set by main).
pub var app_env: []const [*:0]const u8 = &.{};

fn launchApp(program: [:0]const u8, path: [:0]const u8) bool {
    sys.apps.launch(program, path, app_env) catch return false;
    return true;
}

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
    /// Control is held (a drop copies rather than moves): the window's
    /// keys say (main.zig).
    ctrl_held: bool = false,
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
    /// The appearance settings, where the background image is chosen.
    appearance_file: [:0]const u8 = appearance.settings_file,
    /// The text editor (its program), if an app that edits text is
    /// installed: `editor_len` bytes of `editor_buf`.
    editor_buf: [256]u8 = undefined,
    editor_len: usize = 0,
    /// Where apps are looked for, and how they are started.
    apps_dir: []const u8 = sys.system.apps_dir,
    launcher: Launcher = launchApp,
    /// What was asked for since the last `apply`, and room for its path.
    pending: ?Action = null,
    pending_path: std.ArrayList(u8) = .empty,
    /// An inotify descriptor watching `media_dir`, `path`, and the folders
    /// open in the tree so the window updates when files or folders are
    /// made, changed or removed outside Files.
    watch_fd: ?linux.fd_t = null,
    watches: std.ArrayList(i32) = .empty,

    /// Starts at `user_files` (which must last as long as the browser), showing
    /// only what is in it.
    pub fn init(gpa: std.mem.Allocator, user_files: []const u8) !Browser {
        const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        var b: Browser = .{
            .gpa = gpa,
            .user_files = user_files,
            .path = try gpa.dupe(u8, user_files),
            .listing = fs.Listing.read(gpa, user_files),
            .drives = fs.Listing.read(gpa, sys.media.media_dir),
            .watch_fd = if (linux.errno(rc) == .SUCCESS) @intCast(rc) else null,
        };
        try b.expand(user_files);
        b.findEditor();
        b.syncWatches();
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
        b.syncWatches();
        _ = b.hasWatchEvents();
    }

    fn eject(b: *Browser, name: []const u8) void {
        if (!b.isDrive(name)) return;
        // Not looking at it any more.
        const path = fs.join(b.gpa, b.media_dir, name) catch return;
        defer b.gpa.free(path);
        if (fs.within(b.path, path)) b.open(b.user_files) catch {};
        b.clearWatches();
        switch (b.ejector(name) orelse .failed) {
            .ejected => b.say("You can take out \u{201c}{s}\u{201d} now", .{name}),
            .busy => b.say("\u{201c}{s}\u{201d} is in use: close what is open on it, then eject it again", .{name}),
            .unknown => b.say("\u{201c}{s}\u{201d} is not plugged in", .{name}),
            .failed => b.say("\u{201c}{s}\u{201d} could not be ejected", .{name}),
        }
        b.refreshDrives();
    }

    pub fn deinit(b: *Browser) void {
        if (b.watch_fd) |fd| sys.close(fd);
        b.watches.deinit(b.gpa);
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
            .view => b.view() catch {},
            .up => if (b.file != null) b.closeFile() else if (!b.atRoot()) b.open(fs.parent(b.path)) catch {},
            .show_system => |on| b.showSystem(on) catch {},
            .order => |o| b.sortBy(o),
            .layout => |l| b.layout = l,
            .prompt => |p| b.ask(p),
            .make_folder => b.makeFolder(),
            .make_text_file => b.makeTextFile(),
            .edit => b.edit(),
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
            .dismiss_notice => {},
            .set_background => b.setBackground(),
        }
        return true;
    }

    /// Whether the file shown can be the desktop's background: a PNG
    /// image (what the shell reads).
    pub fn canSetBackground(b: *const Browser) bool {
        const f = b.file orelse return false;
        return switch (f.kind) {
            .image => |img| img.format == .png,
            else => false,
        };
    }

    fn setBackground(b: *Browser) void {
        if (!b.canSetBackground()) return;
        const path = b.filePath(b.gpa) orelse return;
        defer b.gpa.free(path);
        if (path.len > appearance.ImagePath.max_len) return b.say("The background cannot be set: its path is too long", .{});
        var s = appearance.loadSettingsFrom(b.appearance_file);
        s.image = .of(path);
        appearance.saveSettingsTo(b.appearance_file, s);
        b.say("\u{201c}{s}\u{201d} is the background", .{fs.baseName(path)});
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
        } else {
            b.syncWatches();
            _ = b.hasWatchEvents();
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
        var n = @min(text.len, b.name_buf.len);
        while (n > 0 and n < text.len and text[n] & 0xc0 == 0x80) n -= 1;
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
            .new_folder, .new_text_file => {
                if (b.file != null or !b.changeable()) return;
                if (p == .new_text_file and b.editor() == null) return;
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

    /// Looks again for an app that edits text (one may have been installed
    /// or removed).
    pub fn findEditor(b: *Browser) void {
        const program = sys.apps.handlerIn(b.apps_dir, &b.editor_buf, sys.apps.text_plain);
        b.editor_len = if (program) |p| p.len else 0;
    }

    /// The text editor's program, if there is one.
    pub fn editor(b: *const Browser) ?[:0]const u8 {
        return if (b.editor_len > 0) b.editor_buf[0..b.editor_len :0] else null;
    }

    /// Whether the item picked is a file whose contents can be viewed.
    pub fn canView(b: *const Browser) bool {
        if (b.copier != null or b.file != null) return false;
        const e = b.picked() orelse return false;
        return e.kind == .file or e.kind == .program;
    }

    fn view(b: *Browser) !void {
        if (!b.canView()) return;
        const e = b.picked().?;
        b.closeFile();
        const path = try fs.join(b.gpa, b.path, e.name);
        defer b.gpa.free(path);
        b.file = content.Content.read(b.gpa, path);
    }

    /// Whether the item picked is a text file the editor can open.
    pub fn canEdit(b: *const Browser) bool {
        if (b.editor() == null or b.copier != null) return false;
        const e = b.picked() orelse return false;
        if (e.kind != .file) return false;
        if (b.file) |f| return f.kind == .text or f.kind == .empty;
        return fs.isTextFile(b.path, e.name);
    }

    fn edit(b: *Browser) void {
        if (!b.canEdit()) return;
        const e = b.picked().?;
        b.openInEditor(e.name);
    }

    fn openInEditor(b: *Browser, name: []const u8) void {
        var buf: [4096]u8 = undefined;
        const path = std.mem.printSentinel(&buf, "{s}/{s}", .{ b.path, name }, 0) catch return;
        if (!b.launcher(b.editor().?, path)) b.say("The text editor could not be started", .{});
    }

    /// The new text file's name: as typed, with ".txt" after it if it does
    /// not say what it is.
    pub fn textFileName(b: *const Browser, buf: []u8) []const u8 {
        const name = b.newName();
        if (name.len == 0 or std.mem.lastIndexOfScalar(u8, name, '.') != null) return name;
        return std.fmt.bufPrint(buf, "{s}.txt", .{name}) catch name;
    }

    fn makeTextFile(b: *Browser) void {
        if (b.prompt != .new_text_file or b.editor() == null) return;
        var name_buf: [260]u8 = undefined;
        const name = b.textFileName(&name_buf);
        fs.makeFile(b.path, name) catch |err| {
            b.failure = fs.describeError(err);
            return;
        };
        b.prompt = .none;
        b.failure = null;
        b.reload();
        // The new file is picked, and opened to be written in.
        b.selected = for (b.listing.entries, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name)) break i;
        } else null;
        b.openInEditor(name);
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
        b.syncWatches();
        _ = b.hasWatchEvents();
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
        b.syncWatches();
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
        b.syncWatches();
    }

    fn activate(b: *Browser, i: usize) !void {
        if (i >= b.listing.entries.len) return;
        const e = b.listing.entries[i];
        if (b.selected != i) b.ask(.none);
        if (e.kind != .folder) {
            b.closeFile();
            b.selected = i;
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

    /// Advances the open video or audio file's playback, if one is shown.
    pub fn stepVideo(b: *Browser, now_ns: u64) bool {
        const f = &(b.file orelse return false);
        return switch (f.kind) {
            .video => |player| player.step(now_ns),
            .audio => |player| blk: {
                const before_pos = player.positionMs();
                const before_playing = player.playing;
                const before_ended = player.ended;
                _ = player.step(now_ns);
                break :blk player.positionMs() != before_pos or player.playing != before_playing or player.ended != before_ended;
            },
            else => false,
        };
    }

    /// How long before the open video or audio file needs another step, if it is playing.
    pub fn videoWakeNs(b: *const Browser) ?u64 {
        const f = &(b.file orelse return null);
        return switch (f.kind) {
            .video => |player| player.nextWakeNs(),
            .audio => |player| if (player.playing) 16 * std.time.ns_per_ms else null,
            else => null,
        };
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
        b.syncWatches();
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

    fn addWatch(b: *Browser, path: []const u8) void {
        const fd = b.watch_fd orelse return;
        var buf: [4096]u8 = undefined;
        const path_z = std.mem.printSentinel(&buf, "{s}", .{path}, 0) catch return;
        const rc = linux.inotify_add_watch(fd, path_z, watch_mask | linux.IN.ONLYDIR);
        if (linux.errno(rc) != .SUCCESS) return;
        const wd: i32 = @intCast(rc);
        for (b.watches.items) |existing| if (existing == wd) return;
        b.watches.append(b.gpa, wd) catch {};
    }

    fn clearWatches(b: *Browser) void {
        const fd = b.watch_fd orelse return;
        for (b.watches.items) |wd| _ = linux.inotify_rm_watch(fd, wd);
        b.watches.clearRetainingCapacity();
    }

    /// Ensures inotify watches are registered on `media_dir`, `path`, and
    /// all folders open in the tree (and their immediate subfolders).
    pub fn syncWatches(b: *Browser) void {
        if (b.watch_fd == null) return;
        b.addWatch(b.media_dir);
        for (b.drives.folders()) |e| {
            if (e.link) continue;
            var sub_buf: [4096]u8 = undefined;
            if (std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ b.media_dir, e.name })) |sub| b.addWatch(sub) else |_| {}
        }
        b.addWatch(b.path);
        var it = b.expanded.iterator();
        while (it.next()) |kv| {
            const dir = kv.key_ptr.*;
            b.addWatch(dir);
            for (kv.value_ptr.folders()) |e| {
                if (e.link) continue;
                var sub_buf: [4096]u8 = undefined;
                const sub = if (std.mem.eql(u8, dir, "/"))
                    std.fmt.bufPrint(&sub_buf, "/{s}", .{e.name}) catch continue
                else
                    std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ dir, e.name }) catch continue;
                b.addWatch(sub);
            }
        }
    }

    /// Reads all pending inotify events from `watch_fd` and returns whether
    /// any non-hidden file or watched folder changed.
    fn hasWatchEvents(b: *Browser) bool {
        const fd = b.watch_fd orelse return false;
        var changed = false;
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            const rc = linux.read(fd, &buf, buf.len);
            if (linux.errno(rc) != .SUCCESS or rc == 0) return changed;
            var at: usize = 0;
            while (at + @sizeOf(linux.inotify_event) <= rc) {
                const ev: *align(1) const linux.inotify_event = @ptrCast(&buf[at]);
                const step = @sizeOf(linux.inotify_event) + ev.len;
                if (at + step > rc) break;
                const name_bytes = buf[at + @sizeOf(linux.inotify_event) .. at + step];
                const name = std.mem.sliceTo(name_bytes, 0);
                at += step;
                if (ev.mask & watch_mask == 0) continue;
                if (name.len > 0 and name[0] == '.') continue;
                changed = true;
            }
        }
    }

    /// Checks whether any watched folder changed on disk; if so, refreshes
    /// the drives, tree and open folder, and returns true.
    pub fn checkWatches(b: *Browser) bool {
        if (b.copying()) return false;
        if (!b.hasWatchEvents()) return false;
        b.refresh();
        return true;
    }

    /// Re-reads the USB drives, the folders open in the tree, and the open
    /// folder (keeping the item picked if it is still there, and updating
    /// the file shown if it changed or was deleted).
    pub fn refresh(b: *Browser) void {
        b.drives.deinit();
        b.drives = fs.Listing.read(b.gpa, b.media_dir);

        while (true) {
            var it = b.expanded.keyIterator();
            const key = while (it.next()) |k| {
                if (b.rootOf(k.*) == null or !folderExists(k.*)) break k.*;
            } else break;
            var kv = b.expanded.fetchRemove(key).?;
            kv.value.deinit();
            b.gpa.free(kv.key);
        }

        var it = b.expanded.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.deinit();
            kv.value_ptr.* = fs.Listing.read(b.gpa, kv.key_ptr.*);
        }

        if (b.rootOf(b.path) == null) {
            b.open(b.user_files) catch {};
            return;
        }
        if (!folderExists(b.path)) {
            var target: []const u8 = fs.parent(b.path);
            while (b.rootOf(target) != null and !folderExists(target)) {
                const p = fs.parent(target);
                if (std.mem.eql(u8, p, target)) break;
                target = p;
            }
            const fallback = if (b.rootOf(target) != null and folderExists(target)) target else b.user_files;
            if (!std.mem.eql(u8, b.path, fallback)) {
                b.open(fallback) catch {};
                return;
            }
        }

        var picked_name_buf: [256]u8 = undefined;
        var picked_name: ?[]const u8 = null;
        var picked_size: u64 = 0;
        var picked_modified: i64 = 0;
        if (b.picked()) |e| if (e.name.len <= picked_name_buf.len) {
            @memcpy(picked_name_buf[0..e.name.len], e.name);
            picked_name = picked_name_buf[0..e.name.len];
            picked_size = e.size;
            picked_modified = e.modified;
        };

        b.listing.deinit();
        b.listing = fs.Listing.read(b.gpa, b.path);
        b.listing.sort(b.order);

        if (picked_name) |name| {
            b.selected = for (b.listing.entries, 0..) |e, i| {
                if (std.mem.eql(u8, e.name, name)) break i;
            } else null;
            if (b.selected) |i| {
                const e = b.listing.entries[i];
                if (b.file) |*f| {
                    if (e.kind != .file and e.kind != .program) {
                        b.closeFile();
                    } else if ((f.kind != .video and f.kind != .audio) or e.size != picked_size or e.modified != picked_modified) {
                        if (fs.join(b.gpa, b.path, e.name)) |fpath| {
                            defer b.gpa.free(fpath);
                            b.closeFile();
                            b.file = content.Content.read(b.gpa, fpath);
                        } else |_| {}
                    }
                }
                if (b.prompt == .delete and e.kind == .folder and !e.link) {
                    b.delete_count = b.countPicked();
                }
            } else {
                b.closeFile();
                if (b.prompt == .delete) b.ask(.none);
            }
        } else {
            b.selected = null;
            b.closeFile();
        }

        b.syncWatches();
    }
};

fn folderExists(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const z = std.mem.printSentinel(&buf, "{s}", .{path}, 0) catch return false;
    var stx: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, z, 0, .{ .TYPE = true }, &stx)) != .SUCCESS) return false;
    return stx.mode & linux.S.IFMT == linux.S.IFDIR;
}

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

    // Clicking a file picks it, View shows it, and Up goes back to its
    // folder; clicking a folder opens it.
    b.request(.{ .activate = 2 });
    try testing.expect(b.apply());
    try testing.expectEqual(@as(?usize, 2), b.selected);
    try testing.expect(b.file == null);
    try testing.expect(b.canView());
    b.request(.view);
    try testing.expect(b.apply());
    try testing.expectEqualStrings("hello", b.file.?.kind.text[0]);
    b.request(.up);
    _ = b.apply();
    try testing.expect(b.file == null);
    try testing.expectEqualStrings(t.path, b.path);
    b.request(.{ .activate = 2 });
    _ = b.apply();
    b.request(.view);
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
        try sys.setFileTimes(std.os.linux.AT.FDCWD, try std.mem.printSentinel(&z, "{s}/{s}", .{ t.path, f[0] }, 0), f[1], 0);
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

var test_launched: [256]u8 = undefined;
var test_launched_len: usize = 0;

fn testLauncher(program: [:0]const u8, path: [:0]const u8) bool {
    _ = program;
    @memcpy(test_launched[0..path.len], path);
    test_launched_len = path.len;
    return true;
}

test "text files: made, and opened in the editor, only if there is one" {
    var t: fs.TestTree = .{};
    try t.init();
    defer t.deinit();
    var b = try Browser.init(testing.allocator, t.path);
    defer b.deinit();
    b.launcher = testLauncher;
    test_launched_len = 0;
    // No editor: nothing is offered.
    b.apps_dir = "/nonexistent";
    b.findEditor();
    try testing.expect(b.editor() == null);
    b.request(.{ .prompt = .new_text_file });
    _ = b.apply();
    try testing.expectEqual(Prompt.none, b.prompt);

    // An editor installed (an app that says it opens text).
    var buf: [256]u8 = undefined;
    const apps = try std.mem.printSentinel(&buf, "{s}/apps", .{t.path}, 0);
    try fs.makeFolder(t.path, "apps");
    try fs.makeFolder(apps, "ed");
    var hbuf: [256]u8 = undefined;
    try sys.files.writeNew(try std.mem.printSentinel(&hbuf, "{s}/ed/ed.handles", .{apps}, 0), "text/plain\n");
    b.apps_dir = apps;
    b.findEditor();
    try testing.expect(std.mem.endsWith(u8, b.editor().?, "/ed/ed"));
    b.reload();

    // A new text file: ".txt" after a name without an ending, and it opens.
    b.request(.{ .prompt = .new_text_file });
    _ = b.apply();
    try testing.expectEqual(Prompt.new_text_file, b.prompt);
    b.setName("notes");
    b.request(.make_text_file);
    _ = b.apply();
    try testing.expectEqual(Prompt.none, b.prompt);
    try testing.expectEqualStrings("notes.txt", b.picked().?.name);
    var pbuf: [256]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&pbuf, "{s}/notes.txt", .{t.path}), test_launched[0..test_launched_len]);
    try testing.expect(b.canEdit());
    // Not twice.
    b.request(.{ .prompt = .new_text_file });
    _ = b.apply();
    b.setName("notes.txt");
    b.request(.make_text_file);
    _ = b.apply();
    try testing.expectEqualStrings("there is already something with that name", b.failure.?);
    b.request(.{ .prompt = .none });
    _ = b.apply();

    // A folder cannot be edited; a text file picked can.
    for (b.listing.entries, 0..) |e, i| if (e.kind == .folder) {
        b.request(.{ .pick = i });
        _ = b.apply();
        break;
    };
    try testing.expect(!b.canEdit());
    test_launched_len = 0;
    b.request(.edit);
    _ = b.apply();
    try testing.expectEqual(@as(usize, 0), test_launched_len);
    for (b.listing.entries, 0..) |e, i| if (std.mem.eql(u8, e.name, "notes.txt")) {
        b.request(.{ .pick = i });
        _ = b.apply();
    };
    b.request(.edit);
    _ = b.apply();
    try testing.expect(std.mem.endsWith(u8, test_launched[0..test_launched_len], "/notes.txt"));
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
    b.request(.view);
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
    const media = try std.mem.printSentinel(&buf, "{s}-media", .{t.path}, 0);
    _ = std.os.linux.mkdir(media, 0o755);
    defer sys.files.removeTree(media);
    try fs.makeFolder(media, "STICK");
    var photo_buf: [160]u8 = undefined;
    try sys.files.writeNew(try std.mem.printSentinel(&photo_buf, "{s}/STICK/photo", .{media}, 0), "jpeg");
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
    try testing.expectEqualStrings("\u{201c}c-tool\u{201d} was copied to " ++ "", b.notice().?[0.."\u{201c}c-tool\u{201d} was copied to ".len]);
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
    try t.write("big", &@as([1024 * 1024]u8, @splat('z')), 0o644);
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

test "watching folders: external files and folders made, changed and deleted update the listing, tree and viewer" {
    var t: fs.TestTree = .{};
    try t.init();
    defer t.deinit();
    var b = try Browser.init(testing.allocator, t.path);
    defer b.deinit();
    try testing.expect(!b.checkWatches());

    // Open b-file in the viewer.
    b.request(.{ .activate = 2 });
    _ = b.apply();
    b.request(.view);
    _ = b.apply();
    try testing.expectEqualStrings("b-file", b.picked().?.name);
    try testing.expectEqualStrings("hello", b.file.?.kind.text[0]);

    // A new file "a-first.txt" is created externally before "b-file":
    // checkWatches detects it, adds it to the listing, and keeps "b-file"
    // selected at its new index.
    try t.write("a-first.txt", "new file\n", 0o644);
    try testing.expect(b.checkWatches());
    try testing.expect(!b.checkWatches());
    try testing.expectEqual(@as(usize, 6), b.listing.entries.len);
    try testing.expectEqualStrings("a-first.txt", b.listing.entries[2].name);
    try testing.expectEqualStrings("b-file", b.picked().?.name);
    try testing.expectEqual(@as(?usize, 3), b.selected);

    // Modifying "b-file" externally updates the open file viewer and size.
    try t.write("b-file", "updated text", 0o644);
    try testing.expect(b.checkWatches());
    try testing.expectEqualStrings("updated text", b.file.?.kind.text[0]);
    try testing.expectEqual(@as(u64, 12), b.picked().?.size);

    // Creating a new folder externally updates both the listing and the tree.
    try fs.makeFolder(t.path, "New-folder");
    try testing.expect(b.checkWatches());
    try testing.expectEqual(@as(usize, 3), b.subfolders(t.path).len);

    // Deleting the open file externally clears the selection and closes the viewer.
    try fs.delete(t.path, "b-file");
    try testing.expect(b.checkWatches());
    try testing.expect(b.selected == null);
    try testing.expect(b.file == null);
}

test "a PNG image shown can be made the desktop's background; other files cannot" {
    var t: fs.TestTree = .{};
    try t.init();
    defer t.deinit();
    const pixels: [4]u32 = @splat(0xff336699);
    const png = try @import("gfx").png.encode(testing.allocator, &pixels, 2, 2);
    defer testing.allocator.free(png);
    try t.write("A-folder/sea.png", png, 0o644);
    var settings_buf: [64]u8 = undefined;
    const settings = try std.mem.printSentinel(&settings_buf, "/tmp/dazzle-files-appearance-{d}", .{linux.getpid()}, 0);
    defer _ = linux.unlink(settings);
    appearance.saveSettingsTo(settings, .{ .theme = .light, .background = .teal });

    var b = try Browser.init(testing.allocator, t.path);
    defer b.deinit();
    b.appearance_file = settings;
    // A text file shown: no.
    b.request(.{ .activate = 2 });
    _ = b.apply();
    b.request(.view);
    _ = b.apply();
    try testing.expect(b.file != null and !b.canSetBackground());
    // The image: yes, keeping the theme and colour.
    var path_buf: [128]u8 = undefined;
    b.request(.{ .open = try std.fmt.bufPrint(&path_buf, "{s}/A-folder", .{t.path}) });
    _ = b.apply();
    b.request(.{ .activate = 0 });
    _ = b.apply();
    b.request(.view);
    _ = b.apply();
    try testing.expect(b.canSetBackground());
    b.request(.set_background);
    _ = b.apply();
    const s = appearance.loadSettingsFrom(settings);
    try testing.expectEqualStrings(try std.fmt.bufPrint(&path_buf, "{s}/A-folder/sea.png", .{t.path}), s.image.slice().?);
    try testing.expectEqual(appearance.Mode.light, s.theme);
    try testing.expectEqual(appearance.Background.teal, s.background);
    try testing.expect(std.mem.indexOf(u8, b.notice().?, "sea.png") != null);
}
