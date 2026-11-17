//! Minimal Win32 layer: the C bindings plus the few conversions we need.

const std = @import("std");

pub const c = @import("win");

/// UTF-8 to NUL-terminated UTF-16 in `buf`.
pub fn wide(buf: []u16, s: []const u8) ?[:0]const u16 {
    const n = std.unicode.utf8ToUtf16Le(buf, s) catch return null;
    if (n + 1 > buf.len) return null;
    buf[n] = 0;
    return buf[0..n :0];
}

pub fn lastError() c.DWORD {
    return c.GetLastError();
}

pub fn env(gpa: std.mem.Allocator, name: []const u8) ?[]u8 {
    var name_buf: [64]u16 = undefined;
    const w_name = wide(&name_buf, name) orelse return null;
    var buf: [1024]u16 = undefined;
    const len = c.GetEnvironmentVariableW(w_name.ptr, &buf, buf.len);
    if (len == 0 or len >= buf.len) return null;
    return std.unicode.wtf16LeToWtf8Alloc(gpa, buf[0..len]) catch null;
}

/// Seconds since the Unix epoch. std.time no longer has a clock without an
/// Io instance, and this is a Win32 app anyway.
pub fn unixNow() i64 {
    var ft: c.FILETIME = undefined;
    c.GetSystemTimeAsFileTime(&ft);
    const v = (@as(u64, @intCast(ft.dwHighDateTime)) << 32) | @as(u64, @intCast(ft.dwLowDateTime));
    return @as(i64, @intCast(v / 10_000_000)) - 11_644_473_600;
}

/// The machine's UTC offset in seconds, so mock data uses local hours.
pub fn utcOffsetSeconds() i32 {
    var tzi: c.TIME_ZONE_INFORMATION = std.mem.zeroes(c.TIME_ZONE_INFORMATION);
    const id = c.GetTimeZoneInformation(&tzi);
    var bias = tzi.Bias;
    if (id == c.TIME_ZONE_ID_DAYLIGHT) bias += tzi.DaylightBias;
    return -bias * 60;
}
