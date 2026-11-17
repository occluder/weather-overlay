//! Small file helpers over the Win32 API, so no std I/O runtime is needed.

const std = @import("std");
const win = @import("win.zig");
const c = win.c;

pub fn readAll(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var wbuf: [1024]u16 = undefined;
    const w = win.wide(&wbuf, path) orelse return error.NameTooLong;

    const handle = c.CreateFileW(w.ptr, c.GENERIC_READ, c.FILE_SHARE_READ, null, c.OPEN_EXISTING, c.FILE_ATTRIBUTE_NORMAL, null);
    if (handle == c.INVALID_HANDLE_VALUE) return error.OpenFailed;
    defer _ = c.CloseHandle(handle);

    var size: c.LARGE_INTEGER = undefined;
    if (c.GetFileSizeEx(handle, &size) == 0) return error.SizeFailed;
    const len: usize = @intCast(size.QuadPart);
    const buf = try gpa.alloc(u8, len + 1);
    errdefer gpa.free(buf);

    var off: usize = 0;
    while (off < len) {
        const want: c.DWORD = @intCast(@min(len - off, 1 << 20));
        var got: c.DWORD = 0;
        if (c.ReadFile(handle, buf.ptr + off, want, &got, null) == 0) return error.ReadFailed;
        if (got == 0) break;
        off += got;
    }
    return buf[0..off];
}

pub fn writeAll(path: []const u8, bytes: []const u8) !void {
    var wbuf: [1024]u16 = undefined;
    const w = win.wide(&wbuf, path) orelse return error.NameTooLong;

    const handle = c.CreateFileW(w.ptr, c.GENERIC_WRITE, 0, null, c.CREATE_ALWAYS, c.FILE_ATTRIBUTE_NORMAL, null);
    if (handle == c.INVALID_HANDLE_VALUE) return error.OpenFailed;
    defer _ = c.CloseHandle(handle);

    var off: usize = 0;
    while (off < bytes.len) {
        const want: c.DWORD = @intCast(@min(bytes.len - off, 1 << 20));
        var put: c.DWORD = 0;
        if (c.WriteFile(handle, bytes.ptr + off, want, &put, null) == 0) return error.WriteFailed;
        off += put;
    }
}

pub fn exists(path: []const u8) bool {
    var wbuf: [1024]u16 = undefined;
    const w = win.wide(&wbuf, path) orelse return false;
    return c.GetFileAttributesW(w.ptr) != c.INVALID_FILE_ATTRIBUTES;
}

pub fn ensureDir(path: []const u8) void {
    var wbuf: [1024]u16 = undefined;
    const w = win.wide(&wbuf, path) orelse return;
    _ = c.CreateDirectoryW(w.ptr, null);
}

pub fn appendAll(path: []const u8, bytes: []const u8) void {
    var wbuf: [1024]u16 = undefined;
    const w = win.wide(&wbuf, path) orelse return;

    const handle = c.CreateFileW(w.ptr, c.FILE_APPEND_DATA, c.FILE_SHARE_READ, null, c.OPEN_ALWAYS, c.FILE_ATTRIBUTE_NORMAL, null);
    if (handle == c.INVALID_HANDLE_VALUE) return;
    defer _ = c.CloseHandle(handle);
    var put: c.DWORD = 0;
    _ = c.WriteFile(handle, bytes.ptr, @intCast(bytes.len), &put, null);
}
