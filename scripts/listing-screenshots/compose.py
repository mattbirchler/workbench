#!/usr/bin/env python3
"""App Store screenshots and creative assets for the Workbench iPhone app.

The look is "Status lights": the app's dark canvas lit by the color of the
state on screen (amber for needs you, orange for working, mint for done), a
small tracked eyebrow in SF Mono with the app's checklist segments on the
right, a big uppercase headline in condensed SF Pro, and the device upright
and bleeding off the bottom. It follows the Quick Reviews listing ("House
lights") in Workbench's own colors and type.

Captures come from the demo mode in the simulator (see capture.sh), so
nothing here shows a real project. Captions are placeholders. Run from
anywhere:

    scripts/listing-screenshots/capture.sh
    python3 scripts/listing-screenshots/compose.py

Writes fastlane/screenshots/en-US (6.9", 6.3", iPhone Duo and iPad 13" sets)
and fastlane/creative-assets (search results image and product page header).
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, os.path.expanduser("~/.claude/skills/app-store-assets/scripts"))
import storefront_kit as kit  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
RAW = os.path.join(ROOT, "fastlane/screenshots/raw")
OUT = os.path.join(ROOT, "fastlane/screenshots/en-US")
CREATIVE = os.path.join(ROOT, "fastlane/creative-assets")
CACHE = os.path.join(ROOT, "build/listing")

# The phone's dark canvas, its ink, and the three status colors.
GROUND = (13, 14, 17)
WHITE = (255, 255, 255)
SECOND = (190, 194, 204)
RULE = (58, 61, 70)
WAITING = (240, 178, 52)
WORKING = (222, 122, 88)
DONE = (96, 222, 164)

SF = "/Library/Fonts/SF-Pro.ttf"
MONO = "/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts/SF-Mono-Semibold.otf"


def sf(size, weight=760, width=62):
    """SF Pro at a weight and width: condensed and bold for headlines."""
    f = ImageFont.truetype(SF, size)
    f.set_variation_by_axes([width, 28, weight])
    return f


def shot(name, prefix="iphone"):
    return os.path.join(RAW, f"{prefix}-{name}.png")


def glow(img, colour, centre=(0.5, 0.4), reach=1.2, strength=0.62):
    """Light in a status color, brightest behind the top of the device and
    gone by the edges."""
    W, H = img.size
    m = Image.new("L", (96, 96), 0)
    px = m.load()
    cx, cy = centre[0] * 96, centre[1] * 96
    r = reach * 96 * 0.75
    for y in range(96):
        for x in range(96):
            dist = (((x - cx) * W / H) ** 2 + (y - cy) ** 2) ** 0.5 / r
            px[x, y] = int(255 * strength * max(0.0, 1 - dist) ** 1.7)
    mask = m.resize((W, H), Image.BICUBIC).filter(ImageFilter.GaussianBlur(W // 30))
    img.paste(Image.new("RGB", (W, H), colour), (0, 0), mask)


def fade(img, top, bottom, a0, a1):
    """Ground-colored gradient between two heights (fractions)."""
    W, H = img.size
    g = Image.new("L", (1, H), 0)
    y0, y1 = int(top * H), int(bottom * H)
    for y in range(H):
        t = min(1, max(0, (y - y0) / max(1, y1 - y0)))
        g.putpixel((0, y), int(a0 + (a1 - a0) * t))
    img.paste(Image.new("RGB", (W, H), GROUND), (0, 0), g.resize((W, H)))


def tracked(d, xy, text, f, fill, tracking):
    x, y = xy
    for ch in text:
        d.text((x, y), ch, font=f, fill=fill)
        x += d.textlength(ch, font=f) + tracking
    return x - tracking


def segments(d, x, y, w, h, colour, filled, total=5):
    """The app's checklist progress: one segment per step."""
    for i in range(total):
        c = colour if i < filled else tuple(int(v * 0.3) for v in colour)
        d.rounded_rectangle([x, y, x + w, y + h], radius=h / 2, fill=c)
        x += w + round(h * 0.8)


def eyebrow(img, text, x, y, right, size, colour, filled, rule=True):
    d = ImageDraw.Draw(img)
    f = kit.font(MONO, size)
    end = tracked(d, (x, y), text.upper(), f, SECOND, size * 0.14)
    if rule:
        w, h = round(size * 1.0), round(size * 0.28)
        total = 5 * w + 4 * round(h * 0.8)
        ty = y + round(size * 0.62)
        d.line([(end + size * 0.7, ty), (right - total - size * 0.7, ty)], fill=RULE, width=max(2, size // 16))
        segments(d, right - total, ty - h // 2, w, h, colour, filled)


def headline(img, lines, x, y, max_w, size, leading=0.98):
    d = ImageDraw.Draw(img)
    while size > 60 and max(d.textlength(line, font=sf(size)) for line in lines) > max_w:
        size -= 4
    f = sf(size)
    for line in lines:
        d.text((x - round(size * 0.02), y), line, font=f, fill=WHITE)
        y += round(size * leading)
    return y + round(size * 0.2)


def sub(img, lines, x, y, size, fill=SECOND):
    d = ImageDraw.Draw(img)
    f = sf(size, weight=500, width=78)
    for line in lines:
        d.text((x, y), line, font=f, fill=fill)
        y += round(size * 1.24)
    return y


def header(img, spec, margin, top, size, sub_size, eyebrow_size):
    """Glow, eyebrow, headline and sub line. Returns the y under the text."""
    glow(img, spec["colour"])
    fade(img, 0.0, 0.3, 200, 0)
    W = img.size[0]
    eyebrow(img, spec["eyebrow"], margin, top, W - margin, eyebrow_size, spec["colour"], spec["step"])
    y = headline(img, spec["lines"], margin, top + round(eyebrow_size * 2.1), W - 2 * margin, size)
    return sub(img, spec["sub"], margin, y, sub_size)


# One spec per image, in the order of a session: see it, answer it, watch
# it, review it. `step` fills that many of the eyebrow's segments, so the
# set counts up as you swipe.
STORY = {
    "sessions": dict(shot="list", colour=WAITING, step=1, eyebrow="Claude Code on your Mac",
                     lines=["EVERY SESSION,", "ONE GLANCE."], sub=["What needs you, what's working, what's done."]),
    "allow": dict(shot="permission", colour=WAITING, step=2, eyebrow="Permissions and questions",
                  lines=["ALLOW IT FROM", "ANYWHERE."], sub=["Answer Claude without going back to your desk."]),
    "follow": dict(shot="working", colour=WORKING, step=3, eyebrow="Live checklist",
                   lines=["FOLLOW", "ALONG."], sub=["Every step, as it happens."]),
    "review": dict(shot="changes", colour=DONE, step=4, whole=True, eyebrow="Changes",
                   lines=["REVIEW,", "THEN COMMIT."], sub=["Diffs, commits and pull requests."]),
    "agents": dict(shot="agent", colour=DONE, step=5, eyebrow="Agents and worktrees",
                   lines=["A BRANCH", "PER AGENT."], sub=["Start one, check in, merge the PR."]),
    "widgets": dict(shot="widgets", colour=WORKING, step=5, eyebrow="Widgets",
                    lines=["ALWAYS", "IN VIEW."], sub=["On your Home Screen and Lock Screen."]),
}

IPHONE = ["sessions", "allow", "follow", "review", "agents", "widgets"]
# The iPad keeps the session list beside the chat, so the agent's chat
# stands in for the list, and the widgets preview is phone-sized.
IPAD = ["sessions", "allow", "follow", "review"]
IPAD_SHOT = {"sessions": "agent"}
DUO = ["sessions", "allow", "follow", "review", "agents"]


def one_line(spec):
    """The wider canvases (iPad, Duo) set the headline on one line."""
    return dict(spec, lines=[" ".join(spec["lines"])])


def iphone_slide(key):
    spec = STORY[key]
    img = kit.canvas(kit.IPHONE_69, GROUND)
    y = header(img, spec, margin=92, top=150, size=250, sub_size=64, eyebrow_size=34)
    # `whole` shows the entire phone, for a screen whose point is at the bottom.
    width = 900 if spec.get("whole") else 1110
    kit.device(img, shot(spec["shot"]), kit.IPHONE_17_PRO_MAX, width=width, pos=((kit.IPHONE_69[0] - width) // 2, y + 110),
               colour="Silver")
    return img


def ipad_slide(key):
    spec = one_line(STORY[key])
    img = kit.canvas(kit.IPAD_13, GROUND)
    y = header(img, spec, margin=150, top=170, size=270, sub_size=84, eyebrow_size=42)
    kit.device(img, shot(IPAD_SHOT.get(key, spec["shot"]), "ipad"), kit.IPAD_PRO_13, width=1840,
               pos=(112, y + 130), ipad_corner=True)
    return img


# iPhone Duo. The canvas is the inner display's size (App Store Connect's
# APP_IPHONE_DUO slot); the captures are the outer display, since simctl
# can't open the device. Apple Frames has no Duo bezel, so the frame is a
# plain rounded one.
DUO_SIZE = (2007, 2853)


def duo_frame(path, bezel=44, screen_radius=120):
    scr = Image.open(path).convert("RGBA")
    w, h = scr.size
    mask = Image.new("L", scr.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, h - 1], radius=screen_radius, fill=255)
    scr.putalpha(mask)
    W, H = w + 2 * bezel, h + 2 * bezel
    dev = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(dev)
    d.rounded_rectangle([0, 0, W - 1, H - 1], radius=screen_radius + bezel, fill=(196, 198, 204, 255))
    d.rounded_rectangle([7, 7, W - 8, H - 8], radius=screen_radius + bezel - 7, fill=(12, 12, 14, 255))
    dev.alpha_composite(scr, (bezel, bezel))
    return dev


def duo_slide(key):
    spec = one_line(STORY[key])
    img = kit.canvas(DUO_SIZE, GROUND)
    y = header(img, spec, margin=140, top=170, size=270, sub_size=84, eyebrow_size=42)
    dev = duo_frame(shot(spec["shot"], "duo"))
    width = 1560
    h = round(dev.size[1] * width / dev.size[0])
    kit.place(img, dev.resize((width, h), Image.LANCZOS), ((DUO_SIZE[0] - width) // 2, y + 130), shadow_alpha=120)
    return img


# ------------------------------------------------------------ creative assets

def wall(img, tw, rot=-9, dim=0.42):
    """A tilted wall of the app's own screens, pushed back into the ground."""
    W, H = img.size
    tiles = [Image.open(shot(n)).convert("RGB") for n in ("list", "working", "permission", "agent", "changes")]
    th = round(tw * tiles[0].size[1] / tiles[0].size[0])
    gap = round(tw * 0.08)
    side = int((W * W + H * H) ** 0.5) + tw * 2
    big = Image.new("RGB", (side, side), GROUND)
    m = Image.new("L", (tw, th), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, tw - 1, th - 1], radius=tw // 9, fill=255)
    small = [t.resize((tw, th), Image.LANCZOS) for t in tiles]
    for col, x in enumerate(range(0, side, tw + gap)):
        for row, y in enumerate(range(-(col % 2) * (th // 2), side, th + gap)):
            big.paste(small[(col * 2 + row) % len(small)], (x, y), m)
    big = big.rotate(rot, resample=Image.BICUBIC)
    x0, y0 = (side - W) // 2, (side - H) // 2
    img.paste(Image.blend(big.crop((x0, y0, x0 + W, y0 + H)), Image.new("RGB", (W, H), GROUND), dim), (0, 0))


def side_fade(img, a0=250, a1=30, reach=0.66, power=2.6):
    """Ground-colored gradient from the left, so the headline has a quiet field."""
    W, H = img.size
    g = Image.new("L", (W, 1), 0)
    for x in range(W):
        g.putpixel((x, 0), int(a0 - (a0 - a1) * min(1, (x / (W * reach)) ** power)))
    img.paste(Image.new("RGB", (W, H), GROUND), (0, 0), g.resize((W, H)))


# The permission card on the Website chat, in 1320x2868 capture pixels.
CARD = (22, 1972, 1298, 2512)


def search():
    """Says what the app is: it stands in for the screenshots in search."""
    img = kit.canvas(kit.SEARCH_3x2, GROUND)
    wall(img, tw=520)
    side_fade(img)
    m = 240
    eyebrow(img, "Claude Code on your Mac", m, 660, 1900, 56, WAITING, 5, rule=False)
    y = headline(img, ["YOUR AGENTS,", "IN YOUR POCKET."], m, 800, 1800, 400)
    sub(img, ["See them work. Answer when they ask."], m, y, 112, fill=WHITE)
    kit.device(img, shot("list"), kit.IPHONE_17_PRO_MAX, width=1340, pos=(2280, 360), colour="Silver")
    return img


def page_header():
    """Wordless: the store draws the icon, name and subtitle beside it."""
    img = kit.canvas(kit.HEADER_21x9, GROUND)
    wall(img, tw=440, dim=0.5)
    width = 1700
    kit.chip(img, shot("permission"), CARD, ((kit.HEADER_21x9[0] - width) // 2, 480),
             scale=width / (CARD[2] - CARD[0]), rot=-3, radius=70)
    return img


def main():
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(CACHE, exist_ok=True)
    os.makedirs(CREATIVE, exist_ok=True)
    paths = []
    for i, key in enumerate(IPHONE, 1):
        img = iphone_slide(key)
        p = os.path.join(OUT, f"iphone69_{i:02}-{key}.png")
        kit.save(img, p)
        kit.save(img.convert("RGB").resize((1206, 2622), Image.LANCZOS), os.path.join(OUT, f"iphone63_{i:02}-{key}.png"))
        paths.append(p)
    kit.contact_sheet(paths, os.path.join(CACHE, "contact-sheet.png"), thumb_height=900, columns=6)
    for prefix, keys, slide, sheet in (("ipad13", IPAD, ipad_slide, "contact-sheet-ipad.png"),
                                       ("duo", DUO, duo_slide, "contact-sheet-duo.png")):
        paths = []
        for i, key in enumerate(keys, 1):
            p = os.path.join(OUT, f"{prefix}_{i:02}-{key}.png")
            kit.save(slide(key), p)
            paths.append(p)
        kit.contact_sheet(paths, os.path.join(CACHE, sheet), thumb_height=900, columns=5)
    kit.save(search(), os.path.join(CREATIVE, "search-3x2.png"))
    kit.save(page_header(), os.path.join(CREATIVE, "header-21x9.png"))


if __name__ == "__main__":
    main()
