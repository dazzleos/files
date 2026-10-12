//! Dazzle's Files app: browses the files on the system, starting at the
//! root. The tree of folders is on the left and the open folder's
//! contents, as a grid of icons, on the right (see view.zig); folders are
//! read when they are opened (see fs.zig and browser.zig). The window is
//! built with the `ui` toolkit, and only what changed is drawn again.
//!
//!     dazzle-files [font.ttf]
//!
//! It runs until it is stopped or its window is closed.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const locale = @import("locale");
const font = @import("font");
const app = @import("app");
const ui = @import("ui");
const fs = @import("fs.zig");
const browser_mod = @import("browser.zig");
const view = @import("view.zig");

const print = sys.print;

/// Keys: Backspace goes up a folder, Delete asks whether to delete the
/// item picked, Ctrl+C, Ctrl+X and Ctrl+V copy, cut and paste, and
/// Escape stops asking (unless a text field has them).
const key_backspace = 14;
const key_c = 46;
const key_x = 45;
const key_v = 47;
const key_space = 57;
const key_left = 105;
const key_right = 106;
const key_delete = 111;
const key_escape = 1;

/// How often the progress of a copy is drawn.
const progress_ns = 250 * std.time.ns_per_ms;

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.logToKmsgIfStderr();
    var args = init.args.iterate();
    _ = args.skip();
    var font_buf: [512]u8 = undefined;
    const font_path: [*:0]const u8 = args.next() orelse sys.fontFile(&font_buf, font.default_font_file);
    run(init, font_path) catch |err| {
        print(sys.log_error ++ "dazzle-files: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init.Minimal, font_path: [*:0]const u8) !void {
    // The language chosen (in setup, or Settings).
    locale.current = locale.load().language;
    const gpa = std.heap.page_allocator;
    const a = try ui.App.open(gpa, init.environ, .{
        .title = "Files",
        .app_id = "dazzle-files",
        .size = view.open_size,
        .min_size = view.min_size,
        .font_path = font_path,
    });
    defer a.close();

    // Apps it starts (the text editor) find the compositor as it did.
    var child_env: app.ChildEnv = undefined;
    browser_mod.app_env = child_env.init(init.environ, "/");

    // The user's files, on the SD card.
    var browser = try browser_mod.Browser.init(gpa, sys.system.user_dir);
    defer browser.deinit();
    // USB drives come and go as their folders do in /media.
    const drives_fd = watchDrives();
    a.win.wake_fd = drives_fd;

    var last_progress: u64 = 0;
    while (try a.step(browser.videoWakeNs() orelse if (browser.copying()) progress_ns else 60 * std.time.ns_per_s)) {
        if (a.suspended_changed and !a.suspended) {
            // An editor may have been installed or removed meanwhile.
            browser.findEditor();
        }
        const now = sys.nowNs();
        for (a.win.takeInput()) |e| switch (e) {
            .key => |k| {
                const typing = a.ui.focused != null;
                a.ui.keyEvent(k.code, k.pressed);
                if (k.pressed) switch (k.code) {
                    key_backspace => if (!typing) browser.request(.up),
                    key_delete => if (!typing and browser.prompt == .none) browser.request(.{ .prompt = .delete }),
                    key_escape => if (browser.prompt != .none) browser.request(.{ .prompt = .none }),
                    key_c => if (!typing and a.ui.ctrl > 0) browser.request(.copy),
                    key_x => if (!typing and a.ui.ctrl > 0) browser.request(.cut),
                    key_v => if (!typing and a.ui.ctrl > 0) browser.request(.paste),
                    key_space => if (!typing and browser.prompt == .none) if (browser.file) |*f| switch (f.kind) {
                        .video => |player| player.togglePlay(now),
                        else => {},
                    },
                    key_left => if (!typing and browser.prompt == .none) if (browser.file) |*f| switch (f.kind) {
                        .video => |player| player.seekTo(player.position_us -| 5_000_000, now),
                        else => {},
                    },
                    key_right => if (!typing and browser.prompt == .none) if (browser.file) |*f| switch (f.kind) {
                        .video => |player| player.seekTo(player.position_us + 5_000_000, now),
                        else => {},
                    },
                    else => {},
                };
                a.dirty = true;
            },
            else => a.ui.handleInput(e),
        };
        if (drives_fd) |fd| if (drained(fd)) {
            browser.refreshDrives();
            a.dirty = true;
        };
        // What the clicks asked for, now that no widget is handling them.
        if (browser.apply()) a.dirty = true;
        if (browser.stepVideo(now)) a.dirty = true;

        // Copying (on its own thread): the window is drawn again, to say
        // how far it has got, a few times a second, and when it is done.
        if (browser.copying()) {
            if (!browser.poll() or now >= last_progress + progress_ns) {
                last_progress = now;
                a.dirty = true;
            }
        }
        try a.draw(now, view.Files{
            .browser = &browser,
            .width = @floatFromInt(a.width),
            .now = realNow(),
        });
    }
}

test {
    _ = @import("decode.zig");
    _ = @import("content.zig");
    _ = @import("viewer.zig");
    _ = fs;
    _ = @import("copier.zig");
    _ = browser_mod;
    _ = view;
}

/// A file that can be read when a folder is made or removed in /media
/// (as drives are mounted and unmounted).
fn watchDrives() ?linux.fd_t {
    const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    const mask = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO;
    if (linux.errno(linux.inotify_add_watch(fd, sys.media.media_dir, mask)) != .SUCCESS) {
        sys.close(fd);
        return null;
    }
    return fd;
}

/// Whether anything happened on the inotify file `fd`, reading it all.
fn drained(fd: linux.fd_t) bool {
    var any = false;
    var buf: [1024]u8 align(@alignOf(linux.inotify_event)) = undefined;
    while (true) {
        const rc = linux.read(fd, &buf, buf.len);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return any;
        any = true;
    }
}

/// The time now, in seconds since 1970.
fn realNow() i64 {
    return sys.realtimeSec();
}
