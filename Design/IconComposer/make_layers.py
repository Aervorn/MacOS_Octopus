"""Calques de l'icône d'Octopus pour Icon Composer (macOS 26).

La pieuvre est `octopus-silhouette.svg` : une silhouette noire vectorisée, sur le canevas
de 1024 × 1024. Ce script lui applique les couleurs de l'icône, écrit les calques ici,
copie dans Octopus/AppIcon.icon/Assets ceux qu'utilise l'icône, écrit Octopus/AppIcon.icon/icon.json
et assemble Design/Octopus-icon.svg (icône complète, pour le README).

    python3 Design/IconComposer/make_layers.py

Pour changer de teinte, modifier les quatre couleurs ci-dessous et relancer le script.
"""
import json
import re
import shutil
from pathlib import Path

HERE = Path(__file__).parent
ICON = HERE.parent.parent / "Octopus" / "AppIcon.icon"
HEAD = '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'

# Teinte « bleu nuit ». Graphite : #101828 → #2A3550 et #FFFFFF → #9AA8C4.
# Sarcelle : #0B2530 → #0F4C5C et #E8FFF9 → #3FD1B5.
SEA_TOP, SEA_BOTTOM = "#0F1B2D", "#1D3B5C"      # fond
BODY_TOP, BODY_BOTTOM = "#F2FBFF", "#7FD8E6"    # pieuvre

SILHOUETTE = re.search(r' d="([^"]+)"', (HERE / "octopus-silhouette.svg").read_text()).group(1)

LAYERS = {
    # Fond : référence seulement (dans l'icône, c'est le dégradé de fond d'Icon Composer)
    "1-fond.svg": HEAD + f"""  <defs>
    <linearGradient id="sea" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{SEA_TOP}"/><stop offset="1" stop-color="{SEA_BOTTOM}"/>
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" fill="url(#sea)"/>
</svg>
""",
    "2-pieuvre.svg": HEAD + f"""  <defs>
    <linearGradient id="body" gradientUnits="userSpaceOnUse" x1="0" y1="110" x2="0" y2="910">
      <stop offset="0" stop-color="{BODY_TOP}"/><stop offset="1" stop-color="{BODY_BOTTOM}"/>
    </linearGradient>
  </defs>
  <path d="{SILHOUETTE}" fill="url(#body)" fill-rule="evenodd"/>
</svg>
""",
}


def hex_to_p3(hex_color):
    """Couleur hexadécimale en « display-p3:r,g,b,a » (approximation sRGB)."""
    h = hex_color.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return f"display-p3:{r:.5f},{g:.5f},{b:.5f},1.00000"


ICON_JSON = {
    "fill": {"linear-gradient": [hex_to_p3(SEA_TOP), hex_to_p3(SEA_BOTTOM)]},
    "groups": [
        {
            "layers": [{"image-name": "2-pieuvre.svg", "name": "2-pieuvre"}],
            "name": "Pieuvre",
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": True, "value": 0.2},
        },
    ],
    "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
}


def composite():
    """Icône complète en un seul SVG (README) : calques superposés, coins arrondis comme sur macOS."""
    def inner(svg):
        return svg.split("\n", 1)[1].rsplit("</svg>", 1)[0]

    body = "".join(inner(LAYERS[name]) for name in sorted(LAYERS))
    return (HEAD + '  <defs><clipPath id="squircle"><rect width="1024" height="1024" rx="229"/></clipPath></defs>\n'
            + '  <g clip-path="url(#squircle)">\n' + body + "  </g>\n</svg>\n")


if __name__ == "__main__":
    assets = ICON / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    for name, svg in LAYERS.items():
        (HERE / name).write_text(svg, encoding="utf-8")
        if name != "1-fond.svg":
            shutil.copy(HERE / name, assets / name)
    (ICON / "icon.json").write_text(json.dumps(ICON_JSON, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (HERE.parent / "Octopus-icon.svg").write_text(composite(), encoding="utf-8")
    print("Calques écrits dans", HERE)
    print("Icône :", ICON)
