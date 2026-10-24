#!/usr/bin/env python3
"""Draws the Overpass app icon and renders every size the asset catalog needs.

A concrete road overpass at night, with a satellite arcing over it: the two kinds
of overpass. The artwork is SVG written here, so changing the icon means editing
this file, not an image. Rendering needs rsvg-convert (brew install librsvg).

Variants:
  light   iOS default appearance (dusk sky)
  dark    iOS dark appearance (night sky)
  tinted  iOS tinted appearance (grayscale; the system applies the tint)
  red     night-vision alternate icon (iOS), to match the app's red mode
  mac     the light art inside the macOS rounded square, with margin and shadow

Run from anywhere:  python3 packaging/icon/make-icon.py
"""

import json
import random
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SVG_DIR = Path(__file__).resolve().parent / "svg"
ASSETS = ROOT / "App" / "Assets.xcassets"

PALETTES = {
    "light": dict(
        sky=["#1A4C9C", "#3F80CC", "#F5B47C"], stars=0.45, star="#FFFFFF", ground="#1D2733", road="#2B2F36", dash="#F4D35E",
        parapet="#E6EAEF", deck="#C3CAD3", underside="#7E8896", pier="#A9B2BE", abutment="#8C96A3",
        trail="#9FEFFF", glow="#7FE7FF", satellite="#FFFFFF", panel="#3A7BD5"),
    "dark": dict(
        sky=["#01030A", "#081430", "#1A2C55"], stars=0.95, star="#FFFFFF", ground="#0B0F16", road="#14171C", dash="#9C8A3C",
        parapet="#6D7684", deck="#4F5866", underside="#272D36", pier="#3E4652", abutment="#323944",
        trail="#B8F4FF", glow="#5FD9FF", satellite="#FFFFFF", panel="#2F6AC0"),
    "tinted": dict(
        sky=["#000000", "#0A0A0A", "#262626"], stars=0.8, star="#FFFFFF", ground="#000000", road="#0D0D0D", dash="#5C5C5C",
        parapet="#9A9A9A", deck="#7A7A7A", underside="#3A3A3A", pier="#5E5E5E", abutment="#4A4A4A",
        trail="#FFFFFF", glow="#E0E0E0", satellite="#FFFFFF", panel="#BDBDBD"),
    "red": dict(
        sky=["#000000", "#120000", "#2A0000"], stars=0.8, star="#FF3030", ground="#000000", road="#0A0000", dash="#7A0000",
        parapet="#B01515", deck="#8A0F0F", underside="#3A0505", pier="#6A0A0A", abutment="#4A0707",
        trail="#FF3B3B", glow="#FF1F1F", satellite="#FF6B6B", panel="#B01515"),
}


def stars(opacity: float, color: str) -> str:
    """Deterministic, so regenerating the icon doesn't reshuffle the sky."""
    rng = random.Random(7)
    out = []
    for _ in range(70):
        x, y = rng.uniform(20, 1004), rng.uniform(20, 470)
        r = rng.choice([1.6, 2.0, 2.4, 3.2])
        out.append(f'<circle cx="{x:.0f}" cy="{y:.0f}" r="{r}" fill="{color}" opacity="{opacity * rng.uniform(0.35, 1):.2f}"/>')
    return "\n    ".join(out)


def art(p: dict) -> str:
    """The 1024×1024 square artwork, edge to edge (iOS masks the corners itself)."""
    # Road lane dashes in perspective: longer and wider as they come closer.
    dashes = []
    y = 712.0
    while y < 1024:
        t = (y - 700) / 324
        length, width = 10 + 70 * t, 3 + 14 * t
        dashes.append(f'<rect x="{512 - width / 2:.1f}" y="{y:.1f}" width="{width:.1f}" height="{length:.1f}" fill="{p["dash"]}"/>')
        y += length * 1.9
    return f"""
  <defs>
    <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{p['sky'][0]}"/>
      <stop offset="0.62" stop-color="{p['sky'][1]}"/>
      <stop offset="1" stop-color="{p['sky'][2]}"/>
    </linearGradient>
    <linearGradient id="trail" x1="70" y1="0" x2="836" y2="0" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{p['trail']}" stop-opacity="0"/>
      <stop offset="1" stop-color="{p['trail']}" stop-opacity="1"/>
    </linearGradient>
    <filter id="blur" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="14"/></filter>
    <filter id="soft" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="5"/></filter>
  </defs>

  <rect width="1024" height="1024" fill="url(#sky)"/>
  <g>
    {stars(p['stars'], p['star'])}
  </g>

  <!-- The satellite's pass, arcing over the bridge. -->
  <path d="M 60 520 Q 390 50 836 206" fill="none" stroke="url(#trail)" stroke-width="26" stroke-linecap="round" filter="url(#soft)" opacity="0.55"/>
  <path d="M 60 520 Q 390 50 836 206" fill="none" stroke="url(#trail)" stroke-width="9" stroke-linecap="round"/>
  <circle cx="842" cy="208" r="58" fill="{p['glow']}" opacity="0.55" filter="url(#blur)"/>
  <g transform="translate(842 208) rotate(16) scale(0.9)">
    <rect x="-86" y="-15" width="58" height="30" rx="3" fill="{p['panel']}" stroke="{p['satellite']}" stroke-width="3"/>
    <rect x="28" y="-15" width="58" height="30" rx="3" fill="{p['panel']}" stroke="{p['satellite']}" stroke-width="3"/>
    <rect x="-30" y="-4" width="60" height="8" fill="{p['satellite']}"/>
    <rect x="-20" y="-22" width="40" height="44" rx="6" fill="{p['satellite']}"/>
  </g>

  <!-- Ground and the road running under the overpass. -->
  <rect y="700" width="1024" height="324" fill="{p['ground']}"/>
  <polygon points="300,1024 724,1024 530,700 494,700" fill="{p['road']}"/>
  {''.join(dashes)}

  <!-- Embankments, piers and the deck. -->
  <polygon points="-10,628 250,628 372,790 -10,790" fill="{p['abutment']}"/>
  <polygon points="1034,628 774,628 652,790 1034,790" fill="{p['abutment']}"/>
  <rect x="382" y="628" width="44" height="122" fill="{p['pier']}"/>
  <rect x="598" y="628" width="44" height="122" fill="{p['pier']}"/>
  <rect x="-10" y="600" width="1044" height="30" fill="{p['underside']}"/>
  <rect x="-10" y="532" width="1044" height="70" fill="{p['deck']}"/>
  <rect x="-10" y="512" width="1044" height="22" fill="{p['parapet']}"/>
  <rect x="-10" y="560" width="1044" height="4" fill="{p['underside']}" opacity="0.5"/>
"""


def svg(body: str, size: int = 1024) -> str:
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 1024 1024">{body}</svg>\n'


def mac(p: dict) -> str:
    """macOS icons carry their own shape: a rounded square on Apple's 824-in-1024 grid."""
    return f"""
  <defs>
    <clipPath id="squircle"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="12" stdDeviation="14" flood-opacity="0.35"/>
    </filter>
  </defs>
  <rect x="100" y="100" width="824" height="824" rx="185" fill="#000" filter="url(#shadow)"/>
  <g clip-path="url(#squircle)">
    <g transform="translate(100 100) scale({824 / 1024})">{art(p)}</g>
  </g>
"""


def render(source: Path, out: Path, size: int) -> None:
    subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), "-o", str(out), str(source)], check=True)


def write_contents(folder: Path, images: list) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


def main() -> None:
    SVG_DIR.mkdir(parents=True, exist_ok=True)
    for name, palette in PALETTES.items():
        (SVG_DIR / f"{name}.svg").write_text(svg(art(palette)))
    (SVG_DIR / "mac.svg").write_text(svg(mac(PALETTES["light"])))

    write_contents(ASSETS, [])

    icon = ASSETS / "AppIcon.appiconset"
    images = []
    for name, appearance in [("light", None), ("dark", "dark"), ("tinted", "tinted")]:
        filename = f"AppIcon-{name}.png"
        render(SVG_DIR / f"{name}.svg", icon / filename, 1024) if icon.mkdir(parents=True, exist_ok=True) is None else None
        entry = {"filename": filename, "idiom": "universal", "platform": "ios", "size": "1024x1024"}
        if appearance:
            entry["appearances"] = [{"appearance": "luminosity", "value": appearance}]
        images.append(entry)
    for points in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            filename = f"mac-{points}@{scale}x.png"
            render(SVG_DIR / "mac.svg", icon / filename, points * scale)
            images.append({"filename": filename, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
    write_contents(icon, images)

    red = ASSETS / "AppIconRed.appiconset"
    red.mkdir(parents=True, exist_ok=True)
    render(SVG_DIR / "red.svg", red / "AppIconRed.png", 1024)
    write_contents(red, [{"filename": "AppIconRed.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}])

    # A preview of all four for checking by eye.
    previews = "".join(
        f'<g transform="translate({i * 1064} 0)"><image href="{name}.svg" width="1024" height="1024"/></g>'
        for i, name in enumerate(["light", "dark", "tinted", "red"]))
    (SVG_DIR / "preview.svg").write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{4 * 1064}" height="1024">{previews}</svg>\n')
    print(f"Wrote {icon.relative_to(ROOT)} and {red.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
