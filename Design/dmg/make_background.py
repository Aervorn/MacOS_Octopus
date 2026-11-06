"""Fond de la fenêtre du DMG d’Octopus (660 × 400 points, en 1x et 2x).

Mêmes dimensions et même placement que celui de Flux : icône de l'app centrée en (180, 200),
raccourci Applications en (480, 200), flèche entre les deux. Couleurs de l’icône d’Octopus (bleu nuit, cyan).

    python3 Design/dmg/make_background.py
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 660, 400
HERE = Path(__file__).parent
VIOLET = (29, 59, 92)    # bleu nuit (#1D3B5C), nom de variable gardé de Vestora
BLUE = (63, 190, 214)    # cyan de la pieuvre
INK = (15, 27, 45)       # #0F1B2D
FONTS = [
    "/System/Library/Fonts/SFNSRounded.ttf",
    "/System/Library/Fonts/SFNS.ttf",
    "/usr/share/fonts/truetype/google-fonts/Poppins-Bold.ttf",
]


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def glow(size, center, radius, color, alpha):
    layer = Image.new("RGBA", size, color + (0,))
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).ellipse(
        [center[0] - radius, center[1] - radius, center[0] + radius, center[1] + radius], fill=alpha
    )
    layer.putalpha(mask.filter(ImageFilter.GaussianBlur(radius * 0.6)))
    return layer


def render(scale):
    s = scale * 2  # suréchantillonnage, réduit à la fin
    size = (W * s, H * s)
    top, bottom = (247, 251, 253), (234, 244, 249)
    img = Image.new("RGBA", size)
    draw = ImageDraw.Draw(img)
    for y in range(size[1]):
        draw.line([(0, y), (size[0], y)], fill=lerp(top, bottom, y / size[1]) + (255,))

    img.alpha_composite(glow(size, (int(0.06 * size[0]), int(0.96 * size[1])), 220 * s, VIOLET, 46))
    img.alpha_composite(glow(size, (int(0.96 * size[0]), int(0.04 * size[1])), 220 * s, BLUE, 40))

    # Motif discret : bulles qui remontent, en haut à droite
    bubbles = Image.new("RGBA", size, (0, 0, 0, 0))
    bd = ImageDraw.Draw(bubbles)
    for x, y, r in [(560, 118, 14), (592, 86, 9), (612, 124, 6), (578, 52, 6), (622, 64, 11), (548, 78, 4)]:
        bd.ellipse([(x - r) * s, (y - r) * s, (x + r) * s, (y + r) * s], outline=BLUE + (70,), width=2 * s)
    img.alpha_composite(bubbles)

    # Nom en haut
    font = next((ImageFont.truetype(f, 30 * s) for f in FONTS if Path(f).exists()), ImageFont.load_default())
    draw = ImageDraw.Draw(img)
    draw.text((W * s / 2, 58 * s), "Octopus", font=font, fill=INK + (255,), anchor="ms")

    # Flèche de l'app vers Applications : courbe de Bézier quadratique, dégradé bleu → violet
    p0, p1, p2 = (262, 200), (330, 172), (398, 200)
    pts = []
    for k in range(121):
        t = k / 120
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1]
        pts.append((x * s, y * s, t))
    r = 3 * s
    for x, y, t in pts:
        draw.ellipse([x - r, y - r, x + r, y + r], fill=lerp(BLUE, VIOLET, t) + (255,))
    for a, b in [((385.8, 184.2), (398, 200)), ((398, 200), (378.2, 202.7))]:
        n = 40
        for k in range(n + 1):
            t = k / n
            x = (a[0] + (b[0] - a[0]) * t) * s
            y = (a[1] + (b[1] - a[1]) * t) * s
            draw.ellipse([x - r, y - r, x + r, y + r], fill=VIOLET + (255,))

    final = img.resize((W * scale, H * scale), Image.LANCZOS).convert("RGB")
    name = "background.png" if scale == 1 else f"background@{scale}x.png"
    final.save(HERE / name, dpi=(72 * scale, 72 * scale))


if __name__ == "__main__":
    render(1)
    render(2)
