#!/usr/bin/env python3
"""Translations for Overpass's string catalogs and App Store listing.

    scripts/l10n.py export DIR          every string, with its comment and the German and Spanish
                                        as a reference, to DIR/source.json
    scripts/l10n.py check DIR LANG      checks DIR/LANG.json against DIR/source.json: every key,
                                        the same format specifiers, plurals, listing lengths
    scripts/l10n.py merge DIR LANG...   writes each checked DIR/LANG.json into the catalogs and
                                        appstore/listing.json
    scripts/l10n.py missing             languages in the catalogs, with how many strings each lacks
    scripts/l10n.py english             US and UK English: the English is written British; this
                                        gives every string with a British spelling an American "en"
                                        and a British "en-GB". Run it after adding strings.

A translation file is {"App": {key: text or {"one", "other"}}, "InfoPlist": {...},
"SkyKit": {...}, "listing": {"subtitle", "promotionalText", "keywords", "description"}}.
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOGS = {
    "App": "App/Localizable.xcstrings",
    "InfoPlist": "App/InfoPlist.xcstrings",
    "SkyKit": "Sources/SkyKit/Resources/Localizable.xcstrings",
}
LISTING = "appstore/listing.json"
# App Store Connect's locale for each catalog language.
STORE_LOCALE = {"es": "es-ES", "de": "de-DE", "fr": "fr-FR", "it": "it", "ja": "ja", "pt-BR": "pt-BR",
                "nl": "nl-NL", "sv": "sv", "da": "da", "nb": "no", "fi": "fi", "en-GB": "en-GB"}
LIMITS = {"subtitle": 30, "promotionalText": 170, "keywords": 100, "description": 4000}
# British to American, for the words Overpass uses. Names keep their own spelling (Minor Planet
# Center, Apache License). Add a pair when a new British spelling appears in the strings.
AMERICAN = {"centre": "center", "centres": "centers", "centred": "centered", "centring": "centering",
            "catalogue": "catalog", "catalogues": "catalogs", "analogue": "analog", "metre": "meter",
            "metres": "meters", "colour": "color", "colours": "colors", "licence": "license",
            "grey": "gray", "favourite": "favorite", "favourites": "favorites"}
WORD = re.compile(r"\b(" + "|".join(AMERICAN) + r")\b", re.I)
SPEC = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|\.?\d*f|%)")


def load(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as f:
        return json.load(f)


def save_catalog(path, data):
    # The catalogs' layout: two-space indent, sorted keys.
    text = json.dumps(data, ensure_ascii=False, indent=2, separators=(",", ": "), sort_keys=True)
    with open(os.path.join(ROOT, path), "w", encoding="utf-8") as f:
        f.write(text + "\n")


def source_text(key, entry):
    en = entry.get("localizations", {}).get("en", {})
    return en["stringUnit"]["value"] if "stringUnit" in en else key


def is_plural(entry):
    return any("variations" in l for l in entry.get("localizations", {}).values())


def reference(entry, lang):
    l = entry.get("localizations", {}).get(lang)
    if not l:
        return None
    if "stringUnit" in l:
        return l["stringUnit"]["value"]
    return {c: u["stringUnit"]["value"] for c, u in l["variations"]["plural"].items()}


def specs(text):
    return sorted(re.sub(r"\d+\$", "", m) for m in SPEC.findall(text))


def export(folder):
    out = {}
    for group, path in CATALOGS.items():
        out[group] = {}
        for key, entry in load(path)["strings"].items():
            if entry.get("shouldTranslate") is False:
                continue
            e = {"source": source_text(key, entry), "de": reference(entry, "de"), "es": reference(entry, "es")}
            if is_plural(entry):
                e["plural"] = True
            if entry.get("comment"):
                e["comment"] = entry["comment"]
            out[group][key] = e
    locales = load(LISTING)["locales"]
    out["listing"] = {f: {"en": locales["en-US"][f], "de": locales["de-DE"].get(f)} for f in LIMITS}
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "source.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    print(f"{sum(len(out[g]) for g in CATALOGS)} strings to {folder}/source.json")


def check(folder, lang):
    with open(os.path.join(folder, "source.json"), encoding="utf-8") as f:
        src = json.load(f)
    with open(os.path.join(folder, f"{lang}.json"), encoding="utf-8") as f:
        out = json.load(f)
    problems = []
    for group in CATALOGS:
        for key, e in src[group].items():
            t = out.get(group, {}).get(key)
            want = specs(e["source"])
            if t is None:
                problems.append(f"{group}: missing {key!r}")
            elif e.get("plural"):
                if not (isinstance(t, dict) and "one" in t and "other" in t):
                    problems.append(f"{group}: {key!r} needs one and other")
                else:
                    problems += [f"{group}: {key!r} [{c}] has {specs(v)}, wants {want}" for c, v in t.items() if specs(v) != want]
            elif not isinstance(t, str):
                problems.append(f"{group}: {key!r} should be text")
            elif specs(t) != want:
                problems.append(f"{group}: {key!r} has {specs(t)}, wants {want}")
        extra = set(out.get(group, {})) - set(src[group])
        if extra:
            problems.append(f"{group}: keys not in the source: {sorted(extra)[:5]}")
    for field, limit in LIMITS.items():
        v = out.get("listing", {}).get(field)
        if not v:
            problems.append(f"listing: missing {field}")
        elif len(v) > limit:
            problems.append(f"listing: {field} is {len(v)} characters; the limit is {limit}")
    return problems


def merge(folder, langs):
    for lang in langs:
        problems = check(folder, lang)
        if problems:
            sys.exit(f"{lang} doesn't pass the check:\n" + "\n".join(problems))
    for group, path in CATALOGS.items():
        data = load(path)
        for lang in langs:
            with open(os.path.join(folder, f"{lang}.json"), encoding="utf-8") as f:
                strings = json.load(f)[group]
            for key, t in strings.items():
                locs = data["strings"][key].setdefault("localizations", {})
                if isinstance(t, dict):
                    locs[lang] = {"variations": {"plural": {c: {"stringUnit": {"state": "translated", "value": v}} for c, v in t.items()}}}
                else:
                    locs[lang] = {"stringUnit": {"state": "translated", "value": t}}
        save_catalog(path, data)
    listing = load(LISTING)
    english = listing["locales"]["en-US"]
    for lang in langs:
        with open(os.path.join(folder, f"{lang}.json"), encoding="utf-8") as f:
            text = json.load(f)["listing"]
        locale = listing["locales"].setdefault(STORE_LOCALE[lang], {})
        for field in ("name", "supportUrl", "marketingUrl", "privacyPolicyUrl"):
            locale.setdefault(field, english[field])
        locale.update({f: text[f] for f in LIMITS})
    with open(os.path.join(ROOT, LISTING), "w", encoding="utf-8") as f:
        f.write(json.dumps(listing, ensure_ascii=False, indent=2) + "\n")
    print("Merged " + ", ".join(langs))


def american(text):
    def swap(m):
        word = AMERICAN[m.group(0).lower()]
        return word.capitalize() if m.group(0)[0].isupper() else word
    return WORD.sub(swap, text)


def english():
    changed = 0
    for path in CATALOGS.values():
        data = load(path)
        for key, entry in data["strings"].items():
            locs = entry.setdefault("localizations", {})
            en = locs.get("en")
            if en and "variations" in en:
                forms = {c: u["stringUnit"]["value"] for c, u in en["variations"]["plural"].items()}
            elif en:
                forms = {None: en["stringUnit"]["value"]}
            else:
                forms = {None: key}
            if "en-GB" in locs:  # already split: the British is in en-GB
                gb = locs["en-GB"]
                forms = ({c: u["stringUnit"]["value"] for c, u in gb["variations"]["plural"].items()}
                         if "variations" in gb else {None: gb["stringUnit"]["value"]})
            if not any(WORD.search(v) for v in forms.values()):
                continue
            def unit(v): return {"stringUnit": {"state": "translated", "value": v}}
            def entry_for(f):
                if None in f: return unit(f[None])
                return {"variations": {"plural": {c: unit(v) for c, v in f.items()}}}
            locs["en-GB"] = entry_for(forms)
            locs["en"] = entry_for({c: american(v) for c, v in forms.items()})
            changed += 1
        save_catalog(path, data)
    print(f"{changed} strings with British spellings: American in en, British in en-GB")


def missing():
    counts = {}
    for path in CATALOGS.values():
        for key, entry in load(path)["strings"].items():
            if entry.get("shouldTranslate") is False:
                continue
            for lang in {l for e in load(path)["strings"].values() for l in e.get("localizations", {})} - {"en", "en-GB"}:
                if lang not in entry.get("localizations", {}):
                    counts[lang] = counts.get(lang, 0) + 1
                else:
                    counts.setdefault(lang, 0)
    for lang, n in sorted(counts.items()):
        print(f"{lang}: {n} missing")


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["export"] and len(args) == 2:
        export(args[1])
    elif args[:1] == ["check"] and len(args) == 3:
        problems = check(args[1], args[2])
        print("\n".join(problems) or f"{args[2]}: OK")
        sys.exit(1 if problems else 0)
    elif args[:1] == ["merge"] and len(args) >= 3:
        merge(args[1], args[2:])
    elif args == ["english"]:
        english()
    elif args == ["missing"]:
        missing()
    else:
        sys.exit(__doc__)
