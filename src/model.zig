//! The forecast the overlay draws, plus the OpenWeatherMap One Call 3.0 mapping
//! and the mock day used when no API key is configured.

const std = @import("std");

pub const max_hours = 48;

pub const Condition = enum {
    clear,
    partly,
    cloudy,
    overcast,
    rain,
    snow,
    thunder,
    fog,
    unknown,

    pub fn label(self: Condition) []const u8 {
        return switch (self) {
            .clear => "Clear sky",
            .partly => "Partly cloudy",
            .cloudy => "Cloudy",
            .overcast => "Overcast",
            .rain => "Rain",
            .snow => "Snow",
            .thunder => "Thunderstorm",
            .fog => "Fog",
            .unknown => "—",
        };
    }

    fn fromId(id: i32) Condition {
        if (id >= 200 and id < 300) return .thunder;
        if (id >= 500 and id < 600) return .rain;
        if (id >= 600 and id < 700) return .snow;
        if (id >= 300 and id < 400) return .rain;
        if (id == 800) return .clear;
        if (id == 801 or id == 802) return .partly;
        if (id == 803) return .cloudy;
        if (id == 804) return .overcast;
        if (id > 700 and id < 800) return .fog;
        return .unknown;
    }
};

pub const Hour = struct {
    ts: i64,
    temp: f32,
    pop: f32,
    mm: f32,
    cond: Condition,
};

pub const Forecast = struct {
    tz_offset: i32 = 0,
    now_ts: i64 = 0,
    current_temp: f32 = 0,
    feels_like: f32 = 0,
    humidity: i32 = 0,
    cond: Condition = .unknown,
    hi: f32 = 0,
    lo: f32 = 0,
    sunrise: i64 = 0,
    sunset: i64 = 0,
    hours: [max_hours]Hour = undefined,
    n: usize = 0,
    stale: bool = false,
    rain_total: f32 = 0,
    rain_from: i64 = 0,

    pub fn hourOfDay(ts: i64, tz: i32) u8 {
        const local = @divFloor(ts + tz, 3600);
        return @intCast(@mod(local, 24));
    }

    /// "07:12" in the location's own timezone.
    pub fn clock(ts: i64, tz: i32) [5]u8 {
        const local = ts + tz;
        const secs: i64 = @mod(local, 86400);
        const h: u8 = @intCast(@divFloor(secs, 3600));
        const m: u8 = @intCast(@divFloor(@mod(secs, 3600), 60));
        return .{ '0' + h / 10, '0' + h % 10, ':', '0' + m / 10, '0' + m % 10 };
    }

    fn split12(ts: i64, tz: i32) struct { h: u8, m: u8, suffix: []const u8 } {
        const local = ts + tz;
        const secs: i64 = @mod(local, 86400);
        const h24: u8 = @intCast(@divFloor(secs, 3600));
        const minute: u8 = @intCast(@divFloor(@mod(secs, 3600), 60));
        const h12: u8 = if (h24 % 12 == 0) 12 else h24 % 12;
        return .{ .h = h12, .m = minute, .suffix = if (h24 < 12) "AM" else "PM" };
    }

    /// "5:57 AM"
    pub fn clock12(ts: i64, tz: i32, buf: []u8) []const u8 {
        const t = split12(ts, tz);
        return std.fmt.bufPrint(buf, "{d}:{d:0>2} {s}", .{ t.h, t.m, t.suffix }) catch "--";
    }

    /// "2PM", for the axis.
    pub fn hour12(ts: i64, tz: i32, buf: []u8) []const u8 {
        const t = split12(ts, tz);
        return std.fmt.bufPrint(buf, "{d}{s}", .{ t.h, t.suffix }) catch "--";
    }
};

// ---------------------------------------------------------------------------
// One Call 3.0
// ---------------------------------------------------------------------------

const JsonWeather = struct { id: ?i32 = null };

const JsonHourly = struct {
    dt: i64 = 0,
    temp: f32 = 0,
    pop: ?f32 = null,
    rain: ?struct { @"1h": ?f32 = null } = null,
    snow: ?struct { @"1h": ?f32 = null } = null,
    weather: ?[]JsonWeather = null,
};

const JsonCurrent = struct {
    temp: f32 = 0,
    feels_like: f32 = 0,
    humidity: f32 = 0,
    weather: ?[]JsonWeather = null,
};

const JsonDaily = struct {
    temp: ?struct { min: f32 = 0, max: f32 = 0 } = null,
    sunrise: i64 = 0,
    sunset: i64 = 0,
};

const JsonRoot = struct {
    timezone_offset: i32 = 0,
    current: ?JsonCurrent = null,
    hourly: ?[]JsonHourly = null,
    daily: ?[]JsonDaily = null,
};

/// Parses a One Call payload. `hour_count` points are kept, starting at the
/// hour containing `now_ts`.
pub fn fromOneCall(
    gpa: std.mem.Allocator,
    body: []const u8,
    now_ts: i64,
    hour_count: usize,
) !Forecast {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std.json.parseFromSlice(JsonRoot, arena, body, .{
        .ignore_unknown_fields = true,
    });

    const root = parsed.value;
    var f = Forecast{
        .tz_offset = root.timezone_offset,
        .now_ts = now_ts,
    };

    if (root.current) |cur| {
        f.current_temp = cur.temp;
        f.feels_like = cur.feels_like;
        f.humidity = @intFromFloat(cur.humidity);
        if (cur.weather) |w| {
            if (w.len > 0) f.cond = Condition.fromId(w[0].id orelse 0);
        }
    }

    if (root.daily) |days| {
        if (days.len > 0) {
            if (days[0].temp) |t| {
                f.hi = t.max;
                f.lo = t.min;
            }
            f.sunrise = days[0].sunrise;
            f.sunset = days[0].sunset;
        }
    }

    const hourly = root.hourly orelse return error.NoHourlyData;
    const want_start = @divFloor(now_ts, 3600) * 3600;
    var start: usize = 0;
    while (start < hourly.len and hourly[start].dt < want_start) : (start += 1) {}
    if (start >= hourly.len) start = 0;

    const count = @min(hour_count, max_hours);
    var i: usize = start;
    while (i < hourly.len and f.n < count) : (i += 1) {
        const h = hourly[i];
        var mm: f32 = 0;
        if (h.rain) |r| mm += r.@"1h" orelse 0;
        if (h.snow) |s| mm += s.@"1h" orelse 0;
        var cond: Condition = .unknown;
        if (h.weather) |w| {
            if (w.len > 0) cond = Condition.fromId(w[0].id orelse 0);
        }
        f.hours[f.n] = .{
            .ts = h.dt,
            .temp = h.temp,
            .pop = h.pop orelse 0,
            .mm = mm,
            .cond = cond,
        };
        f.n += 1;
    }
    if (f.n == 0) return error.NoHourlyData;

    summarize(&f);
    return f;
}

fn summarize(f: *Forecast) void {
    var total: f32 = 0;
    var from: i64 = 0;
    for (f.hours[0..f.n]) |h| {
        total += h.mm;
        if (h.mm > 0 and from == 0) from = h.ts;
    }
    f.rain_total = total;
    f.rain_from = from;
}

// ---------------------------------------------------------------------------
// Five day / three hour forecast (free tier)
// ---------------------------------------------------------------------------

const J3Weather = struct { id: ?i32 = null };

const J3Item = struct {
    dt: i64 = 0,
    main: ?struct {
        temp: f32 = 0,
        feels_like: f32 = 0,
        humidity: f32 = 0,
    } = null,
    weather: ?[]J3Weather = null,
    pop: ?f32 = null,
    rain: ?struct { @"3h": ?f32 = null } = null,
    snow: ?struct { @"3h": ?f32 = null } = null,
};

const J3Root = struct {
    city: ?struct {
        timezone: ?i32 = null,
        sunrise: ?i64 = null,
        sunset: ?i64 = null,
    } = null,
    list: ?[]J3Item = null,
};

/// Maps `/data/2.5/forecast` onto the same model. Its points are 3 hours
/// apart, so the chart covers 3x the configured hours.
pub fn fromThreeHourly(
    gpa: std.mem.Allocator,
    body: []const u8,
    now_ts: i64,
    hour_count: usize,
) !Forecast {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std.json.parseFromSlice(J3Root, arena, body, .{
        .ignore_unknown_fields = true,
    });

    const root = parsed.value;
    var f = Forecast{
        .tz_offset = if (root.city) |city| city.timezone orelse 0 else 0,
        .now_ts = now_ts,
    };
    if (root.city) |city| {
        f.sunrise = city.sunrise orelse 0;
        f.sunset = city.sunset orelse 0;
    }

    const list = root.list orelse return error.NoHourlyData;
    const want_start = @divFloor(now_ts, 10800) * 10800;
    var start: usize = 0;
    while (start < list.len and list[start].dt < want_start) : (start += 1) {}
    if (start >= list.len) start = 0;

    const count = @min(hour_count, max_hours);
    var i: usize = start;
    while (i < list.len and f.n < count) : (i += 1) {
        const item = list[i];
        var mm: f32 = 0;
        if (item.rain) |rain| mm += rain.@"3h" orelse 0;
        if (item.snow) |snow| mm += snow.@"3h" orelse 0;
        var cond: Condition = .unknown;
        if (item.weather) |w| {
            if (w.len > 0) cond = Condition.fromId(w[0].id orelse 0);
        }
        const temp = if (item.main) |m| m.temp else 0;
        f.hours[f.n] = .{
            .ts = item.dt,
            .temp = temp,
            .pop = item.pop orelse 0,
            .mm = mm,
            .cond = cond,
        };
        f.n += 1;
    }
    if (f.n == 0) return error.NoHourlyData;

    const first = f.hours[0];
    f.current_temp = first.temp;
    f.cond = first.cond;
    if (list[start].main) |m| {
        f.feels_like = m.feels_like;
        f.humidity = @intFromFloat(m.humidity);
    }

    var hi = f.hours[0].temp;
    var lo = hi;
    for (f.hours[0..f.n]) |h| {
        hi = @max(hi, h.temp);
        lo = @min(lo, h.temp);
    }
    f.hi = hi;
    f.lo = lo;

    summarize(&f);
    return f;
}

// ---------------------------------------------------------------------------
// Mock day: 14° rising to 17° at 17:00, rain 19:00-23:00 peaking at 1.8 mm/h.
// ---------------------------------------------------------------------------

const mock_temp = [_]f32{ 14.0, 15.5, 16.8, 17.2, 16.5, 15.0, 13.6, 12.4, 11.5, 10.8, 10.2, 9.6 };
const mock_mm = [_]f32{ 0, 0, 0, 0, 0.2, 0.6, 1.1, 1.8, 0.9, 0.3, 0.1, 0 };
const mock_pop = [_]f32{ 0, 0, 0, 0, 0.1, 0.3, 0.55, 0.75, 0.45, 0.2, 0.08, 0 };

pub fn mock(gpa: std.mem.Allocator, tz_offset: i32) !Forecast {
    _ = gpa;
    var f = Forecast{
        .tz_offset = tz_offset,
        .current_temp = mock_temp[0],
        .feels_like = mock_temp[0] - 1.0,
        .humidity = 68,
        .cond = .partly,
        .hi = 17.0,
        .lo = 9.6,
    };

    // Anchor the mock at 14:00 local so the shape matches the approved mockup.
    const base: i64 = 1_800_000_000;
    var ts = @divFloor(base, 3600) * 3600;
    const want: i64 = 14;
    const have: i64 = Forecast.hourOfDay(ts, tz_offset);
    ts += (want - have) * 3600;
    f.now_ts = ts;

    f.sunrise = ts - 7 * 3600 - 1800; // 06:30 local
    f.sunset = ts + 4 * 3600 + 2700; // 18:45 local

    f.n = mock_temp.len;
    for (mock_temp, 0..) |t, i| {
        f.hours[i] = .{
            .ts = ts + @as(i64, @intCast(i)) * 3600,
            .temp = t,
            .pop = mock_pop[i],
            .mm = mock_mm[i],
            .cond = if (mock_mm[i] > 0) .rain else .partly,
        };
    }
    summarize(&f);
    return f;
}
