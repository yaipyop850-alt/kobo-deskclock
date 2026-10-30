import sys
from PIL import Image, ImageDraw, ImageFont
src, out, W, H = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
img = Image.new("L", (W, H), 255)
d = ImageDraw.Draw(img)
fonts = {}
def font(size, bold):
    k = (size, bold)
    if k not in fonts:
        path = "/usr/share/fonts/opentype/noto/NotoSansCJK-%s.ttc" % ("Bold" if bold else "Regular")
        fonts[k] = ImageFont.truetype(path, size, index=1)
    return fonts[k]
overflow = []
for line in open(src, encoding="utf-8"):
    p = line.rstrip("\n").split("\t")
    if p[0] == "R":
        x, y, w, h, c = map(int, p[1:6])
        d.rectangle([x, y, x + w - 1, y + h - 1], fill=c)
    elif p[0] == "T":
        x, y, size, bold, c = map(int, p[1:6]); text = p[6]
        d.text((x, y), text, font=font(size, bold == 1), fill=c, anchor="ls")
        bb = d.textbbox((x, y), text, font=font(size, bold == 1), anchor="ls")
        if bb[0] < 0 or bb[1] < 0 or bb[2] > W or bb[3] > H: overflow.append(text)
img.save(out)
print(out, "overflow:", overflow)
