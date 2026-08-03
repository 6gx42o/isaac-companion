#!/usr/bin/env python3
"""Bakes the item and character tables into the Windows build.

Reads the bundle the macOS app already builds from the user's own game install and
writes two TSVs that `src/run.rs` includes at compile time. Game data is identical on
every platform, so this is the same data both builds run on -- and it means the
Windows .exe needs no ResourceExtractor step and no data directory of its own.

TSV rather than JSON so the Rust side parses with `split('\\t')` and the binary can
stay dependency-free.
"""
import gzip
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
BUNDLE = pathlib.Path.home() / "Library/Application Support/IsaacCompanion/data/abplus/items.json.gz"

ITEM_FIELDS = [
    "damage", "damageMultiplier", "tears", "tearsMultiplier", "tearDelay",
    "range", "speed", "shotSpeed", "luck", "shots",
]


def cell(v):
    """Empty means "no opinion", which is not the same as zero -- the stat engine
    counts how many multipliers exist, so a missing one must not arrive as 1.0."""
    if v is None:
        return ""
    if isinstance(v, bool):
        return "1" if v else ""
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    return str(v)


def main():
    if not BUNDLE.exists():
        sys.exit(f"no data bundle at {BUNDLE}\nRun `swift run ingestctl build` first.")
    data = json.loads(gzip.open(BUNDLE).read())

    rows = ["\t".join(["id", "name"] + ITEM_FIELDS + ["flight"])]
    for item in data["items"]:
        # Only auto-tracked collectibles: the log announces those and nothing else,
        # so a trinket or card in this table could never be matched to a log line.
        if item.get("kind") in ("card", "pill", "trinket"):
            continue
        d = item.get("delta") or {}
        # A name with a tab in it would shift every later column. None have one, but
        # the check costs nothing and the failure would be silent and baffling.
        name = item["name"].replace("\t", " ")
        rows.append("\t".join(
            [str(item["id"]), name] + [cell(d.get(f)) for f in ITEM_FIELDS]
            + [cell(d.get("flight"))]))
    (HERE / "src/items.tsv").write_text("\n".join(rows) + "\n")

    crows = ["\t".join([
        "id", "name", "damage", "tears", "range", "speed", "shotSpeed", "luck",
        "flight", "damageMultiplier", "fireDelayMultiplier", "unverified"])]
    for c in data["characters"]:
        crows.append("\t".join([
            str(c["id"]), c["name"].replace("\t", " "),
            cell(c.get("damage")), cell(c.get("tears")), cell(c.get("range")),
            cell(c.get("speed")), cell(c.get("shotSpeed")), cell(c.get("luck")),
            "1" if c.get("flight") else "",
            cell(c.get("damageMultiplier")), cell(c.get("fireDelayMultiplier")),
            ",".join(c.get("unverified") or []),
        ]))
    (HERE / "src/characters.tsv").write_text("\n".join(crows) + "\n")

    # ---- the browser's tables -------------------------------------------------
    #
    # Names, ids, kinds, pools and stat numbers only. Deliberately NOT the
    # descriptions: those are the External Item Descriptions mod's text, which ships
    # without a licence and is not ours to bake into a binary we hand out. The Windows
    # browser reads them from the user's own EID install if it is there, exactly as the
    # Mac app does, and shows names and numbers when it is not.
    #
    # Sprites are the same story for a different reason -- they are Nicalis's art -- so
    # they are read from the user's own game install and never redistributed.
    brows = ["\t".join(["id", "kind", "name", "pools", "cache", "special", "gfx"])]
    for item in data["items"]:
        brows.append("\t".join([
            str(item["id"]),
            item.get("kind") or "passive",
            item["name"].replace("\t", " "),
            ",".join(item.get("pools") or []),
            ",".join(item.get("cache") or []),
            "1" if item.get("special") else "",
            item.get("gfx") or "",
        ]))
    (HERE / "src/browse.tsv").write_text("\n".join(brows) + "\n")

    erows = ["\t".join(["type", "variant", "name", "hp", "boss"])]
    for e in data.get("entities", []):
        if not e.get("name"):
            continue
        erows.append("\t".join([
            str(e.get("type", 0)), str(e.get("variant", 0)),
            e["name"].replace("\t", " "),
            cell(e.get("baseHP")),
            "1" if e.get("isBoss") else "",
        ]))
    (HERE / "src/enemies.tsv").write_text("\n".join(erows) + "\n")

    arows = ["\t".join(["id", "name", "condition"])]
    for a in data.get("achievements", []):
        # The game's own achievements.xml, same class of data as the item names above.
        # The announcement is a sentence, not a name: `You unlocked "Magdalene"` and
        # `"A Bag of Pennies" has appeared in the basement`. The name is what sits
        # between the first and last quote -- the same rule AppModel.tidy uses, so both
        # builds label an achievement identically.
        ann = a.get("announcement") or ""
        first, last = ann.find('"'), ann.rfind('"')
        name = ann[first + 1:last] if 0 <= first < last else ann
        arows.append("\t".join([
            str(a["id"]), name.replace("\t", " "),
            (a.get("condition") or "").replace("\t", " "),
        ]))
    (HERE / "src/achievements.tsv").write_text("\n".join(arows) + "\n")

    print(f"items.tsv:      {len(rows) - 1} collectibles")
    print(f"characters.tsv: {len(crows) - 1} characters")
    print(f"browse.tsv:     {len(brows) - 1} items")
    print(f"enemies.tsv:    {len(erows) - 1} entities")
    print(f"achievements.tsv: {len(arows) - 1} achievements")


if __name__ == "__main__":
    main()
