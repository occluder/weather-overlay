//! WinHTTP GET: no TLS library, no certificate bundle, system proxy aware.

const std = @import("std");
const win = @import("win.zig");
const c = win.c;

pub const Error = error{
    Session,
    Connect,
    Request,
    Send,
    Receive,
    Read,
    Status,
    OutOfMemory,
};

pub const Response = struct {
    status: u32,
    body: []u8,
};

/// Transport failure is an error; a non-200 answer is a normal result so the
/// caller can log the status and decide what to do.
pub fn get(gpa: std.mem.Allocator, host: []const u8, path: []const u8, timeout_ms: u32) Error!Response {
    var host_buf: [256]u16 = undefined;
    const w_host = win.wide(&host_buf, host) orelse return error.Connect;
    var path_buf: [2048]u16 = undefined;
    const w_path = win.wide(&path_buf, path) orelse return error.Request;

    const session = c.WinHttpOpen(
        std.unicode.utf8ToUtf16LeStringLiteral("WeatherOverlay/1.0"),
        c.WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
        null,
        null,
        0,
    );
    if (session == null) return error.Session;
    defer _ = c.WinHttpCloseHandle(session);

    const t: c_int = @intCast(timeout_ms);
    _ = c.WinHttpSetTimeouts(session, t, t, t, t);

    const conn = c.WinHttpConnect(session, w_host.ptr, c.INTERNET_DEFAULT_HTTPS_PORT, 0);
    if (conn == null) return error.Connect;
    defer _ = c.WinHttpCloseHandle(conn);

    const req = c.WinHttpOpenRequest(
        conn,
        std.unicode.utf8ToUtf16LeStringLiteral("GET"),
        w_path.ptr,
        null,
        null,
        null,
        c.WINHTTP_FLAG_SECURE,
    );
    if (req == null) return error.Request;
    defer _ = c.WinHttpCloseHandle(req);

    if (c.WinHttpSendRequest(req, null, 0, null, 0, 0, 0) == 0) return error.Send;
    if (c.WinHttpReceiveResponse(req, null) == 0) return error.Receive;

    var status: c.DWORD = 0;
    var status_len: c.DWORD = @sizeOf(c.DWORD);
    if (c.WinHttpQueryHeaders(
        req,
        c.WINHTTP_QUERY_STATUS_CODE | c.WINHTTP_QUERY_FLAG_NUMBER,
        null,
        &status,
        &status_len,
        null,
    ) == 0) return error.Status;

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(gpa);

    var buf: [8192]u8 = undefined;
    while (true) {
        var available: c.DWORD = 0;
        if (c.WinHttpQueryDataAvailable(req, &available) == 0) return error.Read;
        if (available == 0) break;
        var got: c.DWORD = 0;
        const want: c.DWORD = @min(available, @as(c.DWORD, buf.len));
        if (c.WinHttpReadData(req, &buf, want, &got) == 0) return error.Read;
        if (got == 0) break;
        try body.appendSlice(gpa, buf[0..got]);
    }

    return .{ .status = status, .body = try body.toOwnedSlice(gpa) };
}
