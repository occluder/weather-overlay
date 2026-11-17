//! Register the overlay in HKCU's Run key so it appears at logon.
//!
//! The registry functions are declared here with pointer-sized integer handles:
//! the translated SDK header would otherwise force a comptime cast of the
//! pseudo-handle HKEY_CURRENT_USER (0x80000001), which Zig rejects because the
//! value is not pointer-aligned.

const std = @import("std");
const win = @import("win.zig");
const c = win.c;

const HKEY = usize;
const hkey_current_user: HKEY = 0x80000001;

const key_set_value: u32 = 0x0002;
const reg_sz: u32 = 1;

extern "advapi32" fn RegCreateKeyExW(
    key: HKEY,
    sub_key: [*:0]const u16,
    reserved: u32,
    class: ?*anyopaque,
    options: u32,
    sam: u32,
    sa: ?*anyopaque,
    result: *HKEY,
    disposition: ?*u32,
) callconv(.c) c_long;

extern "advapi32" fn RegSetValueExW(
    key: HKEY,
    value_name: [*:0]const u16,
    reserved: u32,
    kind: u32,
    data: [*]const u8,
    bytes: u32,
) callconv(.c) c_long;

extern "advapi32" fn RegDeleteValueW(key: HKEY, value_name: [*:0]const u16) callconv(.c) c_long;

extern "advapi32" fn RegCloseKey(key: HKEY) callconv(.c) c_long;

const run_key = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const value_name = "WeatherOverlay";

fn openRunKey() ?HKEY {
    var wbuf: [128]u16 = undefined;
    const wk = win.wide(&wbuf, run_key) orelse return null;
    var key: HKEY = 0;
    if (RegCreateKeyExW(hkey_current_user, wk.ptr, 0, null, 0, key_set_value, null, &key, null) != 0) return null;
    return key;
}

pub fn exePath(gpa: std.mem.Allocator) ?[]const u8 {
    var buf: [1024]u16 = undefined;
    const n = c.GetModuleFileNameW(null, &buf, buf.len);
    if (n == 0) return null;
    return std.unicode.wtf16LeToWtf8Alloc(gpa, buf[0..n]) catch null;
}

pub fn install(gpa: std.mem.Allocator) !void {
    const exe = exePath(gpa) orelse return error.NoExePath;
    defer gpa.free(exe);

    // Keep the registered copy outside the build directory so a later
    // `zig build` cannot swap the autostart target for a debug binary.
    const dir = @import("config.zig").localDir(gpa) orelse return error.NoExePath;
    @import("fs.zig").ensureDir(dir);
    const target = std.fmt.allocPrint(gpa, "{s}\\weather-overlay.exe", .{dir}) catch return error.OutOfMemory;
    defer gpa.free(target);

    if (!std.mem.eql(u8, exe, target)) {
        var wsrc: [1024]u16 = undefined;
        var wdst: [1024]u16 = undefined;
        const ws = win.wide(&wsrc, exe) orelse return error.NoExePath;
        const wd = win.wide(&wdst, target) orelse return error.NoExePath;
        if (c.CopyFileW(ws.ptr, wd.ptr, 0) == 0) return error.CopyFailed;
    }

    const key = openRunKey() orelse return error.Registry;
    defer _ = RegCloseKey(key);

    var value_buf: [1200]u8 = undefined;
    const value = std.fmt.bufPrint(&value_buf, "\"{s}\" --boot", .{target}) catch return error.NoExePath;

    var wname: [64]u16 = undefined;
    const wn = win.wide(&wname, value_name) orelse return error.Registry;
    var wvalue: [1200]u16 = undefined;
    const wv = win.wide(&wvalue, value) orelse return error.Registry;

    const bytes: u32 = @intCast((wv.len + 1) * 2);
    if (RegSetValueExW(key, wn.ptr, 0, reg_sz, @ptrCast(wv.ptr), bytes) != 0) return error.Registry;
}

pub fn uninstall() !void {
    const key = openRunKey() orelse return error.Registry;
    defer _ = RegCloseKey(key);
    var wname: [64]u16 = undefined;
    const wn = win.wide(&wname, value_name) orelse return error.Registry;
    _ = RegDeleteValueW(key, wn.ptr);
}
