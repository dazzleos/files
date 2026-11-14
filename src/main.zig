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
    keys: *Keys,

    pub fn build(r: *const Root, cx: *kete.BuildContext) kete.Widget {
        const width: f32 = if (cx.window()) |w| @floatFromInt(w.size()[0]) else 1280;
        return cx.make(kete.KeyHandler{
            .on_key = .of(r.keys, Keys.key),
            .child = cx.make(view.Files{ .browser = r.browser, .width = width, .now = realNow() }),
        });
    }
};

/// The window's own keys, those that what has the keyboard leaves (a
/// text field keeps what it types, and Backspace): Backspace goes up a
/// folder, Delete asks whether to delete the item picked, Ctrl+C, Ctrl+X
/// and Ctrl+V copy, cut and paste, Escape stops asking, and Space, Left
/// and Right play, pause and seek what is playing.
const Keys = struct {
    browser: *browser_mod.Browser,
    /// A key did something: the window is drawn again.
    pressed: bool = false,

    fn key(k: *Keys, press: kete.Event.Key) bool {
        const browser = k.browser;
        browser.ctrl_held = press.ctrl;
        if (!press.pressed) return false;
        const now = sys.nowNs();
        const asking = browser.prompt != .none;
        switch (press.key) {
            .backspace => browser.request(.up),
            .delete => if (!asking) browser.request(.{ .prompt = .delete }) else return false,
            .escape => if (asking) browser.request(.{ .prompt = .none }) else return false,
            .c => if (press.ctrl) browser.request(.copy) else return false,
            .x => if (press.ctrl) browser.request(.cut) else return false,
            .v => if (press.ctrl) browser.request(.paste) else return false,
            .space, .left, .right => {
                // What is playing: Space plays and pauses, Left and Right
                // seek.
                if (asking) return false;
                const f = if (browser.file) |*f| f else return false;
                const back = press.key == .left;
                switch (f.kind) {
                    .video => |player| if (press.key == .space) player.togglePlay(now) else player.seekTo(if (back) player.position_us -| 5_000_000 else player.position_us + 5_000_000, now),
                    .audio => |player| if (press.key == .space) player.togglePlay() else player.seekRelativeMs(if (back) -5000 else 5000),
                    else => return false,
                }
            },
            else => return false,
        }
        k.pressed = true;
        return true;
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
    const root: Root = .{ .browser = &browser, .keys = &keys };
    const window = try host.app.openWindow(.{
        .title = "Files",
        .root = .of(&root),
        .size = view.open_size,
        .min_size = view.min_size,
        .on_close_request = .close,
    });

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

const testing = std.testing;

test "the window's keys: those a field leaves while it has the keyboard, and all with nothing focused" {
    var t: fs.TestTree = .{};
    try t.init();
    defer t.deinit();
    var b = try browser_mod.Browser.init(testing.allocator, t.path);
    defer b.deinit();
    var keys: Keys = .{ .browser = &b };
    const root: Root = .{ .browser = &b, .keys = &keys };
    const fira = try kete.font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &fira);
    defer u.destroy();
    var n: u64 = 0;
    const Frame = struct {
        fn draw(uu: *kete.ui.WindowUi, bb: *browser_mod.Browser, nn: *u64, r: Root) void {
            _ = bb.apply();
            nn.* += 1;
            uu.frame(1600, 900, nn.*, r);
        }
    }.draw;
    const press = struct {
        fn f(uu: *kete.ui.WindowUi, key: kete.KeyboardKey, char: ?u21) void {
            uu.key(.{ .key = key, .pressed = true, .char = char });
            uu.key(.{ .key = key, .pressed = false });
        }
    }.f;
    var path_buf: [128]u8 = undefined;
    b.request(.{ .open = try std.fmt.bufPrint(&path_buf, "{s}/A-folder", .{t.path}) });
    Frame(u, &b, &n, root);
    try testing.expect(std.mem.endsWith(u8, b.path, "/A-folder"));

    // Naming a new folder, the field has the keyboard: Backspace edits the
    // name (rather than going up), and Escape stops asking.
    b.request(.{ .prompt = .new_folder });
    Frame(u, &b, &n, root);
    Frame(u, &b, &n, root);
    try testing.expect(u.focused != null and u.focused.?.widget.is(kete.TextField));
    press(u, .a, 'a');
    press(u, .backspace, null);
    Frame(u, &b, &n, root);
    try testing.expect(std.mem.endsWith(u8, b.path, "/A-folder"));
    try testing.expectEqual(browser_mod.Prompt.new_folder, b.prompt);
    press(u, .escape, null);
    Frame(u, &b, &n, root);
    Frame(u, &b, &n, root);
    try testing.expectEqual(browser_mod.Prompt.none, b.prompt);

    // With nothing focused, Backspace goes up.
    try testing.expect(u.focused == null);
    press(u, .backspace, null);
    Frame(u, &b, &n, root);
    try testing.expectEqualStrings(t.path, b.path);
    try testing.expect(keys.pressed);
}
