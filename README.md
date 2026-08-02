# Isaac Companion

A live run tracker and item reference for **The Binding of Isaac: Afterbirth+**.

A **macOS app** with an always-on-top game overlay, a full item/enemy/achievement
browser and a pedestal scanner — plus a **Windows build** running the same log parser
and the same stat engine.

Tails the game's own `log.txt`, so it knows what you picked up without any input from
you — and computes what your stats *actually are*, which no wiki or in-game mod does.

**It requires no mod and never touches the game.** Enabling any Workshop mod in AB+
disables Steam achievements; this reads a log file the game already writes, so your
trophies keep counting.

## Targeting Afterbirth+, deliberately

Your install is `v1.06.T1` — Afterbirth+, collectible IDs up to 552. Almost every
online source now serves **Repentance** data, which is wrong here in ways that are
invisible until the numbers are quietly incorrect. So the data build asserts, and
fails loudly if any of these break:

- max collectible id ≤ 552 (Repentance goes to 732)
- Sad Onion is `+0.7` tears (Repentance: 0.72)
- Inner Eye is `x0.48` tears (Repentance: 0.51)
- 26 item pools, no `planetarium`
- no `quality` field anywhere — **AB+ has no item quality**; showing one would be
  importing a Repentance concept

## Running it

```bash
./make-app.sh && open build/IsaacCompanion.app          # dev build, this Mac's arch
./make-app.sh release --universal                      # arm64 + x86_64 in one binary
./package.sh                                           # -> dist/*.dmg *.pkg *.zip *.exe
```

`package.sh` produces every install format from one universal binary, so an M-series
Mac and a 2017 Intel MacBook take the same download and both run it natively — no
Rosetta, nothing to choose between. It also cross-compiles the Windows `.exe` when the
toolchain is present.

First launch asks for the game folder and a storage mode, then builds the data
(~2 seconds). Change the storage mode later in Settings — it rebuilds and restarts.

| Mode | Disk | Trade |
|---|---|---|
| Compact (default) | ~5 MB | discards the 570 MB extraction once harvested |
| Cached | ~575 MB | keeps it, so rebuilds skip the one-minute extract |

Both produce identical data. The setting trades disk for rebuild speed, never
features. Sprite atlasing, gzipped JSON, and extract→harvest→delete are always on.

Actual footprint: **1.9 MB app + 3.3 MB support** (328 KB built data — 674 sprites in
one 236 KB atlas, plus gzipped JSON — and a 3 MB harvest cache).

## Where the data comes from

| What | Source |
|---|---|
| ids, sprites, `cache` flags, charges, devil price | `resources.jp/items.xml` (shipped unpacked; those attributes are language-independent) |
| names, descriptions, numeric stat deltas | EID's `descriptions/ab+/` — read at build time, then **vendored** into the app so the mod can be deleted |
| item pools, sprites, English names | `itempools.xml` / `items.xml` / `gfx/items/**` via the game's own `ResourceExtractor`, run automatically on first build |
| character base stats | hand-authored — AB+ hardcodes them in the binary, `players.xml` has none |

Every item is graded and the grade is shown in the UI:

- `verified` — EID's typed data and its description text agree (86 items)
- `crossChecked` — present in both, only one carries numbers (32)
- `singleSource` — prose-only extraction (2: Cancer, Tape Worm)
- `conditional` — real effect, but timed/triggered/conditional, so there is no
  permanent number to add (42). Explains why the game's `cache` flag fires.
- `nonNumeric` — genuinely changes no stat

The build **fails** if any item claims a stat change and has neither numbers nor an
explicit conditional/non-numeric classification. No silent gaps.

## The stat model

Validated against known in-game values before anything was built on it:

| Case | Expected | Why it matters |
|---|---|---|
| Isaac base | 3.50 dmg, delay 10, 2.73 tears/s | baseline |
| + Blood of the Martyr | `3.5·√(1·1.2+1)` = 5.19 | confirms the sqrt curve |
| + Cricket's Head | `3.5·√(1.6)·1.5` = 6.64 | multiplier after the curve |
| + Ipecac | `3.5·√(49)` = 24.50 | exactly 7× — a designed-clean number |
| + Sad Onion | `16−6·√(1.91)`=7.71 → **floor 7** → 3.75/s | AB+ floors tear delay; Repentance does not |

Anything the game does not document — the ordering of simultaneous tear modifiers,
whether two ×1.5 damage multipliers share a slot — is shown with a `~` and a reason,
not guessed at.

## Development

```bash
swift test                 # 114 tests
swift run ingestctl build  # rebuild the data bundle, run all canaries
swift run ingestctl run    # replay the real log.txt through parser → engine
swift run ingestctl gaps   # items claiming a stat change with no numbers
swift run ingestctl vendor Sources/IsaacCompanionApp/VendoredData/eid.abplus.json
```

`dev/preview.html` renders the real web UI against real bundle data with the Swift
bridge stubbed, for iterating on the UI without launching the app.

## Character base stats must exclude starting items

The log reports a character's starting items as ordinary pickups, so any stat a
starting item grants must **not** also appear in that character's base row or it gets
counted twice.

```bash
swift run ingestctl startingitems   # flags every starting item with a permanent delta
```

Two real cases: Cain starts with Lucky Foot (+1 luck) — his base luck is 0, not 1.
Lazarus Risen starts with Anemic (+5 range) — which is where the long-running
"is his range 23.75 or 28.75?" dispute came from. It is 23.75; the +5 is the item.

## Stat cards show base + change = total

```
DAMAGE          SPEED
6.12            1.70
3.50 + 2.62     1.10 + 0.60
```

The contribution is **`total - base`**, not the sum of the item deltas — deliberately.
Damage is `base x sqrt(1.2 x damageUps + 1) x multipliers`, so Magic Mushroom's
"+0.3 Damage, x1.5" is worth **+2.62** on Cain, not +0.3. Printing the raw inputs
would produce a line that does not add up. Tears are the same story via tear delay;
both carry a tooltip saying so. Clamped stats (range floors at 5, speed at 0.1) report
the clamped movement, so the arithmetic still reconciles.

`StatBreakdownTests.swift` asserts `base + fromItems == value` across every stat,
including downgrades and clamps.

## What the log does and does not report

`Adding collectible N (Name)` is the **only** pickup line the game writes. There is no
equivalent for trinkets, cards or pills — verified by surveying every distinct line
shape in a 270 KB log. So the run view splits into sections along exactly that seam:

| Section | Source |
|---|---|
| Passive items, Active item, Familiars | auto, from the log |
| Trinket | by hand — the log never says |
| Cards & pills | by hand — the log never says |

The manual-only sections stay visible when empty and carry a one-line note saying why,
rather than looking broken.

### Slot capacity reacts to what you're holding

Trinket and pocket slots hold one thing each — until an item widens them, at which
point the heading becomes `TRINKETS 1/2 · +1 slot from Mom's Purse` and a second
trinket stops evicting the first. Adding beyond capacity drops the **oldest**, matching
what walking over a trinket does in game.

The six items are found by reading EID's wording (`SlotGrants.swift`), not from a
hardcoded id list that would silently rot:

| Section | Items |
|---|---|
| Trinket | Mom's Purse (139), Belly Button (458) |
| Pocket | Starter Deck (251), Little Baggy (252), Deep Pockets (416), Polydactyly (454) |

Each states a capacity of **2**, never "+1", so holding two of them still reads as 2 —
whether AB+ actually stacks them to 3 isn't settled by any source here, and claiming 3
would be a guess. Nothing is hard-blocked: if the count ever exceeds capacity the
header shows `2/1` rather than hiding an item.

Cards (54) and pills (47) come from EID and appear nowhere in `items.xml`. **Their ids
collide with collectible ids** — id 1 is The Sad Onion, "0 - The Fool", *and* Bad Trip
depending on kind — so a held record carries its kind and lookups are keyed on
`(kind, id)`. The add box suffixes them (`0 - The Fool (card)`) to keep that
unambiguous. Tested in `SectionTests.swift`.

## Cross-item reasoning

The part no other tool does. EID shows one pedestal's text with no knowledge of what
you're already holding, so it cannot tell you the Technology you're about to take will
do nothing.

Afterbirth+ resolves competing weapon items by a fixed precedence, which EID encodes as
layer numbers rather than pairwise rules:

```
Epic Fetus 900 > Dr. Fetus 800 > Mom's Knife 700 > Haemolacria 675
  > Brimstone 666 > Tech X 600 > Technology 400 > Ludovico 300
```

`ingestctl` reads those out of `eid_conditionals.lua`, skipping every
`if EID.isRepentance` block, and the canaries assert the ladder's *order* (not just its
presence) plus that no explicit edge contradicts it. From that the app computes, for any
item against any build:

- **overridden** — "Overridden by Brimstone — its weapon effect will not fire
  (precedence 666 vs 400). You keep its stat changes."
- **overrides** — what it beats
- **synergy** — the 43 documented interactions (Brimstone + Ipecac, Technology + Ipecac…)
- **redundant** — a second Homing/Piercing/Spectral source adds only its stats
- **multishot** — additive, never multiplied
- **transformation** — live n/3 progress across all 14 sets

## Two themes: Devil and Angel

Both come from the game's own rooms, and both keep the same rule — **two accents with
two jobs that never trade places**: `--mark` for what is dead, `--hot` for your live
damage number.

| | Devil (default) | Angel |
|---|---|---|
| Ground | near-black, warm | warm marble |
| Live number | ember `#e2542b` | halo gold `#b8860f` |
| Dead | blood `#b81f22` | crimson `#a02b26` |
| Ambient | red glow from above | gold light from above |
| Scanlines | visible | near-invisible (marble has no CRT) |

Angel is not an inverted Devil — Angel Rooms are white stone and gold, so the hot accent
moves from red to gold rather than flipping.

Toggle in the tab bar; persisted in `localStorage`.

### The trap this hit

**WebKit will not interpolate a property whose value is `var(--x)` when `--x` itself
changes** — the element keeps its old computed colour permanently. With
`transition: background-color` on `body`, switching theme left the page stuck on the
old ground while `html` (untransitioned) updated correctly.

The fix is `.no-transition` on `<html>` for exactly one frame across the swap, removed
after two `requestAnimationFrame`s. The switch still reads as a change because the page
plays a single `themeshift` dip-and-lift instead.

## The floating panel

The always-on-top readout is a **native** `NSPanel`, not a second web view —
`.fullScreenAuxiliary` + `.canJoinAllSpaces` on a non-activating panel is the only
combination that stays visible over fullscreen Isaac without stealing its focus.

That means the palette exists twice: once in `Web/style.css` and once as `PanelTheme`
in Swift. To stop them drifting, **Swift owns which theme is live** (`AppModel.theme`
in UserDefaults). The web toggle sends `setTheme` through the bridge; the panel's own
picker bumps `themeRevision`, which pushes back the other way. Change it in either
place and both follow.

**Only the ground fades.** The opacity slider (15–100%) drives the panel's background
and border, never its text — a slider that dimmed the numbers too would make the panel
useless at exactly the setting you most want it at. `isOpaque = false` and a clear
`backgroundColor` are what let it fade onto the game rather than onto system grey.

## Motion

Everything animates, but **only on real change**. The run view re-renders on every log
line, so blanket entry animations would flicker the whole list several times a second.
JS tracks which pickup UIDs and stat values it has already seen, and marks only genuinely
new or changed content:

- `.is-new` — a pickup not seen before, staggered so a floor's worth cascades
- `.is-changed` — a stat whose number actually moved, which flares once
- `.just-died` — an item that became overridden since the last render draws its own
  strike-through
- meters animate their width to the new length rather than jumping

Tracking resets on a new seed. All of it collapses under `prefers-reduced-motion`.

## Visual direction

Devil Room: near-black warm ground, **two reds with two jobs that never trade places** —
`--blood` marks what is dead (rails, glyphs, strike-throughs), `--ember` marks your live
damage number and nothing else. Green is a toxic olive rather than a mint, because a
clean green reads as a spreadsheet.

Four retro cues, deliberately no more: hard edges, scanlines, phosphor bloom **on the
numerals only** (spread wider it reads as blurry, not retro), and wide-tracked uppercase
mono labels.

Committed to one theme — a devil-room readout with a daylight variant would be a skin,
not a point of view.

Two things carry the information design:

- **The meter under each stat** is the glance layer: length is how far the items moved
  you from your character's base, colour is which direction. An untouched stat shows an
  empty track, never a full one.
- **A dead item is cauterised** — blood rail, sunken ground, struck-through name, and the
  reason printed *above* its own description. It stays in the list because you still own
  it, but it reads as gone before you get to the words. The `dead` flag comes from the
  synergy engine in Swift, not from string-matching in JS, so the row and the verdicts
  can never disagree.

## Known-bug regressions

An adversarial review pass (four reviewers, every finding independently refuted-or-
confirmed) found 17 real defects. The ones worth remembering:

- **`.overridden` came only from the layer table**, so 144 of the 147 explicit override
  edges never warned their loser. Cursed Eye + Brimstone returned *nothing*. Precedence
  now reads layers **and** edges.
- **A single-line `if EID.isRepentance then X end`** left the guard flag stuck on,
  silently dropping every AB+ rule after it.
- **Multishot was inflated by burst-fire prose** — Tammy's Head (+9), Isaac's Tears
  (+7) and Lil Loki (+3) all matched "shoots N tears". Only passives can raise Isaac's
  shot count, and the gate must run *after* the text merge or it gets undone.
- **Held items were resolved by id alone**, so a hand-added Bat Wing trinket (id 118)
  became Brimstone and the UI announced "Firing: Brimstone".
- **Trinkets inherited collectible pools**, same id collision.
- **The curse regex required a trailing `!`** that most real log lines lack.
- **`rebuild()` restarted the log tailer**, replaying from the top and wiping every
  manual entry.

## The overlay

A borderless, always-on-top panel that sits over the fullscreen game. It shows your six
stats — and, the part that makes it worth glancing at, **what the item you just picked
up changed**: a per-stat delta held until the next pickup, with the item's name under
it. Ipecac reads `24.50 +21.00` in green and `~1.20 −2.55` in red.

It has its own **Overlay tab** in the app: a live mini-screen showing the panel at its
real position on your real display. Drag the miniature to move the actual window; click
a part of it to take that part off. Around 35 settings — click-through (the mouse passes
to the game), corner snapping, per-display placement, opacity, text scale, compact mode,
decimal places, accent stat, and a switch for every element.

Auto-show and auto-hide hang off the game-process watch, so it appears when Isaac
launches and gets out of the way when you quit.

## The Windows build

`win/` is a separate, **dependency-free** Rust binary that runs the same log parser and
the same Afterbirth+ stat engine. It tails `log.txt`, computes the stats and serves a
readout on localhost, which it opens in your browser. Single 440 KB `.exe`, no
installer, no runtime — it imports only DLLs that ship with Windows.

Cross-compiles from macOS:

```bash
brew install mingw-w64
rustup target add x86_64-pc-windows-gnu
python3 win/bake-data.py     # bakes the item + character tables into the binary
cargo build --release --target x86_64-pc-windows-gnu --manifest-path win/Cargo.toml
cargo test --manifest-path win/Cargo.toml    # 13 tests
```

The stat engine is tested against **the same fixtures as the Swift one** — Isaac
3.50/delay 10, Martyr 5.19, Cricket's 6.64, Ipecac 24.50, Sad Onion floor 7 → 3.75/s. If
the two builds ever disagree about a number, that test fails rather than someone's
screen being wrong.

**Not in it:** the overlay and the pedestal scanner. Both are macOS window-server
features (`NSPanel`, ScreenCaptureKit) with no portable equivalent — so they are absent
rather than faked.

## Data this repository does not contain

`Sources/IsaacCompanionApp/VendoredData/eid.abplus.json` is deliberately **not**
committed. It is a snapshot of the [External Item Descriptions](https://steamcommunity.com/sharedfiles/filedetails/?id=836319872)
mod's own description text, and EID ships without a licence — so it is not ours to
redistribute. Build it from your own install:

```bash
swift run ingestctl vendor Sources/IsaacCompanionApp/VendoredData/eid.abplus.json
```

Everything else comes out of your own copy of the game at build time. The Windows
tables (`win/src/*.tsv`) hold item names and numeric stat deltas only — facts about the
game, no third-party prose.

## Credits

A fan tool, not affiliated with Nicalis or Edmund McMillen.

- **The Binding of Isaac: Afterbirth+** — Nicalis / Edmund McMillen. Names, sprites and
  game data are extracted from your own installation.
- **[External Item Descriptions](https://steamcommunity.com/sharedfiles/filedetails/?id=836319872)**
  — numeric stat data and descriptions, read at build time. Not redistributed.
- **[RebirthItemTracker](https://github.com/Rchardon/RebirthItemTracker)** (BSD-2) and
  **[TBoIR-resources](https://github.com/Derugon/TBoIR-resources)** (Unlicense) — fallback
  data sources.

## Licence

[MIT](LICENSE), for the code in this repository. Game assets and third-party mod data
are not covered by it and are not included.

## Status

**Phases 1–3 done** — data pipeline, log tailing, stat engine, floating panel, storage
setting; sprites, all 26 item pools with weights, item detail view, filters; and the
synergy/override engine with live build conflicts, transformation tracking, and a
"considering a pedestal?" check.

### The pedestal scanner needs re-granting after every rebuild

`make-app.sh` ad-hoc signs the bundle, so **each rebuild produces a different signature
and macOS silently revokes Screen Recording**. `CGPreflightScreenCaptureAccess()` then
returns false and the scan reports it rather than failing opaquely.

After running `make-app.sh`, re-grant in System Settings > Privacy & Security >
Screen Recording (remove the old entry, add the new build). A stable Developer ID
signature would fix this permanently.

**Still unverified:** the template *matching*. Everything upstream now works — window
selection (by bundle id `com.Nicalis.…`, excluding this app, largest window),
off-Space capture, room geometry, permission preflight. But no scan has yet run against
a real pedestal, so the match quality is unknown. Type the item name instead; it feeds
the identical code path.

**Still to verify:** the stat numbers have not yet been checked against the in-game
HUD. Set `FoundHUD=1` in `options.ini`, play a run, and compare — that is what
promotes the remaining characters out of `unverified`.
