//! Entry point: flags, single instance, fetch or cache, PNG dump.

const std = @import("std");
const P = @import("gdiplus.zig");
const draw = @import("draw.zig");
const model = @import("model.zig");
const png = @import("png.zig");
const fs = @import("fs.zig");
const win = @import("win.zig");
const c = win.c;
const config = @import("config.zig");
const http = @import("http.zig");
const overlay = @import("overlay.zig");
const autostart = @import("autostart.zig");
const log = @import("log.zig");

const Bg = enum { dark, bright, photo };

const Args = struct {
    dump: ?[]const u8 = null,
    width: i32 = 1920,
    bg: Bg = .dark,
    mock: bool = false,
    hold: bool = false,
    install: bool = false,
    uninstall: bool = false,
    boot: bool = false,
    dismiss_ms: u32 = 0,
};

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    const argv = try init.args.toSlice(gpa);

    var a = Args{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--dump")) {
            i += 1;
            if (i < argv.len) a.dump = argv[i];
        } else if (std.mem.eql(u8, arg, "--width")) {
            i += 1;
            if (i < argv.len) a.width = std.fmt.parseInt(i32, argv[i], 10) catch a.width;
        } else if (std.mem.eql(u8, arg, "--bg")) {
            i += 1;
            if (i < argv.len) {
                a.bg = if (std.mem.eql(u8, argv[i], "bright"))
                    .bright
                else if (std.mem.eql(u8, argv[i], "photo"))
                    .photo
                else
                    .dark;
            }
        } else if (std.mem.eql(u8, arg, "--mock")) {
            a.mock = true;
        } else if (std.mem.eql(u8, arg, "--hold")) {
            a.hold = true;
        } else if (std.mem.eql(u8, arg, "--install")) {
            a.install = true;
        } else if (std.mem.eql(u8, arg, "--uninstall")) {
            a.uninstall = true;
        } else if (std.mem.eql(u8, arg, "--boot")) {
            a.boot = true;
        } else if (std.mem.eql(u8, arg, "--dismiss")) {
            i += 1;
            if (i < argv.len) a.dismiss_ms = std.fmt.parseInt(u32, argv[i], 10) catch 0;
        }
    }

    log.init(gpa);

    if (a.install) {
        autostart.install(gpa) catch |err| {
            log.write("install failed: {t}", .{err});
            return err;
        };
        log.write("installed autostart", .{});
        return;
    }
    if (a.uninstall) {
        autostart.uninstall() catch |err| {
            log.write("uninstall failed: {t}", .{err});
            return err;
        };
        log.write("removed autostart", .{});
        return;
    }

    var token: usize = 0;
    var ginput = P.GdiplusStartupInput{};
    if (P.GdiplusStartup(&token, &ginput, null) != P.ok) return error.GdiplusStartup;
    defer P.GdiplusShutdown(token);

    const cfg = config.load(gpa);
    if (cfg.parse_failed) log.write("config.json is not valid JSON, using defaults", .{});

    if (a.dump) |path| {
        var f = model.mock(gpa, win.utcOffsetSeconds()) catch return error.Mock;
        try dumpBand(gpa, &f, a.width, path, a.bg);
        return;
    }

    if (!acquireSingleton()) {
        log.write("another instance is running", .{});
        return;
    }

    log.write("fetching (mock={})", .{a.mock});
    var forecast = loadForecast(gpa, cfg, a.mock) orelse {
        log.write("no forecast available, not showing", .{});
        return;
    };

    log.write("showing band (boot={})", .{a.boot});
    try overlay.show(gpa, &forecast, .{
        .hold = a.hold,
        .dismiss_ms = a.dismiss_ms,
        .failsafe_ms = if (a.boot) 0 else overlay.default_failsafe_ms,
        .fade_out_ms = cfg.fade_out_ms,
    });
    log.write("done", .{});
}

fn acquireSingleton() bool {
    const name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\WeatherOverlaySingleton");
    const mutex = c.CreateMutexW(null, 1, name);
    if (mutex == null) return true;
    return c.GetLastError() != c.ERROR_ALREADY_EXISTS;
}

const Source = enum { onecall, three_hour };

fn sourcePath(gpa: std.mem.Allocator, lat: f32, lon: f32, key: []const u8, src: Source) ?[]const u8 {
    return switch (src) {
        .onecall => std.fmt.allocPrint(
            gpa,
            "/data/3.0/onecall?lat={d:.4}&lon={d:.4}&units=metric&exclude=minutely,alerts&appid={s}",
            .{ lat, lon, key },
        ) catch null,
        .three_hour => std.fmt.allocPrint(
            gpa,
            "/data/2.5/forecast?lat={d:.4}&lon={d:.4}&units=metric&appid={s}",
            .{ lat, lon, key },
        ) catch null,
    };
}

fn cacheName(src: Source) []const u8 {
    return switch (src) {
        .onecall => "last-onecall.json",
        .three_hour => "last-3h.json",
    };
}

fn parseBody(gpa: std.mem.Allocator, src: Source, body: []const u8, now: i64, hours: usize) !model.Forecast {
    return switch (src) {
        .onecall => model.fromOneCall(gpa, body, now, hours),
        .three_hour => model.fromThreeHourly(gpa, body, now, hours),
    };
}

fn trySource(gpa: std.mem.Allocator, cfg: config.Config, now: i64, src: Source) ?model.Forecast {
    const path = sourcePath(gpa, cfg.lat.?, cfg.lon.?, cfg.api_key, src) orelse return null;
    defer gpa.free(path);

    const resp = http.get(gpa, "api.openweathermap.org", path, 4000) catch |err| {
        log.write("{s}: transport failed: {t}", .{ @tagName(src), err });
        return null;
    };
    defer gpa.free(resp.body);

    if (resp.status != 200) {
        log.write("{s}: http {d}", .{ @tagName(src), resp.status });
        return null;
    }

    const f = parseBody(gpa, src, resp.body, now, cfg.hours) catch |err| {
        log.write("{s}: parse failed: {t}", .{ @tagName(src), err });
        return null;
    };

    if (config.cachePathNamed(gpa, cacheName(src))) |cp| fs.writeAll(cp, resp.body) catch {};
    log.write("{s}: {d} points from {d} bytes", .{ @tagName(src), f.n, resp.body.len });
    return f;
}

fn loadForecast(gpa: std.mem.Allocator, cfg: config.Config, force_mock: bool) ?model.Forecast {
    if (force_mock or cfg.api_key.len == 0 or !cfg.hasLocation()) {
        return model.mock(gpa, win.utcOffsetSeconds()) catch null;
    }

    const now = win.unixNow();

    // One Call 3.0 first (true hourly), then the free three-hourly endpoint.
    if (trySource(gpa, cfg, now, .onecall)) |f| return f;
    if (trySource(gpa, cfg, now, .three_hour)) |f| return f;

    // Last resort: whatever we fetched successfully before.
    for ([_]Source{ .onecall, .three_hour }) |src| {
        const cp = config.cachePathNamed(gpa, cacheName(src)) orelse continue;
        defer gpa.free(cp);
        const body = fs.readAll(gpa, cp) catch continue;
        defer gpa.free(body);
        var f = parseBody(gpa, src, body, now, cfg.hours) catch continue;
        f.stale = true;
        log.write("using cached forecast from {s}", .{@tagName(src)});
        return f;
    }
    return null;
}

fn dumpBand(gpa: std.mem.Allocator, f: *const model.Forecast, width: i32, path: []const u8, bg: Bg) !void {
    const m = draw.Metrics.fromWidth(width);
    const height: i32 = @intFromFloat(m.band_h);
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);

    const pixels = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(pixels);

    draw.render(pixels, width, height, f);

    const rgb = try gpa.alloc(u8, w * h * 3);
    defer gpa.free(rgb);

    var y: usize = 0;
    while (y < h) : (y += 1) {
        const fy = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(h - 1));
        const base: [3]f32 = switch (bg) {
            .dark => .{ 30.0 - 14.0 * fy, 36.0 - 16.0 * fy, 48.0 - 20.0 * fy },
            .bright => .{ 245.0 - 20.0 * fy, 246.0 - 20.0 * fy, 248.0 - 18.0 * fy },
            .photo => .{ 42.0 + 40.0 * (1.0 - fy), 58.0 + 30.0 * (1.0 - fy), 92.0 + 20.0 * (1.0 - fy) },
        };
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const s = pixels[(y * w + x) * 4 ..][0..4];
            const a: f32 = @as(f32, @floatFromInt(s[3])) / 255.0;
            const inv = 1.0 - a;
            rgb[(y * w + x) * 3 + 0] = @intFromFloat(@min(255.0, @ceil(@as(f32, @floatFromInt(s[2])) + base[0] * inv)));
            rgb[(y * w + x) * 3 + 1] = @intFromFloat(@min(255.0, @ceil(@as(f32, @floatFromInt(s[1])) + base[1] * inv)));
            rgb[(y * w + x) * 3 + 2] = @intFromFloat(@min(255.0, @ceil(@as(f32, @floatFromInt(s[0])) + base[2] * inv)));
        }
    }

    const bytes = try png.encode(gpa, rgb, @intCast(w), @intCast(h));
    defer gpa.free(bytes);
    try fs.writeAll(path, bytes);
}
