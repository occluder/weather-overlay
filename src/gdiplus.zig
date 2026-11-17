//! Hand-written bindings for the GDI+ flat API (gdiplus.dll).
//!
//! The MinGW headers that ship with Zig only declare this API inside an
//! `#ifdef __cplusplus` block, so `@cImport` in C mode sees nothing. These are
//! the handful of stable, documented exports this app needs.

pub const Status = c_int;
pub const ok: Status = 0;

pub const real = f32;
pub const argb = u32;

pub const GdiplusStartupInput = extern struct {
    GdiplusVersion: u32 = 1,
    DebugEventCallback: ?*const fn (u32, usize, ?*anyopaque) callconv(.c) c_int = null,
    SuppressBackgroundThread: c_int = 0,
    SuppressExternalCodecs: c_int = 0,
};

pub const PointF = extern struct { X: real = 0, Y: real = 0 };
pub const RectF = extern struct { X: real = 0, Y: real = 0, Width: real = 0, Height: real = 0 };
pub const Rect = extern struct { X: c_int = 0, Y: c_int = 0, Width: c_int = 0, Height: c_int = 0 };

pub const Bitmap = opaque {};
pub const Image = opaque {};
pub const Graphics = opaque {};
pub const Path = opaque {};
pub const Brush = opaque {};
pub const SolidFill = opaque {};
pub const LineGradient = opaque {};
pub const Pen = opaque {};
pub const FontFamily = opaque {};
pub const Font = opaque {};
pub const StringFormat = opaque {};
pub const FontCollection = opaque {};

// Pixel formats
pub const pixel_format_32bpp_pargb: c_int = 0x000E200B;
pub const pixel_format_32bpp_argb: c_int = 0x0026200A;

// Quality modes (CompositingQuality / PixelOffsetMode)
pub const quality_default: c_int = 0;
pub const quality_high: c_int = 2;

// SmoothingMode
pub const smoothing_none: c_int = 0;
pub const smoothing_antialias: c_int = 4;

// TextRenderingHint
pub const text_antialias_gridfit: c_int = 3;
pub const text_antialias: c_int = 4;

// FillMode
pub const fill_alternate: c_int = 0;

// Unit
pub const unit_pixel: c_int = 2;

// WrapMode
pub const wrap_tile: c_int = 0;

// StringAlignment
pub const align_near: c_int = 0;
pub const align_center: c_int = 1;
pub const align_far: c_int = 2;

// FontStyle
pub const font_style_regular: c_int = 0;
pub const font_style_bold: c_int = 1;

// LineCap / LineJoin
pub const line_cap_flat: c_int = 0;
pub const line_cap_round: c_int = 2;
pub const line_join_round: c_int = 2;
pub const dash_cap_flat: c_int = 0;

pub fn rgb(r: u8, g: u8, b: u8) argb {
    return 0xFF000000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

pub fn argbA(a: u8, r: u8, g: u8, b: u8) argb {
    return (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

pub extern fn GdiplusStartup(token: *usize, input: *const GdiplusStartupInput, output: ?*anyopaque) Status;
pub extern fn GdiplusShutdown(token: usize) void;

pub extern fn GdipCreateBitmapFromScan0(
    width: c_int,
    height: c_int,
    stride: c_int,
    format: c_int,
    scan0: ?[*]u8,
    bitmap: *?*Bitmap,
) Status;
pub extern fn GdipDisposeImage(image: *Image) Status;
pub extern fn GdipGetImageGraphicsContext(image: *Image, graphics: *?*Graphics) Status;
pub extern fn GdipDeleteGraphics(g: *Graphics) Status;
pub extern fn GdipSetSmoothingMode(g: *Graphics, mode: c_int) Status;
pub extern fn GdipSetTextRenderingHint(g: *Graphics, hint: c_int) Status;
pub extern fn GdipSetPixelOffsetMode(g: *Graphics, mode: c_int) Status;
pub extern fn GdipSetCompositingQuality(g: *Graphics, quality: c_int) Status;
pub extern fn GdipGraphicsClear(g: *Graphics, color: argb) Status;
pub extern fn GdipSetClipRect(g: *Graphics, x: real, y: real, w: real, h: real, combine: c_int) Status;
pub extern fn GdipResetClip(g: *Graphics) Status;

pub extern fn GdipCreatePath(fill_mode: c_int, path: *?*Path) Status;
pub extern fn GdipDeletePath(path: *Path) Status;
pub extern fn GdipAddPathLine(path: *Path, x1: real, y1: real, x2: real, y2: real) Status;
pub extern fn GdipStartPathFigure(path: *Path) Status;
pub extern fn GdipClosePathFigure(path: *Path) Status;
pub extern fn GdipAddPathBezier(
    path: *Path,
    x1: real,
    y1: real,
    x2: real,
    y2: real,
    x3: real,
    y3: real,
    x4: real,
    y4: real,
) Status;
pub extern fn GdipAddPathArc(
    path: *Path,
    x: real,
    y: real,
    w: real,
    h: real,
    start_angle: real,
    sweep_angle: real,
) Status;
pub extern fn GdipFillPath(g: *Graphics, brush: *Brush, path: *Path) Status;
pub extern fn GdipDrawPath(g: *Graphics, pen: *Pen, path: *Path) Status;

pub extern fn GdipCreateSolidFill(color: argb, brush: *?*SolidFill) Status;
pub extern fn GdipDeleteBrush(brush: *Brush) Status;
pub extern fn GdipCreateLineBrush(
    point1: *const PointF,
    point2: *const PointF,
    color1: argb,
    color2: argb,
    wrap_mode: c_int,
    brush: *?*LineGradient,
) Status;

pub extern fn GdipCreatePen1(color: argb, width: real, unit: c_int, pen: *?*Pen) Status;
pub extern fn GdipDeletePen(pen: *Pen) Status;
pub extern fn GdipSetPenLineCap197819(pen: *Pen, start_cap: c_int, end_cap: c_int, dash_cap: c_int) Status;
pub extern fn GdipSetPenLineJoin(pen: *Pen, join: c_int) Status;

pub extern fn GdipFillEllipse(g: *Graphics, brush: *Brush, x: real, y: real, w: real, h: real) Status;
pub extern fn GdipFillRectangle(g: *Graphics, brush: *Brush, x: real, y: real, w: real, h: real) Status;

pub extern fn GdipCreateFontFamilyFromName(
    name: [*:0]const u16,
    collection: ?*FontCollection,
    family: *?*FontFamily,
) Status;
pub extern fn GdipDeleteFontFamily(family: *FontFamily) Status;
pub extern fn GdipCreateFont(
    family: *FontFamily,
    size: real,
    style: c_int,
    unit: c_int,
    font: *?*Font,
) Status;
pub extern fn GdipDeleteFont(font: *Font) Status;
pub extern fn GdipCreateStringFormat(attrs: c_int, lang: u16, format: *?*StringFormat) Status;
pub extern fn GdipDeleteStringFormat(format: *StringFormat) Status;
pub extern fn GdipSetStringFormatAlign(format: *StringFormat, alignment: c_int) Status;
pub extern fn GdipSetStringFormatLineAlign(format: *StringFormat, alignment: c_int) Status;
pub extern fn GdipDrawString(
    g: *Graphics,
    text: [*]const u16,
    length: c_int,
    font: *Font,
    layout: *const RectF,
    format: ?*StringFormat,
    brush: *Brush,
) Status;
pub extern fn GdipMeasureString(
    g: *Graphics,
    text: [*]const u16,
    length: c_int,
    font: *Font,
    layout: *const RectF,
    format: ?*StringFormat,
    bounding: ?*RectF,
    codepoints_fitted: ?*c_int,
    lines_filled: ?*c_int,
) Status;
