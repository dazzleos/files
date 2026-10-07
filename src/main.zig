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
const vc4 = @import("vc4");
const app = @import("app");
const ui = @import("ui");
const wayland = @import("wayland");
const fs = @import("fs.zig");
const browser_mod = @import("browser.zig");
const view = @import("view.zig");

const print = sys.print;

/// The clear colour: the dark theme's surface.
const background = 0xff141218;

/// Keys: Backspace goes up a folder, Delete asks whether to delete the
/// item picked, Ctrl+C, Ctrl+X and Ctrl+V copy, cut and paste, and
/// Escape stops asking (unless a text field has them).
const key_backspace = 14;
const key_c = 46;
const key_x = 45;
const key_v = 47;
const key_delete = 111;
const key_escape = 1;

var frame: vc4.render.Frame = undefined;

/// How often the progress of a copy is drawn.
const progress_ns = 250 * std.time.ns_per_ms;

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.logToKmsgIfStderr();
    var args = init.args.iterate();
    _ = args.skip();
    var font_buf: [512]u8 = undefined;
    const font_path: [*:0]const u8 = args.next() orelse sys.fontFile(&font_buf, font.default_font_file);
    run(init, font_path) catch |err| {
        print("dazzle-files: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init.Minimal, font_path: [*:0]const u8) !void {
    // The language chosen (in setup, or Settings).
    locale.current = locale.load().language;
    const gpa = std.heap.page_allocator;
    var dev = vc4.device.openRender() catch |err| {
        print("dazzle-files: no GPU ({s})\n", .{@errorName(err)});
        return err;
    };
    const win = try openWindow(gpa, init, &dev);
    var width = win.width;
    var height = win.height;

    var f: ?font.Font = blk: {
        const data = sys.readFileAlloc(gpa, font_path, 32 * 1024 * 1024) catch |err| {
            print("dazzle-files: cannot read the font {s} ({s}); no text\n", .{ font_path, @errorName(err) });
            break :blk null;
        };
        break :blk font.Font.init(data) catch null;
    };
    const window_ui = try ui.Ui.create(gpa, if (f) |*fnt| fnt else null);
    // Copying and pasting go through the system's clipboard.
    window_ui.clipboard = .of(&win.clipboard);
    try window_ui.attachGpu(dev);

    // The user's files, on the SD card.
    var browser = try browser_mod.Browser.init(gpa, sys.system.user_dir);
    defer browser.deinit();
    // USB drives come and go as their folders do in /media.
    const drives_fd = watchDrives();
    win.wake_fd = drives_fd;

    // What the title bar's buttons do, and how small the window may be.
    var controls: app.Controls = .{ .win = win };
    win.setMinSize(view.min_size[0], view.min_size[1]);

    var dirty = true;
    var idle = false;
    var last_progress: u64 = 0;
    var suspended = false;
    while (true) {
        const waited = if (idle) blk: {
            // Nothing changes on its own: wait for input (or a widget's
            // animation).
            const timeout: u64 = if (window_ui.needs_frame and !suspended) 16 * std.time.ns_per_ms else if (browser.copying()) progress_ns else 60 * std.time.ns_per_s;
            break :blk win.wait(timeout);
        } else win.poll();
        waited catch |err| {
            if (err == error.ServerError) print("dazzle-files: compositor error: {s}\n", .{win.conn.errorMessage()});
            return err;
        };
        if (win.closed or controls.quit) return;
        if (try win.applyConfigure()) |size| {
            width = size[0];
            height = size[1];
            dirty = true;
        }
        // Covered by another window: nothing is drawn, and the window in
        // front gets the GPU memory.
        if (win.suspended != suspended) {
            suspended = win.suspended;
            if (suspended) win.releaseSpareBuffers() else dirty = true;
        }
        const now = sys.nowNs();
        // The keyboard's layout, as the shell says.
        window_ui.keyboard = win.layout;
        for (win.takeInput()) |e| switch (e) {
            .motion => |pos| window_ui.pointerMotion(pos),
            .button => |b| window_ui.pointerButton(b.pos, b.code, b.pressed),
            .key => |k| {
                const typing = window_ui.focused != null;
                window_ui.keyEvent(k.code, k.pressed);
                if (k.pressed) switch (k.code) {
                    key_backspace => if (!typing) browser.request(.up),
                    key_delete => if (!typing and browser.prompt == .none) browser.request(.{ .prompt = .delete }),
                    key_escape => if (browser.prompt != .none) browser.request(.{ .prompt = .none }),
                    key_c => if (!typing and window_ui.ctrl > 0) browser.request(.copy),
                    key_x => if (!typing and window_ui.ctrl > 0) browser.request(.cut),
                    key_v => if (!typing and window_ui.ctrl > 0) browser.request(.paste),
                    else => {},
                };
                dirty = true;
            },
            .scroll => |sc| window_ui.pointerScroll(sc.pos, sc.dx, sc.dy),
            .leave => window_ui.pointerLeave(),
            .touch_down => |t| window_ui.touchDown(t.id, t.pos),
            .touch_motion => |t| window_ui.touchMotion(t.id, t.pos),
            .touch_up => |id| window_ui.touchUp(id),
            .touch_cancel => window_ui.touchCancel(),
        };
        if (drives_fd) |fd| if (drained(fd)) {
            browser.refreshDrives();
            dirty = true;
        };
        // What the clicks asked for, now that no widget is handling them.
        if (browser.apply()) dirty = true;

        idle = true;
        // Copying (on its own thread): the window is drawn again, to say
        // how far it has got, a few times a second, and when it is done.
        if (browser.copying()) {
            if (!browser.poll() or now >= last_progress + progress_ns) {
                last_progress = now;
                dirty = true;
            }
        }
        if (!suspended and (dirty or window_ui.needs_frame)) {
            dirty = false;
            window_ui.frame(width, height, now, view.Files{
                .browser = &browser,
                .on_close = .of(&controls, app.Controls.close),
                .on_maximize = .of(&controls, app.Controls.toggleMaximized),
                .on_drag = .of(&controls, app.Controls.drag),
                .maximized = win.maximized,
                .width = @floatFromInt(width),
                .now = realNow(),
            });
            if (window_ui.changed()) {
                idle = false;
                const target = try win.beginFrame();
                const region = window_ui.repaint(win.bufferAge());
                frame.begin(target, .{ .clear = background });
                ui.Ui.limit(&frame, &region);
                try window_ui.render(&frame, win.flusher());
                try win.render(&frame);
                var damage: [ui.damage.Region.max_rects]vc4.render.Viewport = undefined;
                const changed = window_ui.damaged();
                for (changed, damage[0..changed.len]) |r, *v| v.* = .{ .x = @intFromFloat(r.x), .y = @intFromFloat(r.y), .width = @intFromFloat(r.w), .height = @intFromFloat(r.h) };
                try win.showDamaged(damage[0..changed.len]);
            }
        }
    }
}

fn openWindow(gpa: std.mem.Allocator, init: std.process.Init.Minimal, dev: *vc4.Device) !*app.Window {
    const Environ = std.process.Environ;
    // Dazzle's compositor listens on /os/sockets/wayland-0; elsewhere, where
    // WAYLAND_DISPLAY and XDG_RUNTIME_DIR say.
    var path_buf: [128]u8 = undefined;
    const path = wayland.client.socketPath(&path_buf, Environ.getPosix(init.environ, "XDG_RUNTIME_DIR"), Environ.getPosix(init.environ, "WAYLAND_DISPLAY")) catch {
        print("dazzle-files: WAYLAND_DISPLAY needs XDG_RUNTIME_DIR\n", .{});
        return error.NoCompositor;
    };
    const win = app.Window.open(gpa, .device(dev), path, "Files") catch |err| {
        print("dazzle-files: cannot open a window on {s} ({s})\n", .{ path, @errorName(err) });
        return err;
    };
    try win.setAppId("dazzle-files");
    return win;
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
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}
