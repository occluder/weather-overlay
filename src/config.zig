//! Configuration and cache locations under %APPDATA% and %LOCALAPPDATA%.

const std = @import("std");
const win = @import("win.zig");
const fs = @import("fs.zig");

pub const Config = struct {
    api_key: []const u8 = "",
    lat: ?f32 = null,
    lon: ?f32 = null,
    hours: usize = 12,
    fade_out_ms: u32 = 450,
    parse_failed: bool = false,

    pub fn hasLocation(self: Config) bool {
        return self.lat != null and self.lon != null;
    }
};

const default_file =
    \\{
    \\  "apiKey": "",
    \\  "lat": null,
    \\  "lon": null,
    \\  "hours": 12,
    \\  "fadeOutMs": 450
    \\}
    \\
;

const Raw = struct {
    apiKey: ?[]const u8 = null,
    lat: ?f32 = null,
    lon: ?f32 = null,
    hours: ?usize = null,
    fadeOutMs: ?u32 = null,
};

fn envDir(gpa: std.mem.Allocator, var_name: []const u8) ?[]const u8 {
    const base = win.env(gpa, var_name) orelse return null;
    defer gpa.free(base);
    return std.fmt.allocPrint(gpa, "{s}\\weather-overlay", .{base}) catch null;
}

pub fn appDir(gpa: std.mem.Allocator) ?[]const u8 {
    return envDir(gpa, "APPDATA");
}

pub fn localDir(gpa: std.mem.Allocator) ?[]const u8 {
    return envDir(gpa, "LOCALAPPDATA");
}

pub fn configPath(gpa: std.mem.Allocator) ?[]const u8 {
    const dir = appDir(gpa) orelse return null;
    return std.fmt.allocPrint(gpa, "{s}\\config.json", .{dir}) catch null;
}

pub fn cachePath(gpa: std.mem.Allocator) ?[]const u8 {
    return cachePathNamed(gpa, "last-onecall.json");
}

pub fn cachePathNamed(gpa: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const dir = localDir(gpa) orelse return null;
    return std.fmt.allocPrint(gpa, "{s}\\{s}", .{ dir, name }) catch null;
}

pub fn logPath(gpa: std.mem.Allocator) ?[]const u8 {
    const dir = localDir(gpa) orelse return null;
    return std.fmt.allocPrint(gpa, "{s}\\log.txt", .{dir}) catch null;
}

pub fn load(gpa: std.mem.Allocator) Config {
    var cfg = Config{};
    const dir = appDir(gpa) orelse return cfg;
    fs.ensureDir(dir);

    const path = configPath(gpa) orelse return cfg;
    if (!fs.exists(path)) {
        fs.writeAll(path, default_file) catch {};
        return cfg;
    }

    const body = fs.readAll(gpa, path) catch return cfg;
    defer gpa.free(body);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const parsed = std.json.parseFromSlice(Raw, arena_state.allocator(), body, .{
        .ignore_unknown_fields = true,
    }) catch {
        cfg.parse_failed = true;
        return cfg;
    };
    const r = parsed.value;

    if (r.apiKey) |v| cfg.api_key = gpa.dupe(u8, v) catch cfg.api_key;
    if (r.lat) |v| cfg.lat = v;
    if (r.lon) |v| cfg.lon = v;
    if (r.hours) |v| cfg.hours = @min(@max(v, 6), 24);
    if (r.fadeOutMs) |v| cfg.fade_out_ms = @min(@max(v, 80), 2000);
    return cfg;
}
