//! Bottom band: temperature spline with precipitation bars behind it, drawn
//! into a premultiplied 32bpp buffer for UpdateLayeredWindow.

const std = @import("std");
const P = @import("gdiplus.zig");
const model = @import("model.zig");

// Geometry as fractions of a 1920-wide layout box.
const pad_x_f: f32 = 0.036;
const pad_top_f: f32 = 0.062;
const pad_bottom_f: f32 = 0.028;
const labels_h_f: f32 = 0.023;
const labels_gap_f: f32 = 0.010;
const left_w_f: f32 = 0.132;
const right_w_f: f32 = 0.150;
const gap_f: f32 = 0.028;
const chart_aspect: f32 = 152.0 / 640.0;

const sz_temp_f: f32 = 0.062;
const sz_cond_f: f32 = 0.0155;
const sz_sub_f: f32 = 0.012;
const sz_side_f: f32 = 0.012;
const sz_label_f: f32 = 0.0118;
const sz_tlabel_f: f32 = 0.0102;

const white_full: u32 = P.argbA(255, 255, 255, 255);
const white_90: u32 = P.argbA(230, 255, 255, 255);
const white_82: u32 = P.argbA(210, 255, 255, 255);
const white_58: u32 = P.argbA(150, 255, 255, 255);
const white_52: u32 = P.argbA(133, 255, 255, 255);
const white_50: u32 = P.argbA(128, 255, 255, 255);
const white_74: u32 = P.argbA(189, 255, 255, 255);

pub const Metrics = struct {
    u: f32,
    lw: f32,
    x0: f32,
    band_h: f32,

    pub fn fromWidth(width: i32) Metrics {
        const wf: f32 = @floatFromInt(width);
        const u = @min(wf / 1920.0, 1.35);
        const lw = 1920.0 * u;
        const chart_w = lw * (1.0 - 2.0 * pad_x_f - left_w_f - right_w_f - 2.0 * gap_f);
        const band_h = lw * (pad_top_f + pad_bottom_f + labels_h_f + labels_gap_f) + chart_w * chart_aspect;
        return .{ .u = u, .lw = lw, .x0 = (wf - lw) / 2.0, .band_h = @ceil(band_h) };
    }
};

/// Scrim, composited under the finished chart. GDI+ reads pixels already in a
/// PARGB bitmap as straight alpha, so this runs after drawing rather than
/// pre-filling the buffer.
pub fn applyScrim(pixels: []u8, width: i32, height: i32) void {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const f: f32 = 1.0 - @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(@max(h - 1, 1)));
        const alpha: u8 = @intFromFloat(@round(stopAlpha(f) * 255.0));
        const a: u32 = alpha;
        const sr: u32 = @divFloor(4 * a, 255);
        const sg: u32 = @divFloor(7 * a, 255);
        const sb: u32 = @divFloor(13 * a, 255);
        const row = pixels[y * w * 4 ..][0 .. w * 4];
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const px = row[x * 4 ..][0..4];
            const inv: u32 = 255 - px[3];
            px[0] = @intCast(@min(255, @as(u32, px[0]) + sb * inv / 255));
            px[1] = @intCast(@min(255, @as(u32, px[1]) + sg * inv / 255));
            px[2] = @intCast(@min(255, @as(u32, px[2]) + sr * inv / 255));
            px[3] = @intCast(@min(255, @as(u32, px[3]) + alpha * inv / 255));
        }
    }
}

fn stopAlpha(f: f32) f32 {
    if (f <= 0.40) return 0.92 + (0.80 - 0.92) * (f / 0.40);
    if (f <= 0.74) return 0.80 + (0.36 - 0.80) * ((f - 0.40) / 0.34);
    return 0.36 * (1.0 - @min((f - 0.74) / 0.26, 1.0));
}

const Fonts = struct {
    temp: *P.Font,
    cond: *P.Font,
    sub: *P.Font,
    side: *P.Font,
    side_bold: *P.Font,
    label: *P.Font,
    temp_label: *P.Font,
};

const Painter = struct {
    g: *P.Graphics,
    near: *P.StringFormat,
    center: *P.StringFormat,
    far: *P.StringFormat,

    fn text(self: *Painter, font: *P.Font, s: []const u8, color: u32, x: f32, y: f32, w: f32, h: f32, fmt: *P.StringFormat) void {
        var buf: [512]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&buf, s) catch return;
        var b: ?*P.SolidFill = null;
        if (P.GdipCreateSolidFill(color, &b) != P.ok) return;
        defer _ = P.GdipDeleteBrush(@ptrCast(b));
        const rect = P.RectF{ .X = x, .Y = y, .Width = w, .Height = h };
        _ = P.GdipDrawString(self.g, &buf, @intCast(n), font, &rect, fmt, @ptrCast(b));
    }

    fn measure(self: *Painter, font: *P.Font, s: []const u8) P.RectF {
        var buf: [512]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&buf, s) catch return .{};
        const layout = P.RectF{ .X = 0, .Y = 0, .Width = 6000, .Height = 6000 };
        var out = P.RectF{};
        _ = P.GdipMeasureString(self.g, &buf, @intCast(n), font, &layout, self.near, &out, null, null);
        return out;
    }

    fn fillEllipse(self: *Painter, color: u32, cx: f32, cy: f32, r: f32) void {
        var b: ?*P.SolidFill = null;
        if (P.GdipCreateSolidFill(color, &b) != P.ok) return;
        defer _ = P.GdipDeleteBrush(@ptrCast(b));
        _ = P.GdipFillEllipse(self.g, @ptrCast(b), cx - r, cy - r, r * 2.0, r * 2.0);
    }
};

fn makeFormat(alignment: c_int) ?*P.StringFormat {
    var f: ?*P.StringFormat = null;
    if (P.GdipCreateStringFormat(0x5000, 0, &f) != P.ok) return null;
    _ = P.GdipSetStringFormatAlign(f.?, alignment);
    _ = P.GdipSetStringFormatLineAlign(f.?, P.align_far);
    return f;
}

fn makeFont(family: *P.FontFamily, size: f32, style: c_int) ?*P.Font {
    var f: ?*P.Font = null;
    if (P.GdipCreateFont(family, size, style, P.unit_pixel, &f) != P.ok) return null;
    return f;
}

fn newPath() ?*P.Path {
    var path: ?*P.Path = null;
    if (P.GdipCreatePath(P.fill_alternate, &path) != P.ok) return null;
    return path;
}

fn verticalBrush(y1: f32, y2: f32, c1: u32, c2: u32) ?*P.LineGradient {
    if (@abs(y2 - y1) < 0.5) return null;
    var b: ?*P.LineGradient = null;
    // A one-pixel horizontal offset keeps GDI+ from building a zero-width
    // gradient rectangle, which otherwise degenerates into a solid fill.
    const p1 = P.PointF{ .X = 0, .Y = y1 };
    const p2 = P.PointF{ .X = 1, .Y = y2 };
    if (P.GdipCreateLineBrush(&p1, &p2, c1, c2, P.wrap_tile, &b) != P.ok) return null;
    return b;
}

/// Forces `rgb <= a`. GDI+ leaves straight-alpha values on path and text
/// edges, and UpdateLayeredWindow wants strictly premultiplied ARGB.
fn clampPremul(pixels: []u8) void {
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        const a = pixels[i + 3];
        if (pixels[i + 0] > a) pixels[i + 0] = a;
        if (pixels[i + 1] > a) pixels[i + 1] = a;
        if (pixels[i + 2] > a) pixels[i + 2] = a;
    }
}

pub fn render(pixels: []u8, width: i32, height: i32, f: *const model.Forecast) void {
    @memset(pixels, 0);
    if (f.n != 0) paint(pixels, width, height, f);
    clampPremul(pixels);
    applyScrim(pixels, width, height);
}

fn paint(pixels: []u8, width: i32, height: i32, f: *const model.Forecast) void {
    const m = Metrics.fromWidth(width);

    var bitmap: ?*P.Bitmap = null;
    if (P.GdipCreateBitmapFromScan0(width, height, width * 4, P.pixel_format_32bpp_pargb, pixels.ptr, &bitmap) != P.ok) return;
    defer _ = P.GdipDisposeImage(@ptrCast(bitmap.?));

    var g: ?*P.Graphics = null;
    if (P.GdipGetImageGraphicsContext(@ptrCast(bitmap.?), &g) != P.ok) return;
    defer _ = P.GdipDeleteGraphics(g.?);

    const gr = g.?;
    _ = P.GdipSetSmoothingMode(gr, P.smoothing_antialias);
    _ = P.GdipSetTextRenderingHint(gr, P.text_antialias_gridfit);
    _ = P.GdipSetPixelOffsetMode(gr, P.quality_high);
    _ = P.GdipSetCompositingQuality(gr, P.quality_high);

    var family_opt: ?*P.FontFamily = null;
    if (P.GdipCreateFontFamilyFromName(std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"), null, &family_opt) != P.ok) return;
    const family = family_opt.?;
    defer _ = P.GdipDeleteFontFamily(family);

    var semibold: ?*P.FontFamily = null;
    const have_semibold = P.GdipCreateFontFamilyFromName(
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI Semibold"),
        null,
        &semibold,
    ) == P.ok;
    const bold_family = if (have_semibold) semibold.? else family;
    defer if (have_semibold) {
        _ = P.GdipDeleteFontFamily(semibold.?);
    };

    const near = makeFormat(P.align_near) orelse return;
    const center = makeFormat(P.align_center) orelse return;
    const far = makeFormat(P.align_far) orelse return;
    defer _ = P.GdipDeleteStringFormat(near);
    defer _ = P.GdipDeleteStringFormat(center);
    defer _ = P.GdipDeleteStringFormat(far);

    const lw = m.lw;
    const fonts = Fonts{
        .temp = makeFont(bold_family, lw * sz_temp_f, P.font_style_regular) orelse return,
        .cond = makeFont(family, lw * sz_cond_f, P.font_style_regular) orelse return,
        .sub = makeFont(family, lw * sz_sub_f, P.font_style_regular) orelse return,
        .side = makeFont(family, lw * sz_side_f, P.font_style_regular) orelse return,
        .side_bold = makeFont(bold_family, lw * sz_side_f, P.font_style_regular) orelse return,
        .label = makeFont(family, lw * sz_label_f, P.font_style_regular) orelse return,
        .temp_label = makeFont(family, lw * sz_tlabel_f, P.font_style_regular) orelse return,
    };
    defer {
        _ = P.GdipDeleteFont(fonts.temp);
        _ = P.GdipDeleteFont(fonts.cond);
        _ = P.GdipDeleteFont(fonts.sub);
        _ = P.GdipDeleteFont(fonts.side);
        _ = P.GdipDeleteFont(fonts.side_bold);
        _ = P.GdipDeleteFont(fonts.label);
        _ = P.GdipDeleteFont(fonts.temp_label);
    }

    var p = Painter{ .g = gr, .near = near, .center = center, .far = far };

    const pad_x = lw * pad_x_f;
    const xl = m.x0 + pad_x;
    const xr = m.x0 + lw - pad_x;
    const band_h: f32 = @floatFromInt(height);
    const text_bottom = band_h - lw * pad_bottom_f;
    const labels_h = lw * labels_h_f;
    const labels_top = text_bottom - labels_h;
    const chart_bottom = labels_top - lw * labels_gap_f;
    const chart_x = xl + lw * left_w_f + lw * gap_f;
    const chart_w = lw * (1.0 - 2.0 * pad_x_f - left_w_f - right_w_f - 2.0 * gap_f);
    const chart_top = chart_bottom - chart_w * chart_aspect;

    drawChart(&p, f, &fonts, chart_x, chart_top, chart_w, chart_bottom, labels_top, labels_h, lw, m.x0 + lw);
    drawLeftColumn(&p, f, &fonts, xl, text_bottom, lw);
    drawRightColumn(&p, f, &fonts, xr, text_bottom, lw);
}

fn drawChart(
    p: *Painter,
    f: *const model.Forecast,
    fonts: *const Fonts,
    chart_x: f32,
    chart_top: f32,
    chart_w: f32,
    chart_bottom: f32,
    labels_top: f32,
    labels_h: f32,
    lw: f32,
    layout_right: f32,
) void {
    const n = f.n;
    const plot_h = chart_bottom - chart_top;
    const inset = chart_w * 0.011;
    const plot_w = chart_w - 2.0 * inset;

    var lo = f.hours[0].temp;
    var hi = lo;
    var max_mm: f32 = 0;
    for (f.hours[0..n]) |h| {
        lo = @min(lo, h.temp);
        hi = @max(hi, h.temp);
        max_mm = @max(max_mm, h.mm);
    }
    const rng = @max(hi - lo, 0.1);

    const step: f32 = if (n > 1) plot_w / @as(f32, @floatFromInt(n - 1)) else plot_w;

    var xs: [model.max_hours]f32 = undefined;
    var ys: [model.max_hours]f32 = undefined;
    for (f.hours[0..n], 0..) |h, i| {
        const t = @as(f32, @floatFromInt(i));
        xs[i] = chart_x + inset + step * t;
        const norm = (h.temp - lo) / rng;
        ys[i] = chart_top + (0.10 + (1.0 - norm) * 0.70) * plot_h;
    }

    // Precipitation bars, behind everything else.
    if (max_mm > 0) {
        const bw = @max(2.0, step * 0.44);
        for (f.hours[0..n], 0..) |h, i| {
            if (h.mm <= 0) continue;
            const bh = @max(bw * 0.5, (h.mm / max_mm) * plot_h * 0.50);
            const y0 = chart_bottom - bh;
            const r = @min(bw * 0.5, bh * 0.5);
            const path = newPath() orelse return;
            defer _ = P.GdipDeletePath(path);
            const x0 = xs[i] - bw * 0.5;
            _ = P.GdipAddPathArc(path, x0, y0, bw, r * 2.0, 180.0, 180.0);
            _ = P.GdipAddPathLine(path, x0 + bw, y0 + r, x0 + bw, chart_bottom);
            _ = P.GdipAddPathLine(path, x0 + bw, chart_bottom, x0, chart_bottom);
            _ = P.GdipClosePathFigure(path);
            if (verticalBrush(y0, chart_bottom, P.argbA(217, 143, 192, 255), P.argbA(77, 63, 127, 214))) |b| {
                defer _ = P.GdipDeleteBrush(@ptrCast(b));
                _ = P.GdipFillPath(p.g, @ptrCast(b), path);
            }
        }
    }

    // Temperature area, then the spline itself.
    if (n > 1) {
        var min_y = ys[0];
        for (ys[0..n]) |y| min_y = @min(min_y, y);

        const area = newPath() orelse return;
        defer _ = P.GdipDeletePath(area);
        _ = P.GdipStartPathFigure(area);
        addSpline(area, xs[0..n], ys[0..n]);
        _ = P.GdipAddPathLine(area, xs[n - 1], ys[n - 1], xs[n - 1], chart_bottom);
        _ = P.GdipAddPathLine(area, xs[n - 1], chart_bottom, xs[0], chart_bottom);
        _ = P.GdipClosePathFigure(area);
        if (verticalBrush(min_y, chart_bottom, P.argbA(77, 255, 255, 255), P.argbA(0, 255, 255, 255))) |b| {
            defer _ = P.GdipDeleteBrush(@ptrCast(b));
            _ = P.GdipFillPath(p.g, @ptrCast(b), area);
        }

        const line = newPath() orelse return;
        defer _ = P.GdipDeletePath(line);
        _ = P.GdipStartPathFigure(line);
        addSpline(line, xs[0..n], ys[0..n]);

        const pen_w = @max(1.0, chart_w * 0.00375);
        var pen: ?*P.Pen = null;
        if (P.GdipCreatePen1(white_full, pen_w, P.unit_pixel, &pen) == P.ok) {
            defer _ = P.GdipDeletePen(pen.?);
            _ = P.GdipSetPenLineCap197819(pen.?, P.line_cap_round, P.line_cap_round, P.dash_cap_flat);
            _ = P.GdipSetPenLineJoin(pen.?, P.line_join_round);
            _ = P.GdipDrawPath(p.g, pen.?, line);
        }
    }

    // Hour dots and the "now" marker.
    const dot_r = @max(1.5, chart_w * 0.00344);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i != 0 and i % 2 == 0) p.fillEllipse(P.argbA(235, 255, 255, 255), xs[i], ys[i], dot_r);
    }
    p.fillEllipse(P.argbA(41, 255, 255, 255), xs[0], ys[0], chart_w * 0.0097);
    p.fillEllipse(white_full, xs[0], ys[0], chart_w * 0.0053);

    // The value at every point, sitting just above its dot.
    const tl_h = lw * sz_tlabel_f * 1.34;
    const tl_w = step * 1.7;
    const tl_lift = dot_r + lw * 0.005;
    i = 0;
    while (i < n) : (i += 1) {
        var tb: [12]u8 = undefined;
        const s = std.fmt.bufPrint(&tb, "{d:.0}°", .{f.hours[i].temp}) catch continue;
        p.text(fonts.temp_label, s, white_74, xs[i] - tl_w * 0.5, ys[i] - tl_lift - tl_h, tl_w, tl_h, p.center);
    }

    // Hour labels.
    var buf: [12]u8 = undefined;
    i = 0;
    while (i < n) : (i += 1) {
        if (i % 2 != 0) continue;
        const s = model.Forecast.hour12(f.hours[i].ts, f.tz_offset, &buf);
        const col_w = step * 2.0;
        if (i == 0) {
            p.text(fonts.label, s, white_58, xs[i], labels_top, col_w, labels_h, p.near);
        } else if (i + 1 >= n) {
            p.text(fonts.label, s, white_58, xs[i] - col_w, labels_top, col_w, labels_h, p.far);
        } else {
            p.text(fonts.label, s, white_58, xs[i] - col_w * 0.5, labels_top, col_w, labels_h, p.center);
        }
    }
    _ = layout_right;
}

fn addSpline(path: *P.Path, xs: []const f32, ys: []const f32) void {
    const t: f32 = 1.0 / 6.0;
    var i: usize = 1;
    while (i < xs.len) : (i += 1) {
        const prev_i = if (i >= 2) i - 2 else i - 1;
        const next_i = if (i + 1 < xs.len) i + 1 else i;
        const c1x = xs[i - 1] + (xs[i] - xs[prev_i]) * t;
        const c1y = ys[i - 1] + (ys[i] - ys[prev_i]) * t;
        const c2x = xs[i] - (xs[next_i] - xs[i - 1]) * t;
        const c2y = ys[i] - (ys[next_i] - ys[i - 1]) * t;
        _ = P.GdipAddPathBezier(path, xs[i - 1], ys[i - 1], c1x, c1y, c2x, c2y, xs[i], ys[i]);
    }
}

fn drawLeftColumn(p: *Painter, f: *const model.Forecast, fonts: *const Fonts, xl: f32, bottom: f32, lw: f32) void {
    const sz_temp = lw * sz_temp_f;
    const sz_cond = lw * sz_cond_f;
    const sz_sub = lw * sz_sub_f;

    var buf: [96]u8 = undefined;
    const temp_s = std.fmt.bufPrint(&buf, "{d:.0}°", .{f.current_temp}) catch return;
    const cond_s = f.cond.label();
    var buf3: [128]u8 = undefined;
    const sub_s = std.fmt.bufPrint(&buf3, "feels {d:.0}° · humidity {d}%", .{ f.feels_like, f.humidity }) catch return;

    const lh_sub = sz_sub * 1.45;
    const lh_cond = sz_cond * 1.30;
    const lh_temp = sz_temp * 1.02;
    const wide = lw * 0.30;

    var y = bottom - lh_sub;
    p.text(fonts.sub, sub_s, white_52, xl, y, wide, lh_sub, p.near);
    y -= lh_cond + lw * 0.004;
    p.text(fonts.cond, cond_s, white_90, xl, y, wide, lh_cond, p.near);
    y -= lh_temp + lw * 0.006;
    p.text(fonts.temp, temp_s, white_full, xl, y, wide, lh_temp, p.near);
}

fn drawRightColumn(p: *Painter, f: *const model.Forecast, fonts: *const Fonts, xr: f32, bottom: f32, lw: f32) void {
    const wide = lw * 0.35;
    const line_h = lw * sz_side_f * 1.55;

    // Sunrise / sunset.
    var sun_buf: [64]u8 = undefined;
    var rise_buf: [16]u8 = undefined;
    var set_buf: [16]u8 = undefined;
    const rise = model.Forecast.clock12(f.sunrise, f.tz_offset, &rise_buf);
    const set = model.Forecast.clock12(f.sunset, f.tz_offset, &set_buf);
    const sun_s = std.fmt.bufPrint(&sun_buf, "{s} ↑   {s} ↓", .{ rise, set }) catch return;
    p.text(fonts.side, sun_s, white_50, xr - wide, bottom - line_h, wide, line_h, p.far);

    // Rain summary.
    var rain_buf: [96]u8 = undefined;
    var peak_buf: [12]u8 = undefined;
    const rain_s = if (f.rain_total > 0)
        blk: {
            var peak: f32 = 0;
            var peak_ts: i64 = f.rain_from;
            for (f.hours[0..f.n]) |h| {
                if (h.mm > peak) {
                    peak = h.mm;
                    peak_ts = h.ts;
                }
            }
            const hh = model.Forecast.hour12(peak_ts, f.tz_offset, &peak_buf);
            break :blk std.fmt.bufPrint(&rain_buf, "rain {d:.1} mm/h · {s}", .{ peak, hh }) catch return;
        }
    else
        "no rain ahead";
    p.text(fonts.side, rain_s, white_50, xr - wide, bottom - line_h * 2.0, wide, line_h, p.far);

    // High / low, with the low dimmed like the mockup.
    var hi_buf: [32]u8 = undefined;
    var lo_buf: [32]u8 = undefined;
    const hi_s = std.fmt.bufPrint(&hi_buf, "H {d:.0}°", .{f.hi}) catch return;
    const lo_s = std.fmt.bufPrint(&lo_buf, "L {d:.0}°", .{f.lo}) catch return;
    const lo_w = p.measure(fonts.side, lo_s).Width;
    const hl_y = bottom - line_h * 3.0;
    p.text(fonts.side, lo_s, white_50, xr - wide, hl_y, wide, line_h, p.far);
    p.text(fonts.side_bold, hi_s, white_82, xr - wide - lo_w - lw * 0.008, hl_y, wide, line_h, p.far);
}
