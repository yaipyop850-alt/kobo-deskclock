"""Draw the plugin menu dumped by menu_dump.lua, roughly as KOReader's touch menu shows it
(check/radio mark on the left, separators as lines, sub-menus open as their own page).
usage: python3 menu_draw.py menu.txt out.png"""
import sys
from PIL import Image, ImageDraw, ImageFont
F = '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'
FB = '/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc'
f, fs, fb = ImageFont.truetype(F, 30), ImageFont.truetype(F, 22), ImageFont.truetype(FB, 30)
rows = [l.rstrip('\n').split('\t') for l in open(sys.argv[1], encoding='utf-8') if l.count('\t') >= 6]
rows = [(int(d), p, k, c == '1', e == '1', s == '1', t) for d, p, k, c, e, s, t in rows]
pages = {}  # path -> list of items
for d, p, k, c, e, s, t in rows[1:]:
    pages.setdefault(p, []).append((k, c, e, s, t))
W, RH = 760, 60
def page(path, items):
    h = 90 + len(items) * RH + sum(10 for it in items if it[3]) + 20
    im = Image.new('L', (W, h), 255); d = ImageDraw.Draw(im)
    crumbs = ['도구'] + path.split('/')
    d.text((24, 14), ' › '.join(crumbs[:-1]) + ' ›', font=fs, fill=110)
    d.text((24, 40), crumbs[-1], font=fb, fill=0)
    d.line((0, 86, W, 86), fill=0, width=3)
    y = 92
    for k, c, e, s, t in items:
        col = 0 if e else 150
        if k == 'check':
            d.rectangle((24, y + 17, 50, y + 43), outline=col, width=2)
            if c: d.line((28, y + 30, 36, y + 39), fill=col, width=4); d.line((36, y + 39, 48, y + 19), fill=col, width=4)
        elif k == 'radio':
            d.ellipse((24, y + 17, 50, y + 43), outline=col, width=2)
            if c: d.ellipse((31, y + 24, 43, y + 36), fill=col)
        d.text((66, y + 10), t, font=f, fill=col)
        y += RH
        d.line((20, y, W - 20, y), fill=225 if not s else 0, width=1 if not s else 2)
        if s: y += 10
    d.rectangle((0, 0, W - 1, h - 1), outline=0, width=2)
    return im
root = rows[0][6].split('  [')[0]
order = [root] + [p for p in pages if p != root]
ims = [page(p, pages[p]) for p in order]
cols = 3
colw = [W] * cols
x_of = lambda i: (i % cols) * (W + 30)
heights = {}
for i, im in enumerate(ims):
    r = i // cols; heights[r] = max(heights.get(r, 0), im.height)
H = sum(heights.values()) + 30 * len(heights)
out = Image.new('L', (cols * (W + 30), H), 255)
y = 0
for r in sorted(heights):
    for i, im in enumerate(ims):
        if i // cols == r: out.paste(im, (x_of(i), y))
    y += heights[r] + 30
out.save(sys.argv[2])
