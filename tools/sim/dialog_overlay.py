"""Draw a KOReader-style InfoMessage / ConfirmBox on top of a simulator PNG.
Approximation of KOReader's look (bordered box, (i) icon, buttons) for previews only.
usage: python3 dialog_overlay.py in.png out.png info|confirm "text with \\n" ["ok|cancel"]
"""
import sys
from PIL import Image, ImageDraw, ImageFont
src, out, kind, text = sys.argv[1:5]
buttons = sys.argv[5].split("|") if len(sys.argv) > 5 else []
text = text.replace("\\n", "\n")
img = Image.open(src).convert("L")
W, H = img.size
d = ImageDraw.Draw(img)
reg = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"
fs = int(min(W, H) * 0.034)
font = ImageFont.truetype(reg, fs, index=1)
bfont = ImageFont.truetype(reg, int(fs * 0.95), index=1)
icon = int(fs * 1.9)
pad = int(fs * 0.9)
text_x0 = pad * 2 + icon
max_text = int(W * 0.9) - text_x0 - pad
lines = []
for para in text.split("\n"):
    cur = ""
    for word in para.split(" "):
        cand = (cur + " " + word) if cur else word
        if d.textlength(cand, font=font) <= max_text or not cur:
            cur = cand
        else:
            lines.append(cur); cur = word
    lines.append(cur)
text_w = max(d.textlength(l, font=font) for l in lines)
box_w = int(text_x0 + text_w + pad * 2)
lh = int(fs * 1.45)
text_h = lh * len(lines)
btn_h = int(fs * 2.4) if buttons else 0
box_h = pad * 2 + text_h + btn_h
x0, y0 = (W - box_w) // 2, (H - box_h) // 2
d.rounded_rectangle([x0, y0, x0 + box_w, y0 + box_h], radius=int(fs * 0.4), fill=255, outline=0, width=3)
cy = y0 + pad + (text_h if not buttons else text_h) // 2
d.ellipse([x0 + pad, cy - icon // 2, x0 + pad + icon, cy + icon // 2], outline=0, width=3)
d.text((x0 + pad + icon // 2, cy), "i", font=ImageFont.truetype(reg, int(icon * 0.7), index=1), fill=0, anchor="mm")
for i, ln in enumerate(lines):
    d.text((x0 + text_x0, y0 + pad + i * lh), ln, font=font, fill=0)
if buttons:
    by = y0 + box_h - btn_h
    d.line([x0, by, x0 + box_w, by], fill=0, width=2)
    n = len(buttons)
    bw = box_w // n
    for i, b in enumerate(buttons):
        if i:
            d.line([x0 + i * bw, by, x0 + i * bw, y0 + box_h], fill=0, width=2)
        d.text((x0 + i * bw + bw // 2, by + btn_h // 2), b, font=bfont, fill=0, anchor="mm")
img.save(out)
print(out)
