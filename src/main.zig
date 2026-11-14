//! Dazzle's Files app: browses the files on the system, starting at the
//! root. The tree of folders is on the left and the open folder's
//! contents, as a grid of icons, on the right (see view.zig); folders are
//! read when they are opened (see fs.zig and browser.zig). The window is
//! built with kete, and only what changed is drawn again.
//!
//!     dazzle-files
//!
//! It runs until it is stopped or its window is closed.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const evdev = sys.evdev;
const app = @import("app");
const kete = @import("kete");
const kete_vc4 = @import("kete_vc4");
const fs = @import("fs.zig");
const browser_mod = @import("browser.zig");
const view = @import("view.zig");

const print = sys.print;

/// How often the progress of a copy is drawn.
const progress_ns = 250 * std.time.ns_per_ms;

pub fn main(init: std.process.Init) u8 {
    sys.logToKmsgIfStderr();
    run(init) catch |err| {
        print(sys.log_error ++ "dazzle-files: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

/// The window's root: the folders and the file open, as they are now.
const Root = struct {
    browser: *browser_mod.Browser,

    pub fn build(r: *const Root, cx: *kete.BuildContext) kete.Widget {
        const width: f32 = if (cx.window()) |w| @floatFromInt(w.size()[0]) else 1280;
        return cx.make(view.Files{ .browser = r.browser, .width = width, .now = realNow() });
    }
};

/// The window's own keys, whatever has the keyboard (unless a text field
/// has it, for those that type): Backspace goes up a folder, Delete asks
/// whether to delete the item picked, Ctrl+C, Ctrl+X and Ctrl+V copy, cut
/// and paste, and Escape stops asking.
const Keys = struct {
    browser: *browser_mod.Browser,
    window: ?*kete.App.Window = null,
    /// A key did something: the window is drawn again.
    pressed: bool = false,

    fn key(k: *Keys, press: kete_vc4.KeyPress) void {
        const browser = k.browser;
        browser.ctrl_held = press.ctrl;
        if (!press.pressed) return;
        const typing = if (k.window) |w| w.ui.focused != null else false;
        const now = sys.nowNs();
        switch (press.code) {
            evdev.key_backspace => if (!typing) browser.request(.up),
            evdev.key_delete => if (!typing and browser.prompt == .none) browser.request(.{ .prompt = .delete }),
            evdev.key_esc => if (browser.prompt != .none) browser.request(.{ .prompt = .none }),
            evdev.key_c => if (!typing and press.ctrl) browser.request(.copy),
            evdev.key_x => if (!typing and press.ctrl) browser.request(.cut),
            evdev.key_v => if (!typing and press.ctrl) browser.request(.paste),
            evdev.key_space => if (!typing and browser.prompt == .none) if (browser.file) |*f| switch (f.kind) {
                .video => |player| player.togglePlay(now),
                .audio => |player| player.togglePlay(),
                else => {},
            },
            evdev.key_left => if (!typing and browser.prompt == .none) if (browser.file) |*f| switch (f.kind) {
                .video => |player| player.seekTo(player.position_us -| 5_000_000, now),
                .audio => |player| player.seekRelativeMs(-5000),
                else => {},
            },
            evdev.key_right => if (!typing and browser.prompt == .none) if (browser.file) |*f| switch (f.kind) {
                .video => |player| player.seekTo(player.position_us + 5_000_000, now),
                .audio => |player| player.seekRelativeMs(5000),
                else => {},
            },
            else => {},
        }
        k.pressed = true;
    }
};

fn run(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    var host: kete_vc4.Host = undefined;
    try host.init(gpa, init.io, init.minimal.environ, .{ .app_id = "dazzle-files" });
    defer host.deinit();

    // Apps it starts (the text editor) find the compositor as it did.
    var child_env: app.ChildEnv = undefined;
    browser_mod.app_env = child_env.init(init.minimal.environ, "/");

    // The user's files, on the SD card.
    var browser = try browser_mod.Browser.init(gpa, sys.system.user_dir);
    defer browser.deinit();
    // Watch the open folder, the folders open in the tree, and /media.
    if (browser.watch_fd) |fd| host.wakeOn(fd, true);

    var keys: Keys = .{ .browser = &browser };
    host.display.on_key = .of(&keys, Keys.key);
    const root: Root = .{ .browser = &browser };
    const window = try host.app.openWindow(.{
        .title = "Files",
        .root = .of(&root),
        .size = view.open_size,
        .min_size = view.min_size,
        .on_close_request = .close,
    });
    keys.window = window;

    var last_progress: u64 = 0;
    var suspended = false;
    while (try host.step(browser.videoWakeNs() orelse if (browser.copying()) progress_ns else 60 * std.time.ns_per_s)) {
        if (window.suspended != suspended) {
            suspended = window.suspended;
            // An editor may have been installed or removed meanwhile.
            if (!suspended) browser.findEditor();
        }
        const now = sys.nowNs();
        if (keys.pressed) {
            keys.pressed = false;
            host.redraw();
        }
        // What the clicks asked for, now that no widget is handling them.
        if (browser.apply()) host.redraw();
        if (browser.checkWatches()) host.redraw();
        const shown_at = if (host.display.window) |*w| w.nextPresentationNs(now) else now;
        if (browser.stepVideo(shown_at)) host.redraw();

        // Copying (on its own thread): the window is drawn again, to say
        // how far it has got, a few times a second, and when it is done.
        if (browser.copying()) {
            if (!browser.poll() or now >= last_progress + progress_ns) {
                last_progress = now;
                host.redraw();
            }
        }
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

/// The time now, in seconds since 1970.
fn realNow() i64 {
    return sys.realtimeSec();
}
