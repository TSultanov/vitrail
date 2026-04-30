// Deterministic per-app color from a UTF-8 string (class name or app_id).
// For ASCII identifiers (the common case) this produces the same result as the
// original UTF-16 implementation, since the CRC only uses the low 8 bits per element.

const color_offset = 50;

/// Returns a packed 0x00RRGGBB color derived from `text`.
/// `focused` toggles between a lighter and darker shade.
pub fn createColor(text: []const u8, focused: bool) u32 {
    const crc = getCrc16(text);

    const pre_h: u16 = (((crc >> 8) & 0xFF) + color_offset) % 256;
    const pre_s = ((crc << 0) & 0xFF);
    const h: f32 = @as(f32, @floatFromInt(pre_h)) / 255.0;
    const s: f32 = 0.1 + @as(f32, @floatFromInt(pre_s)) / 512.0;
    const l: f32 = if (focused) 0.4 else 0.6;

    const q = if (l < 0.5) l * (1.0 + s) else l + s - l * s;
    const p = 2.0 * l - q;
    const r = hue2rgb(p, q, h + 1.0 / 3.0);
    const g = hue2rgb(p, q, h);
    const b = hue2rgb(p, q, h - 1.0 / 3.0);

    const ri: u32 = @intFromFloat(r * 255);
    const bi: u32 = @intFromFloat(b * 255);
    const gi: u32 = @intFromFloat(g * 255);

    return (ri << 16) | (gi << 8) | bi;
}

fn getCrc16(a: []const u8) u16 {
    const crc16_poly: u16 = 0x8408;

    var data: u16 = undefined;
    var crc: u16 = 0xffff;
    if (a.len == 0)
        return (~crc);

    for (a) |byte| {
        var j: usize = 8;
        data = 0xff & @as(u16, byte);
        while (j > 0) : (j -= 1) {
            if ((crc & 0x0001) ^ (data & 0x0001) != 0) {
                crc = (crc >> 1) ^ crc16_poly;
            } else {
                crc >>= 1;
            }
            data >>= 1;
        }
    }

    crc = ~crc;
    data = crc;
    crc = (crc << 8) | (data >> 8 & 0xff);
    return crc;
}

fn hue2rgb(p: f32, q: f32, ti: f32) f32 {
    var t: f32 = ti;
    if (t < 0.0) t += 1.0;
    if (t > 1.0) t -= 1.0;
    if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
    if (t < 1.0 / 2.0) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    return p;
}
