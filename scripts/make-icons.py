#!/usr/bin/env python3
"""Draws every Mydroid icon and Chrome Web Store image from one design and writes them into the repo.

    python3 scripts/make-icons.py

Needs Google Chrome (renders the SVG/HTML to PNG) and macOS `sips`. Outputs:
  assets/icon.svg, assets/icon-1024.png         the Mac icon source (build-app.sh makes the .icns from the PNG)
  android/app/src/main/res/...                  adaptive icon foreground and monochrome layers
  extension/icons/icon{16,32,48,128}.png        browser extension icons (128 is also the store icon)
  assets/chrome-store/*                         store icon, five 1280x800 screenshots, 440x280 and 1400x560 promo tiles
The store screenshots use real captures from `node extension/test/e2e.mjs --shots <dir>`, kept in assets/chrome-store/source/.
"""
import os, subprocess, sys, tempfile, shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TOP, BOTTOM, DEEP = "#38bdf8", "#0369a1", "#075985"   # tile gradient and the dark "screen" colour
ANDROID_BG = "#0284C7"

def mark(screens=True):
    """The artwork on a 128 grid: a laptop and a phone side by side. `screens=False` is the chunky small-size version."""
    s = f'''<g transform="translate(64 64) scale(1.1) translate(-64 -64) translate(5 -1)">
  <rect x="10" y="34" width="70" height="46" rx="6" fill="#fff"/>
  <rect x="2" y="84" width="82" height="7" rx="3.5" fill="#fff" opacity=".92"/>
  <rect x="88" y="46" width="28" height="50" rx="7" fill="#fff"/>'''
    if screens:
        s += f'''
  <rect x="15" y="39" width="60" height="36" rx="2.5" fill="{DEEP}"/><circle cx="45" cy="57" r="4.5" fill="#fff"/>
  <rect x="92" y="51" width="20" height="38" rx="3" fill="{DEEP}"/><circle cx="102" cy="70" r="3.2" fill="#fff"/>'''
    return s + "\n</g>"

def tile(size=128, screens=True, rx=28):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" width="{size}" height="{size}">
<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{TOP}"/><stop offset="1" stop-color="{BOTTOM}"/></linearGradient></defs>
<rect width="128" height="128" rx="{rx}" fill="url(#g)"/>
{mark(screens)}
</svg>'''

def mac_master():
    # macOS grid: an 824 tile centred in 1024 with a soft shadow.
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{TOP}"/><stop offset="1" stop-color="{BOTTOM}"/></linearGradient>
<filter id="sh" x="-10%" y="-10%" width="120%" height="125%"><feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity=".3"/></filter></defs>
<g transform="translate(100 100) scale(6.4375)"><rect width="128" height="128" rx="28.8" fill="url(#g)" filter="url(#sh)"/>{mark()}</g>
</svg>'''

def render(html_or_svg, out, w, h, transparent=False):
    ext = ".svg" if html_or_svg.lstrip().startswith("<svg") else ".html"
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "page" + ext)
        body = html_or_svg
        if ext == ".svg":
            body = f'<!doctype html><meta charset="utf-8"><style>html,body{{margin:0;background:transparent}}svg{{display:block}}</style>{html_or_svg}'
            src = os.path.join(d, "page.html")
        open(src, "w").write(body)
        cmd = [CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
               f"--window-size={w},{h}", f"--screenshot={out}"]
        if transparent: cmd.append("--default-background-color=00000000")
        subprocess.run(cmd + ["file://" + src], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def to_jpeg(png, jpg):
    subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "95", png, "--out", jpg], check=True, stdout=subprocess.DEVNULL)
    os.remove(png)

def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True); open(path, "w").write(text)

# ---------------------------------------------------------------- Mac
write(f"{ROOT}/assets/icon.svg", tile() + "\n")
render(mac_master(), f"{ROOT}/assets/icon-1024.png", 1024, 1024, transparent=True)

# ---------------------------------------------------------------- Android (108 viewport, safe zone is the middle 66)
def rr(x, y, w, h, r):
    return (f"M{x+r:g},{y:g}H{x+w-r:g}A{r:g},{r:g} 0 0 1 {x+w:g},{y+r:g}V{y+h-r:g}A{r:g},{r:g} 0 0 1 {x+w-r:g},{y+h:g}"
            f"H{x+r:g}A{r:g},{r:g} 0 0 1 {x:g},{y+h-r:g}V{y+r:g}A{r:g},{r:g} 0 0 1 {x+r:g},{y:g}Z")
def circle(cx, cy, r):
    return f"M{cx-r:g},{cy:g}a{r:g},{r:g} 0 1 1 {2*r:g},0a{r:g},{r:g} 0 1 1 {-2*r:g},0Z"
K = 0.54                                  # 128-grid -> 108 viewport
OX, OY = 54 - 59 * K, 54 - 65 * K          # centre the artwork (its centre is 59,65 on the 128 grid)
def a(x, y, w, h, r): return rr(OX + x * K, OY + y * K, w * K, h * K, r * K)
def dot(cx, cy, r): return circle(OX + cx * K, OY + cy * K, r * K)
shapes = " ".join([
    a(10, 34, 70, 46, 6), a(15, 39, 60, 36, 2.5), dot(45, 57, 4.5),          # laptop with a screen hole and a dot
    a(2, 84, 82, 7, 3.5),                                                    # base
    a(88, 46, 28, 50, 7), a(92, 51, 20, 38, 3), dot(102, 70, 3.2),           # phone
])
# 128-grid x offset: the mark is drawn with translate(5,-1); the Android layer centres it by its own box instead.
def vector(color):
    return f'''<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp" android:viewportWidth="108" android:viewportHeight="108">
    <path android:fillColor="{color}" android:fillType="evenOdd"
        android:pathData="{shapes}" />
</vector>
'''
res = f"{ROOT}/android/app/src/main/res"
write(f"{res}/drawable/ic_launcher_foreground.xml", vector("#FFFFFF"))
write(f"{res}/drawable/ic_launcher_mono.xml", vector("#000000"))
write(f"{res}/values/colors.xml", f'<resources>\n    <color name="ic_background">{ANDROID_BG}</color>\n</resources>\n')

# ---------------------------------------------------------------- Extension icons
icons = f"{ROOT}/extension/icons"
render(tile(16, screens=False, rx=24), f"{icons}/icon16.png", 16, 16, transparent=True)
render(tile(32, screens=False, rx=26), f"{icons}/icon32.png", 32, 32, transparent=True)
render(tile(48), f"{icons}/icon48.png", 48, 48, transparent=True)
# 128 px with the artwork at 96 and 16 px of transparent margin, as the store guidelines ask.
render(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" width="128" height="128"><g transform="translate(16 16) scale(.75)">{tile(128)[tile(128).index("<defs>"):-6]}</g></svg>',
       f"{icons}/icon128.png", 128, 128, transparent=True)

# ---------------------------------------------------------------- Chrome Web Store
store = f"{ROOT}/assets/chrome-store"
shutil.copy(f"{icons}/icon128.png", f"{store}/store-icon-128.png")

FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Helvetica Neue', Arial, sans-serif"
def shot_page(title, sub, img, crop, scale):
    x, y, w, h = crop
    return f'''<!doctype html><meta charset="utf-8"><style>
html,body{{margin:0;width:1280px;height:800px;font-family:{FONT};overflow:hidden}}
body{{background:linear-gradient(160deg,#e6f4fc 0%,#c4e5f6 100%);display:flex;flex-direction:column;align-items:center}}
h1{{margin:64px 0 0;font-size:54px;letter-spacing:-1.2px;color:#0c4a6e;font-weight:700}}
p{{margin:14px 0 0;font-size:26px;color:#0b5f94}}
.card{{margin-top:44px;width:{w*scale:g}px;height:{h*scale:g}px;border-radius:18px;overflow:hidden;
box-shadow:0 30px 70px rgba(7,89,133,.28),0 0 0 1px rgba(7,89,133,.10);background:url("file://{ROOT}/assets/chrome-store/source/{img}.png") -{x*scale:g}px -{y*scale:g}px/{1350*scale:g}px auto no-repeat}}
</style><h1>{title}</h1><p>{sub}</p><div class="card"></div>'''

shots = [
    ("Fill 2FA codes from your phone", "A small chip appears right on the code field.", "idle-single", (300, 40, 760, 380), 1.25),
    ("Approve on your phone", "Every fill waits for your OK on the phone.", "working", (300, 40, 760, 380), 1.25),
    ("The code goes in for you", "Nothing to read, nothing to type.", "filled", (300, 40, 760, 380), 1.25),
    ("Works with split code boxes", "Each digit lands in its own box.", "idle-split", (300, 40, 760, 380), 1.25),
    ("Spots lookalike sites", "Warns you before linking paypa1.com.", "picker-lookalike", (300, 40, 760, 660), 0.72),
]
for i, (t, s, img, crop, sc) in enumerate(shots, 1):
    out = f"{store}/screenshot-{i}.png"
    render(shot_page(t, s, img, crop, sc), out, 1280, 800)
    to_jpeg(out, f"{store}/screenshot-{i}.jpg")

def promo(w, h, big, small_tile, with_card):
    icon = tile(small_tile)
    card = f'<div class="card"></div>' if with_card else ""
    return f'''<!doctype html><meta charset="utf-8"><style>
html,body{{margin:0;width:{w}px;height:{h}px;font-family:{FONT};overflow:hidden}}
body{{background:linear-gradient(135deg,#0ea5e9 0%,#0369a1 100%);color:#fff;display:flex;align-items:center;justify-content:{"flex-start" if with_card else "center"};gap:{int(h*.08)}px;padding:0 {int(w*.07)}px;box-sizing:border-box}}
.t h1{{margin:0;font-size:{big}px;line-height:1.05;letter-spacing:-1px;font-weight:700}}
.t p{{margin:{int(big*.28)}px 0 0;font-size:{int(big*.42)}px;opacity:.92;line-height:1.25}}
.card{{margin-left:auto;flex-shrink:0;width:491px;height:238px;border-radius:18px;overflow:hidden;box-shadow:0 24px 60px rgba(0,0,0,.30);
background:url("file://{ROOT}/assets/chrome-store/source/filled.png") -227px -42px/945px auto no-repeat}}
.i svg{{display:block;filter:drop-shadow(0 8px 18px rgba(0,0,0,.25))}}
</style><div class="i">{icon}</div><div class="t"><h1>Mydroid<br>Authenticator</h1><p>Fill 2FA codes from<br>your Android phone</p></div>{card}'''
render(promo(440, 280, 40, 112, False), f"{store}/promo-small.png", 440, 280); to_jpeg(f"{store}/promo-small.png", f"{store}/promo-small.jpg")
render(promo(1400, 560, 66, 180, True), f"{store}/promo-marquee.png", 1400, 560); to_jpeg(f"{store}/promo-marquee.png", f"{store}/promo-marquee.jpg")
print("done")
