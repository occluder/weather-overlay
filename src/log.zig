//! Append-only log file. A GUI build has no console.

const std = @import("std");
const win = @import("win.zig");
const fs = @import("fs.zig");

var path: ?[]const u8 = null;

pub fn init(gpa: std.mem.Allocator) void {
    const cfg = @import("config.zig");
    if (cfg.localDir(gpa)) |dir| fs.ensureDir(dir);
    path = cfg.logPath(gpa) orelse return;
}

pub fn write(comptime fmt: []const u8, args: anytype) void {
    const p = path orelse return;
    var buf: [1024]u8 = undefined;

    var st: win.c.SYSTEMTIME = std.mem.zeroes(win.c.SYSTEMTIME);
    win.c.GetLocalTime(&st);
    const head = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}:{d:0>2} ", .{
        st.wHour, st.wMinute, st.wSecond,
    }) catch return;

    const body = std.fmt.bufPrint(buf[head.len..], fmt, args) catch "";
    var line: [1200]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "{s}{s}\n", .{ head, body }) catch return;
    fs.appendAll(p, text);
}
