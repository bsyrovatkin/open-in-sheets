from PIL import Image, ImageDraw
import os, math

OUT = "build/icons"
os.makedirs(OUT, exist_ok=True)
GREEN = (15, 157, 88, 255)
GREEN_D = (11, 128, 71, 255)
WHITE = (255, 255, 255, 255)

def rounded(d, box, r, fill):
    d.rounded_rectangle(box, radius=r, fill=fill)

def app_icon(size):
    S = size * 4  # supersample
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    m = S * 0.08                      # macOS icon margin
    r = (S - 2 * m) * 0.225           # squircle-ish radius
    # base
    rounded(d, [m, m, S - m, S - m], r, GREEN)
    # spreadsheet grid
    gx0, gy0 = S * 0.255, S * 0.235
    gx1, gy1 = S * 0.745, S * 0.700
    lw = max(2, int(S * 0.020))
    d.rounded_rectangle([gx0, gy0, gx1, gy1], radius=S * 0.030, outline=WHITE, width=lw)
    # header fill
    hh = (gy1 - gy0) / 4.0
    d.rounded_rectangle([gx0, gy0, gx1, gy0 + hh], radius=S * 0.030, fill=WHITE)
    d.rectangle([gx0, gy0 + hh * 0.55, gx1, gy0 + hh], fill=WHITE)
    # inner lines
    for i in (2, 3):
        y = gy0 + hh * i
        d.line([gx0, y, gx1, y], fill=WHITE, width=lw)
    for i in (1, 2):
        x = gx0 + (gx1 - gx0) / 3.0 * i
        d.line([x, gy0, x, gy1], fill=WHITE, width=lw)
    # up-right arrow badge (bottom-right)
    cx, cy, rad = S * 0.735, S * 0.735, S * 0.145
    d.ellipse([cx - rad, cy - rad, cx + rad, cy + rad], fill=WHITE)
    a = rad * 0.58
    w = max(2, int(S * 0.030))
    tip = (cx + a * 0.72, cy - a * 0.72)
    d.line([cx - a * 0.72, cy + a * 0.72, tip[0], tip[1]], fill=GREEN, width=w)
    hl = a * 0.85
    d.line([tip[0], tip[1], tip[0] - hl, tip[1]], fill=GREEN, width=w)
    d.line([tip[0], tip[1], tip[0], tip[1] + hl], fill=GREEN, width=w)
    d.ellipse([tip[0]-w/2, tip[1]-w/2, tip[0]+w/2, tip[1]+w/2], fill=GREEN)
    return img.resize((size, size), Image.LANCZOS)

def menubar_icon(scale):
    S = 18 * scale * 8
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    K = (0, 0, 0, 255)
    lw = max(6, int(S * 0.055))
    p = S * 0.10
    x0, y0, x1, y1 = p, p * 1.35, S - p, S - p * 1.35
    d.rounded_rectangle([x0, y0, x1, y1], radius=S * 0.09, outline=K, width=lw)
    hh = (y1 - y0) / 3.4
    d.rectangle([x0, y0, x1, y0 + hh], fill=K)
    d.line([x0, y0 + hh * 2, x1, y0 + hh * 2], fill=K, width=lw)
    xm = x0 + (x1 - x0) * 0.42
    d.line([xm, y0 + hh, xm, y1], fill=K, width=lw)
    return img.resize((18 * scale, 18 * scale), Image.LANCZOS)

# iconset
iconset = "build/AppIcon.iconset"
os.makedirs(iconset, exist_ok=True)
for sz in (16, 32, 128, 256, 512):
    app_icon(sz).save(f"{iconset}/icon_{sz}x{sz}.png")
    app_icon(sz * 2).save(f"{iconset}/icon_{sz}x{sz}@2x.png")
menubar_icon(1).save(f"{OUT}/menubar.png")
menubar_icon(2).save(f"{OUT}/menubar@2x.png")
app_icon(512).save(f"{OUT}/preview.png")
print("icons written")
