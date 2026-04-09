#!/usr/bin/env python3
"""Generate DMG background image — light theme with arrow and labels. Pure stdlib."""

import struct, zlib, math, sys

WIDTH = 660
HEIGHT = 480

# Light palette
BG_TOP = (245, 244, 250)        # very light lavender
BG_BOT = (232, 230, 240)        # slightly darker at bottom
ARROW = (180, 140, 120)         # warm muted (Claude terracotta echo)
ARROW_HEAD = (210, 130, 100)    # slightly more vivid
GUIDE = (210, 208, 218)         # subtle guide line
ACCENT = (217, 119, 87)         # Claude orange for small accents
TEXT_HINT = (140, 135, 155)     # muted text color


def lerp_c(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def blend(bg, fg, alpha):
    a = alpha / 255
    return tuple(int(b * (1 - a) + f * a) for b, f in zip(bg, fg))

def dist_to_segment(px, py, x1, y1, x2, y2):
    dx, dy = x2 - x1, y2 - y1
    if dx == 0 and dy == 0:
        return math.hypot(px - x1, py - y1)
    t = max(0, min(1, ((px - x1) * dx + (py - y1) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (x1 + t * dx), py - (y1 + t * dy))

def point_in_triangle(px, py, x1, y1, x2, y2, x3, y3):
    denom = (y2 - y3) * (x1 - x3) + (x3 - x2) * (y1 - y3)
    if abs(denom) < 0.001:
        return 0
    a = ((y2 - y3) * (px - x3) + (x3 - x2) * (py - y3)) / denom
    b = ((y3 - y1) * (px - x3) + (x1 - x3) * (py - y3)) / denom
    c = 1 - a - b
    if a >= 0 and b >= 0 and c >= 0:
        return 255
    margin = min(a, b, c)
    if margin > -0.03:
        return int(255 * max(0, (margin + 0.03) / 0.03))
    return 0


# Build pixel function
def get_pixel(x, y):
    # Vertical gradient background
    t = y / HEIGHT
    r, g, b = lerp_c(BG_TOP, BG_BOT, t)

    # Subtle horizontal divider between row 1 and row 2
    div_y = 310
    div_dist = abs(y - div_y)
    if div_dist < 1.0 and 60 < x < WIDTH - 60:
        da = int(50 * (1 - div_dist / 1.0))
        r, g, b = blend((r, g, b), GUIDE, da)

    # Arrow: line from app area to Applications area (row 1, y ~190)
    arrow_y = 195
    arrow_x1 = 215
    arrow_x2 = 430

    # Arrow shaft
    shaft_dist = dist_to_segment(x, y, arrow_x1, arrow_y, arrow_x2, arrow_y)
    if shaft_dist < 3.0:
        sa = int(160 * (1 - shaft_dist / 3.0)) if shaft_dist > 1.5 else 160
        r, g, b = blend((r, g, b), ARROW, sa)

    # Arrowhead
    head_size = 16
    tri_alpha = point_in_triangle(x, y,
        arrow_x2 + head_size, arrow_y,
        arrow_x2 - 2, arrow_y - head_size * 0.65,
        arrow_x2 - 2, arrow_y + head_size * 0.65)
    if tri_alpha > 0:
        r, g, b = blend((r, g, b), ARROW_HEAD, int(tri_alpha * 0.7))

    # Small accent dots along the arrow (dashed feel)
    if abs(y - arrow_y) < 1.5 and arrow_x1 < x < arrow_x2:
        seg = int((x - arrow_x1) / 8)
        if seg % 3 == 0:
            dot_a = int(40 * (1 - abs(y - arrow_y) / 1.5))
            r, g, b = blend((r, g, b), ACCENT, dot_a)

    return (r, g, b)


def create_png(width, height, get_pixel_fn):
    raw_rows = []
    for y in range(height):
        row = bytearray()
        row.append(0)
        for x in range(width):
            cr, cg, cb = get_pixel_fn(x, y)
            row.extend([cr, cg, cb, 255])
        raw_rows.append(bytes(row))

    raw = b''.join(raw_rows)
    compressed = zlib.compress(raw, 9)

    def chunk(ctype, data):
        c = ctype + data
        crc = zlib.crc32(c) & 0xffffffff
        return struct.pack('>I', len(data)) + c + struct.pack('>I', crc)

    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', compressed)
    png += chunk(b'IEND', b'')
    return png


out_path = sys.argv[1] if len(sys.argv) > 1 else 'dmg-background.png'
data = create_png(WIDTH, HEIGHT, get_pixel)
with open(out_path, 'wb') as f:
    f.write(data)
print(f"Background image written to {out_path} ({len(data)} bytes)")
