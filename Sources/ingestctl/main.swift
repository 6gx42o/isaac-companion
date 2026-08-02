import AppKit
import Foundation
import Ingest
import IsaacCore

// Dev CLI for the data pipeline. The app runs the same Ingest code in-process;
// this exists so a build can be driven and inspected from a terminal.

let args = Array(CommandLine.arguments.dropFirst())
let eidDir = DataPaths.eidDescriptions

func probe(_ target: String, in file: String) {
    guard let src = try? String(contentsOf: eidDir.appending(path: file), encoding: .utf8) else {
        print("  \(target): cannot read \(file)")
        return
    }
    var p = LuaLiteralParser(src)
    do {
        let t = try p.table(assignedTo: target)
        print("  OK   \(target): \(t.array.count) array, \(t.dict.count) keyed")
    } catch {
        print("  FAIL \(target): \(error)")
    }
}

func byteCount(_ n: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
}

switch args.first {
case "probe":
    print("probing EID tables at \(eidDir.path)")
    probe("EID.ItemData", in: "item_data.lua")
    probe("EID.descriptions[languageCode].collectibles", in: "en_us.lua")
    probe("EID.descriptions[languageCode].trinkets", in: "en_us.lua")
    probe("EID.EntityTransformations", in: "transformations.lua")

case "progress":
    guard let prog = SaveFile().readBest() else {
        print("no readable save found; looked at:")
        for u in SaveFile.candidatePaths() { print("  \(u.path)") }
        exit(1)
    }
    let (pb, _, _) = try Pipeline.load()
    let byID = Dictionary(pb.achievements.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    print("save:      \(prog.source.lastPathComponent)")
    print("unlocked:  \(prog.unlocked.count) of \(prog.total)")
    for id in prog.unlocked.sorted().prefix(6) {
        let a = byID[id]
        print("  \(id): \(a?.steamName ?? a?.announcement ?? "?") -- \(a?.displayCondition ?? "")")
    }
    let gatedLocked = pb.items.filter {
        guard let g = $0.achievement else { return false }
        return !prog.unlocked.contains(g)
    }
    print("items still locked for you: \(gatedLocked.count) of 262")

case "detect":
    let d = VersionDetector.detect()
    print("version:  \(d.version.displayName)  [\(d.version.rawValue)]")
    print("owned:    \(d.owned.map(\.displayName).joined(separator: ", "))")
    print("log:      \(VersionDetector.logFile(for: d.version).path)")
    print("          \(d.hasLog ? "present" : "MISSING -- launch the game once")")
    print("eid set:  descriptions/\(d.version.eidFolder)/")
    print("expects:  max id \(d.version.maxCollectibleID), \(d.version.expectedPoolCount) pools, "
        + "tear-delay floor \(d.version.floorsTearDelay ? "on" : "off")")
    print("why:      \(d.reason)")

case "extract":
    // Pools and sprites live only inside resources/packed/*.a. Extract, keep the
    // ~4 MB we need, throw the other ~570 MB away. Slow (~1 min), and the only way
    // to refresh sprites after changing what the harvest keeps. `--keep-raw` leaves
    // the full extraction behind when a game asset the harvest drops needs a look.
    let keepRaw = args.contains("--keep-raw")
    let extractor = Extractor(gameRoot: DataPaths.defaultGameRoot)
    try extractor.extractAndHarvest(keepRaw: keepRaw) { print("  \($0)") }
    if let raw = try? Data(contentsOf: Extractor.monsterArtIndex),
       let idx = try? JSONDecoder().decode([String: String].self, from: raw) {
        print("  monster art: \(idx.count) entities -> \(Set(idx.values).count) sheets")
    }
    print("harvested to \(Extractor.harvestDir.path)")

case "startingitems":
    // Base stats in Characters.swift must EXCLUDE anything a starting item grants,
    // because the log reports starting items as ordinary pickups. Anything printed
    // here with a permanent delta is a double-count risk.
    let (bundle, _, _) = try Pipeline.load()
    let byID = Dictionary(
        bundle.items.filter { $0.kind != .trinket }.map { ($0.id, $0) },
        uniquingKeysWith: { a, _ in a })
    let xml = try String(
        contentsOf: DataPaths.resourcesDir(gameRoot: DataPaths.defaultGameRoot)
            // resources.jp, NOT .kr: the Korean copy is Afterbirth-era and stops at 15
            // players, silently skipping Apollyon (15), The Forgotten (16) and The
            // Forgotten Soul (17) -- including Apollyon's starting Void.
            .appending(path: "resources.jp/players.xml"), encoding: .utf8)
    // Match the whole element first, then pull attributes out of it. The two copies of
    // this file order attributes differently (jp is alphabetical, so `id` is NOT first),
    // and an order-dependent pattern silently matches nothing.
    let elementRE = try NSRegularExpression(pattern: #"<player\b[^>]*/>"#)
    let attrRE = try NSRegularExpression(pattern: #"(\w+)="([^"]*)""#)
    let ns = xml as NSString
    for m in elementRE.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
        let element = ns.substring(with: m.range)
        var attrs: [String: String] = [:]
        let en = element as NSString
        for a in attrRE.matches(in: element, range: NSRange(location: 0, length: en.length)) {
            attrs[en.substring(with: a.range(at: 1))] = en.substring(with: a.range(at: 2))
        }
        guard let pid = attrs["id"].flatMap(Int.init) else { continue }
        let ids = (attrs["items"] ?? "").split(separator: ",").compactMap { Int($0) }
        let name = bundle.characters.first { $0.id == pid }?.name ?? "player \(pid)"
        for id in ids {
            guard let item = byID[id] else { continue }
            let permanent = !item.delta.isEmpty
            print("\(permanent ? "!! " : "   ")\(name) starts with \(item.name) (#\(id))"
                + (permanent ? "  PERMANENT DELTA -- must not also be in base stats" : ""))
        }
    }

case "build", nil:
    let noEID = args.contains("--no-eid")
    let pipeline = noEID
        ? Pipeline(eidDir: URL(fileURLWithPath: "/nonexistent/eid"))
        : Pipeline()
    if noEID { print("(simulating the EID mod being removed)") }
    let vendored = URL(fileURLWithPath: "Sources/IsaacCompanionApp/VendoredData/eid.abplus.json")
    do {
        let (items, pools, synergies, report) = try pipeline.build(vendoredEIDJSON: vendored)
        let bytes = try pipeline.write(items: items, pools: pools, synergies: synergies)
        print("built \(report.itemCount) collectibles, \(report.trinketCount) trinkets, "
            + "\(report.cardCount) cards, \(report.pillCount) pills")
        print("  with numeric stat data: \(report.withNumbers)")
        print("  item pools: \(report.poolCount)")
        print("  sources: \(report.sources)")
        print("  written: \(byteCount(bytes)) -> \(DataPaths.dataDir(.abplus).path)")
        for w in report.warnings { print("  warning: \(w)") }

        let gated = items.items.filter { $0.achievement != nil }
        let byAch = Dictionary(items.achievements.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let known = gated.filter { byAch[$0.achievement!]?.isKnown == true }
        print("  achievements: \(items.achievements.count) (\(items.achievements.filter(\.isKnown).count) with a stated condition)")
        print("  gated items: \(gated.count), of which \(known.count) have a known unlock condition")
        let bosses = items.entities.filter { $0.isBoss && $0.bossID != nil }
        print("  entities: \(items.entities.count) (\(bosses.count) boss rows, "
            + "\(Set(bosses.compactMap(\.bossID)).count) distinct bossIDs)")

        // Prove the round trip, so a bundle that cannot be read back never ships.
        let (reloaded, _, reloadedSyn) = try Pipeline.load()
        print("  reloaded \(reloaded.items.count) items, \(reloaded.characters.count) characters")

        var byConfidence: [String: Int] = [:]
        for item in reloaded.items { byConfidence[item.confidence.rawValue, default: 0] += 1 }
        print("  confidence: \(byConfidence.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        let claiming = reloaded.items.filter(\.claimsStatChange)
        let covered = claiming.filter { !$0.delta.isEmpty }
        print("  items declaring a stat change: \(claiming.count), of which \(covered.count) carry numbers")
    } catch let e as CanaryFailure {
        print(e.description)
        exit(1)
    } catch {
        print("build failed: \(error)")
        exit(1)
    }

case "run":
    // Replays the real log.txt through the exact parser -> reducer -> engine path the
    // app uses, so the whole chain can be verified without launching the UI.
    let (bundle, _, _) = try Pipeline.load()
    let byID = Dictionary(
        bundle.items.filter { $0.kind != .trinket }.map { ($0.id, $0) },
        uniquingKeysWith: { a, _ in a })
    let text = try String(contentsOf: DataPaths.logFile, encoding: .utf8)
    let events = LogParser().parse(lines: text)
    var reducer = RunReducer()
    let state = reducer.replay(events)
    let character = bundle.characters.first { $0.id == state.playerType }
        ?? Characters.resolve(state.playerType)
    let owned = state.items.compactMap { byID[$0.itemID] }
    let s = StatEngine.compute(character: character, items: owned)

    print("log:        \(DataPaths.logFile.path)")
    print("events:     \(events.count) parsed")
    print("seed:       \(state.seed ?? "—")")
    print("character:  \(character.name) (PlayerType \(state.playerType.map(String.init) ?? "?"))")
    if !character.unverified.isEmpty {
        print("            unverified base stats: \(character.unverified.joined(separator: ", "))")
    }
    print("floor:      \(state.stage) (type \(state.stageType))")
    print("room:       \(state.room)\(state.room.offersChoice ? "  <- offers a choice" : "")")
    print("pedestals:  \(state.pedestals.count)")
    print("items:      \(owned.map(\.name).joined(separator: ", "))")
    print("stats:")
    for (label, stat) in [
        ("damage", s.damage), ("tears", s.tears), ("delay", s.tearDelay),
        ("range", s.range), ("shotspeed", s.shotSpeed), ("speed", s.speed), ("luck", s.luck),
    ] {
        print(String(format: "  %-10@ %@%.2f", label as NSString, stat.approx ? "~" : "", stat.value))
    }
    print("  shots      \(s.shots)")

    let bestiary = Bestiary(bundle.entities)
    if !state.bossesDefeated.isEmpty {
        let named = state.bossesDefeated.map { bestiary.boss($0)?.name ?? "boss #\($0)" }
        print("bosses:     \(named.joined(separator: ", "))")
    }
    if let death = state.death {
        print("died to:    \(bestiary.describeDeath(death)) on floor \(death.stage)")
    }

    // Every death in the whole log, so the decode can be eyeballed against reality.
    var replayer = RunReducer()
    var seen: [String] = []
    var scratch = RunState()
    for e in events {
        replayer.apply(e, to: &scratch)
        if case .died(let by, let from) = e {
            seen.append(bestiary.describeDeath(
                DeathRecord(killedBy: by, spawnedBy: from, stage: scratch.stage)))
        }
    }
    if !seen.isEmpty {
        print("all deaths in this log (\(seen.count)):")
        for d in seen { print("  - \(d)") }
    }

case "gaps":
    // Items whose `cache` attribute claims a stat change but that carry no numbers.
    // Most are genuinely non-numeric (temporary, conditional, or weapon-replacing);
    // the rest are real data gaps. Both need saying out loud.
    let (items, _, _, _) = try Pipeline().build(validate: false)
    let gaps = items.items.filter { $0.claimsStatChange && $0.delta.isEmpty }
    print("\(gaps.count) items declare a stat cache flag with no numeric delta:\n")
    for item in gaps.sorted(by: { $0.id < $1.id }) {
        let text = item.text.replacingOccurrences(of: "#", with: " / ")
        print("\(item.id)\t[\(item.cache.joined(separator: ","))]\t\(item.name)")
        print("\t\(text.isEmpty ? "(no description)" : text)")
    }

case "sitedata":
    // Data for the public item index. Colour tags are measured off the sprite atlas,
    // because no text source says what an item LOOKS like -- and looks are how people
    // search when they cannot remember a name.
    let (sbundle, spools, _) = try Pipeline.load()
    guard let index = Pipeline.loadAtlasIndex(),
        let atlasData = try? Data(
            contentsOf: DataPaths.dataDir(.abplus).appending(path: "atlas.png")),
        let atlasImage = NSImage(data: atlasData),
        let atlasCG = atlasImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { print("no atlas; run `ingestctl build` first"); exit(1) }

    var frames: [String: (x: Int, y: Int)] = [:]
    var colorsByGfx: [String: [String]] = [:]
    for entry in index.entries {
        frames[entry.key.lowercased()] = (entry.x, entry.y)
        if let crop = atlasCG.cropping(
            to: CGRect(x: entry.x, y: entry.y, width: entry.w, height: entry.h)) {
            colorsByGfx[entry.key.lowercased()] = SpriteColors.names(for: crop)
        }
    }

    var weights: [Int: [String]] = [:]
    for pool in spools?.pools ?? [] {
        for e in pool.entries { weights[e.id, default: []].append(pool.name) }
    }

    struct SiteItem: Encodable {
        var id: Int; var name: String; var kind: String; var text: String
        var colors: [String]; var pools: [String]; var frame: [Int]?
        var confidence: String; var charges: Int?; var devil: Int?
        var unlock: String?; var unlockKnown: Bool
    }
    let achByID = Dictionary(sbundle.achievements.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let siteItems = sbundle.items.map { item -> SiteItem in
        let gate = item.achievement.flatMap { achByID[$0] }
        let key = item.gfx.lowercased()
        let f = frames[key]
        return SiteItem(
            id: item.id, name: item.name, kind: item.kind.rawValue,
            text: item.text, colors: colorsByGfx[key] ?? [],
            pools: item.kind.isAutoTracked ? (weights[item.id] ?? []) : [],
            frame: f.map { [$0.x, $0.y] },
            confidence: item.confidence.rawValue,
            charges: item.maxCharges, devil: item.devilPrice,
            unlock: gate?.displayCondition, unlockKnown: gate?.isKnown ?? false)
    }
    // Sheets go out as PNG here and are re-encoded to lossless WebP by build-site.py:
    // macOS can READ WebP but CGImageDestinationCopyTypeIdentifiers does not list it
    // as writable, so there is no ImageIO path for it. WebP matters because these two
    // sheets are 1.1 MB and 1.9 MB as RGBA PNG, and base64 inlining adds a third again.
    func sheet(_ name: String) -> (uri: String, index: Atlas.Index)? {
        let dir = DataPaths.dataDir(.abplus)
        guard let raw = try? Data(contentsOf: dir.appending(path: "\(name).index.json")),
              let idx = try? JSONDecoder().decode(Atlas.Index.self, from: raw),
              let png = try? Data(contentsOf: dir.appending(path: "\(name).png"))
        else { return nil }
        return ("data:image/png;base64," + png.base64EncodedString(), idx)
    }

    struct SiteSheet: Encodable {
        var uri: String; var width: Int; var height: Int; var cellW: Int; var cellH: Int
        /// Frames packed side by side inside one cell -- the enemy sheet holds a short
        /// idle loop, so the page steps through it rather than showing a still.
        var steps: Int
        var frames: [String: [Int]]
    }
    func siteSheet(_ name: String) -> SiteSheet? {
        guard let (uri, idx) = sheet(name) else { return nil }
        return SiteSheet(
            uri: uri, width: idx.width, height: idx.height,
            cellW: idx.cellW ?? idx.cell, cellH: idx.cellH ?? idx.cell,
            steps: max(1, idx.steps ?? 1),
            frames: Dictionary(
                idx.entries.map { ($0.key.lowercased(), [$0.x, $0.y]) },
                uniquingKeysWith: { a, _ in a }))
    }

    struct SiteEnemy: Encodable {
        var name: String; var type: Int; var variant: Int
        var hp: Double; var stageHP: Double
        var boss: Bool; var blocks: Bool; var fight: Bool
        var colors: [String]; var art: String?
    }
    // Same de-dupe the app uses: variants sharing a name collapse to the first.
    var seenEnemy = Set<String>()
    let siteEnemies = sbundle.entities.compactMap { e -> SiteEnemy? in
        guard seenEnemy.insert("\(e.name)|\(e.type)").inserted else { return nil }
        return SiteEnemy(
            name: e.name, type: e.type, variant: e.variant, hp: e.baseHP,
            stageHP: e.stageHP, boss: e.isBoss, blocks: e.blocksClear,
            fight: (10..<1000).contains(e.type), colors: e.colors, art: e.art)
    }.sorted { ($0.boss ? 0 : 1, $0.name) < ($1.boss ? 0 : 1, $1.name) }

    struct SiteAchievement: Encodable {
        var id: Int; var name: String; var condition: String
        var known: Bool; var gives: [String]; var gfx: String?
    }
    var gives: [Int: [String]] = [:]
    for item in sbundle.items {
        guard let a = item.achievement else { continue }
        gives[a, default: []].append(item.name)
    }
    // The announcement is 'You unlocked "X"'; the quoted part is the name.
    func tidy(_ text: String?) -> String? {
        guard let text else { return nil }
        guard let q = text.range(of: "\""), let q2 = text.range(of: "\"", options: .backwards),
              q.upperBound < q2.lowerBound else { return text }
        return String(text[q.upperBound..<q2.lowerBound])
    }
    let siteAchievements = sbundle.achievements.map { a in
        SiteAchievement(
            id: a.id,
            name: a.steamName ?? tidy(a.announcement) ?? "Achievement \(a.id)",
            condition: a.displayCondition, known: a.isKnown,
            gives: (gives[a.id] ?? []).sorted(), gfx: a.gfx?.lowercased())
    }

    struct SitePayload: Encodable {
        var atlas: String; var atlasWidth: Int; var atlasHeight: Int; var cell: Int
        var items: [SiteItem]
        var enemies: [SiteEnemy]
        var achievements: [SiteAchievement]
        var monsters: SiteSheet?
        var badges: SiteSheet?
        /// Every pill colour in one strip. Pills share an icon, so it is a lone sheet
        /// rather than an atlas entry, and the page cycles it. The frame count is
        /// measured off the image -- a row of square frames -- so the page never
        /// restates a number the harvest chose.
        var pills: SiteStrip?
    }
    struct SiteStrip: Encodable { var uri: String; var frames: Int }
    func siteStrip(_ name: String) -> SiteStrip? {
        let url = DataPaths.dataDir(.abplus).appending(path: "\(name).png")
        guard let png = try? Data(contentsOf: url),
              let img = NSImage(data: png)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil),
              img.height > 0, img.width % img.height == 0
        else { return nil }
        return SiteStrip(
            uri: "data:image/png;base64," + png.base64EncodedString(),
            frames: img.width / img.height)
    }
    let payload = SitePayload(
        atlas: "data:image/png;base64," + atlasData.base64EncodedString(),
        atlasWidth: index.width, atlasHeight: index.height, cell: index.cell,
        items: siteItems,
        enemies: siteEnemies, achievements: siteAchievements,
        monsters: siteSheet("monsters"), badges: siteSheet("achievements"),
        pills: siteStrip("pills"))
    let outURL = URL(fileURLWithPath: args.count > 1 ? args[1] : "site-data.json")
    let enc = JSONEncoder()
    try enc.encode(payload).write(to: outURL)
    let tagged = siteItems.filter { !$0.colors.isEmpty }.count
    print("wrote \(siteItems.count) items (\(tagged) with colour tags) -> \(outURL.path)")
    var vocab: [String: Int] = [:]
    for i in siteItems { for c in i.colors { vocab[c, default: 0] += 1 } }
    print("  colours: \(vocab.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
    print("  \(siteEnemies.filter(\.fight).count) enemies (of \(siteEnemies.count) entities), "
        + "\(siteAchievements.count) achievements")
    let bytes = (try? Data(contentsOf: outURL).count) ?? 0
    print("  payload \(bytes / 1024) KB")

case "vendor":
    // Freeze the EID data into the repo so the app stops depending on the mod
    // being installed -- the user needs to remove it to get achievements back.
    let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "VendoredData/eid.abplus.json")
    let result = try EIDIngest().load(descriptionsDirectory: eidDir)
    // The lattice lives in the mod's features/ folder and vanishes with it, so it is
    // frozen here too rather than being re-derived at runtime.
    let conditionals = eidDir.deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "features/eid_conditionals.lua")
    let synergies = try? SynergyIngest().load(
        conditionals: conditionals, descriptions: result.conditionalDescs,
        transformationAssignments: result.transformations,
        transformationNames: result.transformationNames)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(VendoredEID(result, synergies: synergies))
    try FileManager.default.createDirectory(
        at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: out)
    print(
        "vendored \(result.collectibles.count) collectibles, \(result.trinkets.count) trinkets, "
            + "\(result.cards.count) cards, \(result.pills.count) pills, "
            + "\(result.conditionalDescs.count) interaction texts, "
            + "\(synergies?.overrides.count ?? 0) override edges")
    if synergies == nil {
        print("  WARNING: no synergy lattice captured -- verdicts will be missing once "
            + "the mod is deleted.")
    }
    print("  -> \(out.path) (\(byteCount(data.count)))")

case "stats":
    // Quick sanity read of the built bundle against the in-game HUD.
    let (bundle, _, _) = try Pipeline.load()
    let ids = args.dropFirst().compactMap(Int.init)
    let items = ids.compactMap { id in bundle.items.first { $0.id == id && $0.kind != .trinket } }
    let character = bundle.characters.first { $0.id == 0 }!
    let s = StatEngine.compute(character: character, items: items)
    print("character: \(character.name), items: \(items.map(\.name).joined(separator: ", "))")
    func show(_ label: String, _ stat: Stat) {
        let mark = stat.approx ? "~" : " "
        print(String(format: "  %-10s %@%.2f", (label as NSString).utf8String!, mark, stat.value))
        if let r = stat.reason { print("             (\(r))") }
    }
    show("damage", s.damage)
    show("tears", s.tears)
    show("delay", s.tearDelay)
    show("range", s.range)
    show("shotspeed", s.shotSpeed)
    show("speed", s.speed)
    show("luck", s.luck)
    print("  shots      \(s.shots)")

default:
    print("usage: ingestctl [build|extract|probe|vendor [path]|stats <item ids...>]")
}
