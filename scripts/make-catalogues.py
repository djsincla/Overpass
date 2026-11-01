#!/usr/bin/env python3
"""Writes Sources/SkyKit/DeepSkyData.swift and NamedStarsData.swift.

Run by hand when the sources change, with the downloads in one folder:

    scripts/make-catalogues.py DOWNLOADS

DOWNLOADS holds:
- NGC.csv and addendum.csv from OpenNGC, https://github.com/mattiaverga/OpenNGC
  (Mattia Verga, CC BY-SA 4.0): positions, types, magnitudes, sizes, Messier numbers.
- IAU-CSN.txt, the IAU Working Group on Star Names list,
  https://www.pas.rochester.edu/~emamajek/WGSN/IAU-CSN.txt: names, Hipparcos J2000 positions, V magnitudes.

M102 follows the usual modern reading, NGC 5866; OpenNGC lists it as a duplicate of M101.
Caldwell numbers come from Patrick Moore's list, below, as NGC/IC names or OpenNGC addendum entries.
"""
import csv
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Sources" / "SkyKit"

CALDWELL = {
    1: "NGC0188", 2: "NGC0040", 3: "NGC4236", 4: "NGC7023", 5: "IC0342", 6: "NGC6543", 7: "NGC2403",
    8: "NGC0559", 9: "C009", 10: "NGC0663", 11: "NGC7635", 12: "NGC6946", 13: "NGC0457", 14: "C014",
    15: "NGC6826", 16: "NGC7243", 17: "NGC0147", 18: "NGC0185", 19: "IC5146", 20: "NGC7000",
    21: "NGC4449", 22: "NGC7662", 23: "NGC0891", 24: "NGC1275", 25: "NGC2419", 26: "NGC4244",
    27: "NGC6888", 28: "NGC0752", 29: "NGC5005", 30: "NGC7331", 31: "IC0405", 32: "NGC4631",
    33: "NGC6992", 34: "NGC6960", 35: "NGC4889", 36: "NGC4559", 37: "NGC6885", 38: "NGC4565",
    39: "NGC2392", 40: "NGC3626", 41: "C041", 42: "NGC7006", 43: "NGC7814", 44: "NGC7479",
    45: "NGC5248", 46: "NGC2261", 47: "NGC6934", 48: "NGC2775", 49: "NGC2237", 50: "NGC2244",
    51: "IC1613", 52: "NGC4697", 53: "NGC3115", 54: "NGC2506", 55: "NGC7009", 56: "NGC0246",
    57: "NGC6822", 58: "NGC2360", 59: "NGC3242", 60: "NGC4038", 61: "NGC4039", 62: "NGC0247",
    63: "NGC7293", 64: "NGC2362", 65: "NGC0253", 66: "NGC5694", 67: "NGC1097", 68: "NGC6729",
    69: "NGC6302", 70: "NGC0300", 71: "NGC2477", 72: "NGC0055", 73: "NGC1851", 74: "NGC3132",
    75: "NGC6124", 76: "NGC6231", 77: "NGC5128", 78: "NGC6541", 79: "NGC3201", 80: "NGC5139",
    81: "NGC6352", 82: "NGC6193", 83: "NGC4945", 84: "NGC5286", 85: "IC2391", 86: "NGC6397",
    87: "NGC1261", 88: "NGC5823", 89: "NGC6087", 90: "NGC2867", 91: "NGC3532", 92: "NGC3372",
    93: "NGC6752", 94: "NGC4755", 95: "NGC6025", 96: "NGC2516", 97: "NGC3766", 98: "NGC4609",
    99: "C099", 100: "IC2944", 101: "NGC6744", 102: "IC2602", 103: "NGC2070", 104: "NGC0362",
    105: "NGC4833", 106: "NGC0104", 107: "NGC6101", 108: "NGC4372", 109: "NGC3195",
}

KINDS = {
    "G": "galaxy", "GPair": "galaxy", "GTrpl": "galaxy", "GGroup": "galaxy",
    "OCl": "openCluster", "*Ass": "asterism", "Other": "asterism", "GCl": "globularCluster", "Cl+N": "clusterWithNebula",
    "EmN": "nebula", "HII": "nebula", "Neb": "nebula", "RfN": "nebula", "DrkN": "darkNebula",
    "PN": "planetaryNebula", "SNR": "supernovaRemnant", "*": "star", "**": "doubleStar",
}


def degrees(sexagesimal, hours):
    sign = -1 if sexagesimal.startswith("-") else 1
    parts = [float(p) for p in sexagesimal.lstrip("+-").split(":")]
    value = parts[0] + parts[1] / 60 + (parts[2] if len(parts) > 2 else 0) / 3600
    return sign * value * (15 if hours else 1)


def designation(name):
    m = re.fullmatch(r"(NGC|IC)0*(\d+)(.*)", name)
    return f"{m.group(1)} {m.group(2)}{m.group(3)}" if m else None


def swift_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def number(s):
    try:
        return float(s)
    except ValueError:
        return None


def load_openngc(folder):
    rows = {}
    for file in ("NGC.csv", "addendum.csv"):
        with open(folder / file, newline="", encoding="utf-8") as f:
            for row in csv.DictReader(f, delimiter=";"):
                rows[row["Name"]] = row
    return rows


def resolve(rows, name):
    """A duplicate entry's data comes from the object it duplicates, keeping its own designation."""
    row = rows[name]
    if row["Type"] != "Dup":
        return row
    target = f"NGC{int(row['NGC']):04d}" if row["NGC"] else f"IC{int(row['IC']):04d}"
    return dict(rows[target], Name=name)


def entry(id_, row, common=None):
    kind = KINDS.get(row["Type"])
    if kind is None:
        sys.exit(f"{id_}: no kind for type {row['Type']} ({row['Name']})")
    names = [n for n in row["Common names"].split(",") if n]
    name = common or (names[0] if names else "")
    magnitude = number(row["V-Mag"]) or number(row["B-Mag"])
    size = number(row["MajAx"])
    fields = [
        f"id: {swift_string(id_)}",
        f"name: {swift_string(name)}",
        f"designation: {swift_string(designation(row['Name']) or '')}",
        f"kind: .{kind}",
        f"constellation: {swift_string(row['Const'])}",
        f"ra: {degrees(row['RA'], True):.5f}",
        f"dec: {degrees(row['Dec'], False):.5f}",
        f"magnitude: {magnitude if magnitude is not None else 'nil'}",
        f"size: {size if size is not None else 'nil'}",
    ]
    return "        DeepSkyObject(" + ", ".join(fields) + "),"


def deep_sky(folder):
    rows = load_openngc(folder)
    messier = {}
    for row in rows.values():
        if row["M"] and row["Type"] != "Dup":
            messier[int(row["M"])] = row
    messier[102] = rows["NGC5866"]
    missing = [m for m in range(1, 111) if m not in messier]
    if missing:
        sys.exit(f"Messier objects missing: {missing}")
    lines = [
        "// Generated by scripts/make-catalogues.py from OpenNGC (Mattia Verga, CC BY-SA 4.0). Do not edit.",
        "",
        "extension DeepSky {",
        "    /// M1 to M110, J2000.",
        "    public static let messier: [DeepSkyObject] = [",
    ]
    lines += [entry(f"M{m}", messier[m]) for m in range(1, 111)]
    lines += ["    ]", "", "    /// C1 to C109, J2000.", "    public static let caldwell: [DeepSkyObject] = ["]
    for c in range(1, 110):
        if CALDWELL[c] not in rows:
            sys.exit(f"C{c}: {CALDWELL[c]} not in OpenNGC")
        lines.append(entry(f"C{c}", resolve(rows, CALDWELL[c])))
    lines += ["    ]", "}", ""]
    (OUT / "DeepSkyData.swift").write_text("\n".join(lines), encoding="utf-8")
    return len(messier), 109


def ngc_ic(folder):
    """Every NGC and IC object as one compact text block, parsed when first used: 13,000 Swift
    initialisers take minutes to type-check, a string literal doesn't."""
    rows = load_openngc(folder)
    out = []
    for name in sorted(rows, key=lambda n: (n[:3] != "NGC", int(re.sub(r"\D", "", n[3:7] if n.startswith("NGC") else n[2:6]) or 0), n)):
        m = re.fullmatch(r"(NGC|IC)\d+[A-Z]?", name)
        row = rows[name]
        if not m or row["Type"] not in KINDS or not row["RA"]:
            continue
        names = [n for n in row["Common names"].split(",") if n]
        magnitude = number(row["V-Mag"]) or number(row["B-Mag"])
        size = number(row["MajAx"])
        fields = [designation(name), KINDS[row["Type"]], row["Const"],
                  f"{degrees(row['RA'], True):.5f}", f"{degrees(row['Dec'], False):.5f}",
                  "" if magnitude is None else str(magnitude), "" if size is None else str(size),
                  names[0] if names else "", row["M"]]
        out.append("|".join(f.replace("|", "/") for f in fields))
    lines = [
        "// Generated by scripts/make-catalogues.py from OpenNGC (Mattia Verga, CC BY-SA 4.0). Do not edit.",
        "",
        "extension DeepSky {",
        "    /// designation|kind|constellation|ra|dec|magnitude|size|common name|Messier number, J2000.",
        '    static let ngcICText = """',
    ]
    lines += out
    lines += ['"""', "}", ""]
    (OUT / "NGCICData.swift").write_text("\n".join(lines), encoding="utf-8")
    return len(out)


def named_stars(folder, limit=4.0):
    stars = {}
    date = re.compile(r"\d{4}-\d{2}-\d{2}")
    for line in (folder / "IAU-CSN.txt").read_text(encoding="utf-8").splitlines():
        if line.startswith("#") or not line.strip():
            continue
        tokens = line.split()
        i = next((k for k, t in enumerate(tokens) if date.fullmatch(t)), None)
        if i is None or i < 10:
            continue
        # Names may have spaces ("Rigil Kentaurus"): the second column is fixed width.
        name, vmag, hip = line[18:36].strip(), number(tokens[i - 6]), tokens[i - 4]
        ra, dec = number(tokens[i - 2]), number(tokens[i - 1])
        greek, con = tokens[i - 10], tokens[i - 9]
        if hip == "_" or vmag is None or vmag > limit or ra is None or dec is None or name in stars:
            continue
        bayer = f"{greek} {con}" if greek != "_" else ""
        stars[name] = (name, bayer, ra, dec, vmag)
    lines = [
        "// Generated by scripts/make-catalogues.py from the IAU WGSN star names list. Do not edit.",
        "",
        "extension NamedStars {",
        f"    /// IAU-named stars to magnitude {limit}, J2000 (Hipparcos), brightest first.",
        "    public static let all: [Star] = [",
    ]
    for name, bayer, ra, dec, vmag in sorted(stars.values(), key=lambda s: s[4]):
        lines.append(f"        Star(name: {swift_string(name)}, ra: {ra:.6f}, dec: {dec:.6f}, magnitude: {vmag}, "
                     f"designation: {swift_string(bayer) if bayer else 'nil'}),")
    lines += ["    ]", "}", ""]
    (OUT / "NamedStarsData.swift").write_text("\n".join(lines), encoding="utf-8")
    return len(stars)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    folder = Path(sys.argv[1])
    m, c = deep_sky(folder)
    s = named_stars(folder)
    n = ngc_ic(folder)
    print(f"{m} Messier, {c} Caldwell, {n} NGC and IC, {s} named stars")
