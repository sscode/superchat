//! This build belongs to your app, written once by `native eject`:
//! the `native` CLI stops generating a build graph and
//! drives this file through `zig build` instead, and it will
//! never rewrite it. `addApp` wires the complete standard app
//! build — executable, `zig build run`, `zig build test`, and
//! the -Dplatform/-Dweb-engine/-Dautomation/-Doptimize flags —
//! from the framework's build/app.zig, so a framework upgrade
//! still upgrades your build. Extend from here with
//! `addAppArtifacts` when you need extra sources or steps.

const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const artifacts = native_sdk.addAppArtifacts(b, b.dependency("native_sdk", .{}), .{ .name = "superchat" });
    const app_options = b.addOptions();
    app_options.addOption(bool, "credential_store", b.option(bool, "credential-store", "Persist credentials in the OS keychain (signed releases only)") orelse false);
    app_options.addOption([]const u8, "version", "0.1.1");
    artifacts.exe.root_module.addOptions("superchat_options", app_options);
    artifacts.tests.root_module.addOptions("superchat_options", app_options);
    if (b.sysroot) |sysroot| {
        const include_path: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr/include" }) };
        const library_path: std.Build.LazyPath = .{ .cwd_relative = "/usr/lib" };
        artifacts.exe.root_module.addSystemIncludePath(include_path);
        artifacts.exe.root_module.addLibraryPath(library_path);
        artifacts.tests.root_module.addSystemIncludePath(include_path);
        artifacts.tests.root_module.addLibraryPath(library_path);
    }
    artifacts.exe.root_module.linkSystemLibrary("sqlite3", .{});
    artifacts.tests.root_module.linkSystemLibrary("sqlite3", .{});
}
