# VendoredData

This directory is empty in the repository on purpose, and this file exists to keep it
that way — `Package.swift` declares it as a resource (`.copy("VendoredData")`), and git
does not store empty directories, so without this file a fresh clone fails to build with:

```
error: couldn't build … because of missing inputs: …/Sources/IsaacCompanionApp/VendoredData
```

## What belongs here

`eid.abplus.json` — a snapshot of the [External Item Descriptions][eid] mod's own
description text, stat deltas and conditional lattice, frozen so the app keeps working
after you delete the mod.

Deleting the mod is the point. Enabling any Workshop mod in Afterbirth+ turns Steam
achievements off, and this app exists so you can track a run without that trade. The
snapshot is read once at data-build time; nothing needs the mod at runtime.

## Why it isn't committed

EID ships without a licence, so it is not ours to put in a public repository. It is
listed in `.gitignore`, and the app builds it from **your own** EID install instead:

```bash
swift run ingestctl vendor
```

Run that once while the mod is still installed, then remove the mod.

## If you skip this

Everything still builds and runs. `Pipeline.build(vendoredEIDJSON:)` takes an optional
URL, and with neither the mod folder nor a snapshot present it reports that no
description data is available rather than failing the build. You lose item descriptions
and the weapon-override verdicts; stats, pools, sprites and the browser are unaffected,
since those come from the game's own files.

[eid]: https://steamcommunity.com/sharedfiles/filedetails/?id=836319872
