//! Files, an app for browsing the files on the computer and on USB drives, for Dazzle: built with Dazzle's modules and
//! tools (see Dazzle's build.zig, `addApp`).
//!
//!     zig build                 the program, and its archive and catalogue (zig-out/apps)
//!     zig build test            its tests, on this computer
//!
//! With a Dazzle (or kete) checkout of your own beside it:
//! `zig build --fork=../dazzle`.

const std = @import("std");
const dazzle = @import("dazzle");

pub fn build(b: *std.Build) void {
    _ = dazzle.addApp(b, .{
        .name = "dazzle-files",
        .icon = .folder,
        .title = "Files",
        .description = "Browse your files",
        .about = "Browse the files on this computer and on USB drives plugged into it: open them with the app that opens their kind, see photos, and make, rename, copy, move and delete files and folders.",
    });
}
