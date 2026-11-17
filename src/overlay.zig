//! Layered band window, fade in and out, and the mouse hook that dismisses it.

const std = @import("std");
const win = @import("win.zig");
const c = win.c;
const draw = @import("draw.zig");
const model = @import("model.zig");
const log = @import("log.zig");

const click_msg: c.UINT = @as(c.UINT, @intCast(c.WM_APP)) + 1;
const timer_tick: c.UINT_PTR = 1;
const timer_arm: c.UINT_PTR = 2;
const timer_failsafe: c.UINT_PTR = 3;

pub const Options = struct {
    hold: bool = false,
    failsafe_ms: u32 = 90_000,
    fade_in_ms: u32 = 200,
    fade_out_ms: u32 = 450,
    /// Debug: dismiss this long after showing, without needing a click.
    dismiss_ms: u32 = 0,
};

const Phase = enum { fade_in, shown, fade_out, done };

const State = struct {
    hwnd: c.HWND = null,
    mem_dc: c.HDC = null,
    dib: c.HBITMAP = null,
    pixels: []u8 = &.{},
    width: i32 = 0,
    height: i32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    alpha: i32 = 0,
    phase: Phase = .fade_in,
    phase_started_ms: u64 = 0,
    fade_in_ms: u32 = 200,
    fade_out_ms: u32 = 450,
    armed: bool = false,
    hook: ?c.HHOOK = null,
    hold: bool = false,
};

var g: State = .{};

pub fn show(gpa: std.mem.Allocator, f: *const model.Forecast, opts: Options) !void {
    _ = c.SetProcessDpiAwarenessContext(c.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    var mi: c.MONITORINFO = std.mem.zeroes(c.MONITORINFO);
    mi.cbSize = @sizeOf(c.MONITORINFO);
    const mon = c.MonitorFromPoint(.{ .x = 0, .y = 0 }, c.MONITOR_DEFAULTTOPRIMARY);
    _ = c.GetMonitorInfoW(mon, &mi);
    const rc = mi.rcMonitor;

    g.width = rc.right - rc.left;
    const m = draw.Metrics.fromWidth(g.width);
    g.height = @intFromFloat(m.band_h);
    g.x = rc.left;
    g.y = rc.bottom - g.height;
    log.write("monitor {d},{d}..{d},{d} band {d}x{d} at {d},{d}", .{
        rc.left, rc.top, rc.right, rc.bottom, g.width, g.height, g.x, g.y,
    });
    g.hold = opts.hold;
    g.fade_in_ms = @max(opts.fade_in_ms, 16);
    g.fade_out_ms = @max(opts.fade_out_ms, 80);
    g.phase_started_ms = nowMs();

    const hinst = c.GetModuleHandleW(null);
    var wc: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hinst;
    wc.lpszClassName = std.unicode.utf8ToUtf16LeStringLiteral("WeatherOverlayBand");
    if (c.RegisterClassExW(&wc) == 0) return error.RegisterClass;

    const ex_style: c.DWORD = c.WS_EX_LAYERED | c.WS_EX_TRANSPARENT | c.WS_EX_TOOLWINDOW |
        c.WS_EX_NOACTIVATE | c.WS_EX_TOPMOST;
    const hwnd = c.CreateWindowExW(
        ex_style,
        wc.lpszClassName,
        std.unicode.utf8ToUtf16LeStringLiteral("Weather overlay"),
        c.WS_POPUP,
        g.x,
        g.y,
        g.width,
        g.height,
        null,
        null,
        hinst,
        null,
    );
    if (hwnd == null) return error.CreateWindow;
    g.hwnd = hwnd;

    // The DIB is the render target: draw straight into it, then hand its DC to
    // UpdateLayeredWindow.
    var bmi: c.BITMAPINFO = std.mem.zeroes(c.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = g.width;
    bmi.bmiHeader.biHeight = -g.height; // top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = c.BI_RGB;

    var bits: ?*anyopaque = null;
    const dib = c.CreateDIBSection(null, &bmi, c.DIB_RGB_COLORS, &bits, null, 0);
    if (dib == null or bits == null) return error.CreateDib;
    g.dib = dib;

    const byte_len: usize = @as(usize, @intCast(g.width)) * @as(usize, @intCast(g.height)) * 4;
    const ptr: [*]u8 = @ptrCast(bits.?);
    g.pixels = ptr[0..byte_len];

    g.mem_dc = c.CreateCompatibleDC(null);
    _ = c.SelectObject(g.mem_dc, dib);

    draw.render(g.pixels, g.width, g.height, f);
    g.alpha = 0;
    blit();

    _ = c.ShowWindow(hwnd, c.SW_SHOWNOACTIVATE);
    _ = c.SetTimer(hwnd, timer_tick, 16, null);
    if (!opts.hold) {
        const delay = if (opts.dismiss_ms > 0) opts.dismiss_ms else opts.failsafe_ms;
        _ = c.SetTimer(hwnd, timer_failsafe, delay, null);
    }

    var msg: c.MSG = std.mem.zeroes(c.MSG);
    while (c.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageW(&msg);
    }

    removeHook();
    _ = c.KillTimer(hwnd, timer_tick);
    _ = c.KillTimer(hwnd, timer_arm);
    _ = c.KillTimer(hwnd, timer_failsafe);
    log.write("loop exited", .{});
    if (g.mem_dc != null) _ = c.DeleteDC(g.mem_dc);
    if (g.dib != null) _ = c.DeleteObject(g.dib);
    _ = gpa;
}

fn blit() void {
    var dst = c.POINT{ .x = g.x, .y = g.y };
    var size = c.SIZE{ .cx = g.width, .cy = g.height };
    var src = c.POINT{ .x = 0, .y = 0 };
    var blend = c.BLENDFUNCTION{
        .BlendOp = c.AC_SRC_OVER,
        .BlendFlags = 0,
        .SourceConstantAlpha = @intCast(std.math.clamp(g.alpha, 0, 255)),
        .AlphaFormat = c.AC_SRC_ALPHA,
    };
    _ = c.UpdateLayeredWindow(g.hwnd, null, &dst, &size, g.mem_dc, &src, 0, &blend, c.ULW_ALPHA);
}

fn installHook() void {
    if (g.hold or g.hook != null) return;
    const h = c.SetWindowsHookExW(c.WH_MOUSE_LL, hookProc, c.GetModuleHandleW(null), 0);
    if (h == null) {
        log.write("mouse hook failed, err={d}", .{c.GetLastError()});
        return;
    }
    g.hook = h;
    g.armed = true;
}

fn removeHook() void {
    if (g.hook) |h| {
        _ = c.UnhookWindowsHookEx(h);
        g.hook = null;
    }
    g.armed = false;
}

fn hookProc(code: c_int, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
    if (code >= 0 and g.armed) {
        const m: c.UINT = @intCast(wparam);
        if (m == c.WM_LBUTTONDOWN or m == c.WM_RBUTTONDOWN or m == c.WM_MBUTTONDOWN) {
            _ = c.PostMessageW(g.hwnd, click_msg, 0, 0);
        }
    }
    return c.CallNextHookEx(null, code, wparam, lparam);
}

fn nowMs() u64 {
    return @intCast(c.GetTickCount64());
}

fn startFadeOut() void {
    if (g.phase == .fade_out or g.phase == .done) return;
    g.phase = .fade_out;
    g.phase_started_ms = nowMs();
    log.write("fade out from alpha {d}", .{g.alpha});
    removeHook();
}

fn tick() void {
    switch (g.phase) {
        .fade_in => {
            const elapsed = nowMs() - g.phase_started_ms;
            const progress = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(g.fade_in_ms));
            if (progress >= 1.0) {
                g.alpha = 255;
                g.phase = .shown;
                g.phase_started_ms = nowMs();
                _ = c.SetTimer(g.hwnd, timer_arm, 250, null);
            } else {
                g.alpha = @intFromFloat(255.0 * progress);
            }
            blit();
        },
        .fade_out => {
            const elapsed = nowMs() - g.phase_started_ms;
            const progress = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(g.fade_out_ms));
            if (progress >= 1.0) {
                g.alpha = 0;
                blit();
                g.phase = .done;
                log.write("fade out took {d} ms", .{elapsed});
                _ = c.KillTimer(g.hwnd, timer_tick);
                _ = c.DestroyWindow(g.hwnd);
                return;
            }
            g.alpha = @intFromFloat(255.0 * (1.0 - progress));
            blit();
        },
        else => {},
    }
}

fn onTimer(id: c.UINT_PTR) void {
    if (id == timer_tick) {
        tick();
    } else if (id == timer_arm) {
        _ = c.KillTimer(g.hwnd, timer_arm);
        installHook();
    } else if (id == timer_failsafe) {
        _ = c.KillTimer(g.hwnd, timer_failsafe);
        startFadeOut();
    }
}

fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
    switch (msg) {
        c.WM_TIMER => {
            onTimer(@intCast(wparam));
            return 0;
        },
        click_msg => {
            startFadeOut();
            return 0;
        },
        c.WM_CLOSE => {
            startFadeOut();
            return 0;
        },
        c.WM_DESTROY => {
            c.PostQuitMessage(0);
            return 0;
        },
        else => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
