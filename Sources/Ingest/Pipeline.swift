import CoreGraphics
import Foundation
import IsaacCore

/// Where the app keeps its built data. Deliberately outside the app bundle so the
/// storage setting can rebuild it and so game-derived assets stay on the machine
/// that owns the game.
public enum DataPaths {
    public static var root: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Application Support/IsaacCompanion")
    }
    public static func dataDir(_ version: GameVersion) -> URL {
        root.appending(path: "data").appending(path: version.dataDirectory)
    }
    public static var cacheDir: URL { root.appending(path: "cache") }

    /// Resolved from whichever release Steam says is installed, so the app follows
    /// the game rather than assuming Afterbirth+.
    public static var detected: GameVersion { VersionDetector.detect().version }

    /// ISAAC_LOG_PATH points the tailer somewhere else. Needed to exercise anything that
    /// depends on the *shape* of a log -- run transitions, replay, truncation -- without
    /// playing the game, and to reproduce a bug from someone else's log.
    public static var logFile: URL {
        if let override = ProcessInfo.processInfo.environment["ISAAC_LOG_PATH"] {
            return URL(fileURLWithPath: override)
        }
        return VersionDetector.logFile(for: detected)
    }

    /// Standard Steam location. The setup wizard lets the user pick if this misses.
    public static var defaultGameRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(
                path: "Library/Application Support/Steam/steamapps/common/The Binding of Isaac Rebirth")
    }

    public static func resourcesDir(gameRoot: URL) -> URL {
        gameRoot.appending(path: "The Binding of Isaac Rebirth.app/Contents/Resources")
    }

    /// The only unpacked items.xml. Japanese strings, but every attribute we take
    /// from it is language-independent.
    public static func unpackedItemsXML(gameRoot: URL) -> URL {
        resourcesDir(gameRoot: gameRoot).appending(path: "resources.jp/items.xml")
    }

    public static var eidDescriptions: URL { eidDescriptions(for: detected) }

    /// EID keeps a description set per era. Reading `rep/` for an Afterbirth+ run is
    /// precisely how wrong-but-plausible numbers get in.
    public static func eidDescriptions(for version: GameVersion) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Application Support/Binding of Isaac Afterbirth+ Mods")
            .appending(path: "external item descriptions_836319872/descriptions")
            .appending(path: version.eidFolder)
    }
}

/// Compact keeps nothing but the built bundles; Cached also keeps raw inputs so a
/// later rebuild does not have to re-extract. Both produce identical output --
/// the setting trades disk for rebuild speed, never features.
public enum StorageMode: String, Codable, Sendable, CaseIterable {
    case compact, cached
    public var explanation: String {
        switch self {
        case .compact:
            "~5 MB total. Discards the 570 MB extraction as soon as the sprites and "
                + "item pools have been harvested from it."
        case .cached:
            "~575 MB. Also keeps the raw extraction, so a rebuild skips the "
                + "one-minute extract step."
        }
    }
}

public struct BuildReport: Sendable {
    public var itemCount: Int
    public var trinketCount: Int
    public var cardCount: Int
    public var pillCount: Int
    public var poolCount: Int
    public var withNumbers: Int
    public var sources: [String: String]
    public var warnings: [String]
    public var bytesWritten: Int
}

/// (kind, id) key — consumable ids collide across kinds, as everywhere else here.
struct Pair2: Hashable {
    let kind: ItemKind
    let id: Int
    init(_ k: ItemKind, _ i: Int) { kind = k; id = i }
}

public struct Pipeline: Sendable {
    public var gameRoot: URL
    public var eidDir: URL
    public var mode: StorageMode

    public init(
        gameRoot: URL = DataPaths.defaultGameRoot,
        eidDir: URL = DataPaths.eidDescriptions,
        mode: StorageMode = .compact
    ) {
        self.gameRoot = gameRoot
        self.eidDir = eidDir
        self.mode = mode
    }

    /// Vendored copy, used when the EID mod has been unsubscribed. Built data must
    /// never require the mod to be installed -- enabling mods turns achievements off,
    /// so the whole point is that the user can delete them.
    public static func vendoredEID(in bundleResources: URL?) -> URL? {
        bundleResources?.appending(path: "eid.abplus.json")
    }

    public func build(vendoredEIDJSON: URL? = nil, validate: Bool = true) throws -> (
        ItemBundle, PoolBundle?, SynergyBundle?, BuildReport
    ) {
        var sources: [String: String] = [:]
        var warnings: [String] = []

        // The extracted items.xml is English and canonical; the unpacked Japanese one
        // is the fallback when the extractor has not been run (its ids, gfx names and
        // cache flags are identical -- only the strings differ).
        let extractedItems = Extractor.itemsXML
        let usingExtracted = FileManager.default.fileExists(atPath: extractedItems.path)
        let xmlURL = usingExtracted ? extractedItems : DataPaths.unpackedItemsXML(gameRoot: gameRoot)
        guard FileManager.default.fileExists(atPath: xmlURL.path) else {
            throw NSError(
                domain: "IsaacCompanion", code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not find the game's items.xml at \(xmlURL.path). "
                        + "Point setup at your Binding of Isaac Rebirth folder."
                ])
        }
        let rows = try ItemsXML().parse(contentsOf: xmlURL)
        sources["items"] = usingExtracted ? "extracted/resources/items.xml" : "resources.jp/items.xml"

        let eid: EIDIngest.Result
        var vendoredSynergies: SynergyBundle?
        if FileManager.default.fileExists(atPath: eidDir.appending(path: "en_us.lua").path) {
            eid = try EIDIngest().load(descriptionsDirectory: eidDir)
            sources["eid"] = "live mod folder"
        } else if let vendoredEIDJSON,
            let data = try? Data(contentsOf: vendoredEIDJSON),
            let decoded = try? JSONDecoder().decode(VendoredEID.self, from: data) {
            eid = decoded.asResult()
            vendoredSynergies = decoded.synergies
            sources["eid"] = "vendored"
            warnings.append("EID mod folder not found; using the vendored copy.")
            // Loudly, because a stale snapshot silently drops features rather than
            // failing, and the user only notices much later.
            let gaps = decoded.gaps
            if !gaps.isEmpty {
                warnings.append(
                    "The vendored copy is out of date and is missing "
                        + gaps.joined(separator: ", ")
                        + ". Re-run `ingestctl vendor` while the mod is still installed.")
            }
        } else {
            throw NSError(
                domain: "IsaacCompanion", code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "No item description data available (EID folder missing and no "
                        + "vendored copy present)."
                ])
        }

        // Pools only exist inside the packed archives, so they appear once the user
        // has run the extractor. Everything else works without it.
        var poolBundle: PoolBundle?
        let poolsURL = Extractor.itemPoolsXML
        if FileManager.default.fileExists(atPath: poolsURL.path),
            let pools = try? ItemPoolsXML().parse(contentsOf: poolsURL) {
            poolBundle = PoolBundle(pools: pools)
            sources["pools"] = "extracted/resources/itempools.xml"
        } else {
            warnings.append(
                "Item pools not built yet -- they live inside the packed archives and "
                + "need the game's ResourceExtractor. Everything else works without them.")
        }

        var poolMembership: [Int: [String]] = [:]
        for pool in poolBundle?.pools ?? [] {
            for entry in pool.entries { poolMembership[entry.id, default: []].append(pool.name) }
        }

        var items: [Item] = []
        for row in rows {
            let entry = row.kind == .trinket ? eid.trinkets[row.id] : eid.collectibles[row.id]
            let text = entry?.text ?? ""
            let typed = entry?.delta ?? ItemDelta()
            let fromText = TextDelta.parse(text)

            // Two independent readings of the same item. Where they agree the number
            // is trustworthy; where only one exists it is used but marked; where they
            // disagree the build says so rather than silently picking one.
            var delta = typed
            var confidence: Confidence
            switch (typed.isEmpty, fromText) {
            case (false, .some(let t)):
                let conflicts = TextDelta.disagreements(typed, t)
                if conflicts.isEmpty {
                    confidence = .verified
                } else {
                    confidence = .crossChecked
                    warnings.append(
                        "item \(row.id) (\(entry?.name ?? "?")): EID data and text disagree on "
                            + conflicts.joined(separator: "; ") + " -- using the typed data")
                }
                // The text is the only place multishot and range multipliers appear.
                delta.shots = delta.shots ?? t.shots
                delta.rangeMultiplier = delta.rangeMultiplier ?? t.rangeMultiplier
            case (false, .none):
                confidence = .crossChecked
            case (true, .some(let t)):
                delta = t                       // prose-only numbers, e.g. Cancer's -2 tear delay
                confidence = .singleSource
            case (true, .none):
                confidence =
                    row.cache.contains(where: Item.statCacheFlags.contains)
                    ? (TextDelta.isConditional(text) ? .conditional : .nonNumeric)
                    : .nonNumeric
            }

            // Multishot means "Isaac fires more tears per shot", which only a PASSIVE
            // can grant. Actives that fire a burst on use (Tammy's Head, Isaac's Tears)
            // and familiars that shoot their own tears (Lil Loki) match the prose but
            // must not raise the run's shot count. This has to run AFTER the merge
            // above: both `delta.shots ?? t.shots` and the prose-only `delta = t`
            // branch would otherwise put it straight back.
            if row.kind != .passive { delta.shots = nil }

            items.append(
                Item(
                    id: row.id,
                    name: entry?.name ?? "Item \(row.id)",
                    kind: row.kind,
                    gfx: row.gfx,
                    cache: row.cache,
                    special: row.special,
                    maxCharges: row.maxCharges,
                    devilPrice: row.devilPrice,
                    // itempools.xml lists COLLECTIBLES only, and trinket ids collide
                    // with collectible ids -- so a trinket reading this table inherits
                    // a completely unrelated item's pools.
                    pools: row.kind.isAutoTracked ? (poolMembership[row.id] ?? []) : [],
                    delta: delta,
                    text: text,
                    confidence: confidence,
                    slots: SlotGrants.parse(text: text),
                    achievement: row.achievement))
        }

        // Unlock conditions. Optional: they only exist once the extractor has run,
        // and everything else works without them.
        var achievements: [Achievement] = []
        if FileManager.default.fileExists(atPath: Extractor.achievementsXML.path),
            let parsed = try? AchievementsXML().parse(contentsOf: Extractor.achievementsXML) {
            achievements = parsed
            sources["achievements"] = "extracted/resources/achievements.xml"
        }
        var entities: [EntityInfo] = []
        if FileManager.default.fileExists(atPath: Extractor.entitiesXML.path),
            let parsed = try? EntitiesXML().parse(contentsOf: Extractor.entitiesXML) {
            entities = parsed
            sources["entities"] = "extracted/resources/entities2.xml"
        }
        var consumableGates: [Pair2: Int] = [:]
        if FileManager.default.fileExists(atPath: Extractor.pocketItemsXML.path),
            let gates = try? PocketItemsXML().parse(contentsOf: Extractor.pocketItemsXML) {
            for g in gates { consumableGates[Pair2(g.kind, g.id)] = g.achievement }
        }

        // Cards and pills come only from EID -- items.xml does not list them, and they
        // have no pool membership.
        //
        // They DO change stats, which this used to assert they did not. Eight pills move
        // a stat permanently -- Range, Speed, Tears and Luck, up and down -- and state
        // the number in their own text ("+0.15 Speed", "-2 Range"). Hardcoding an empty
        // delta meant a Speed Up pill changed nothing even when entered by hand, so the
        // run's numbers drifted from the game's with no warning.
        //
        // TextDelta is the same reader the collectibles use, including its refusal to
        // extract from conditional prose -- so a card whose effect lasts "for the room"
        // still yields nothing, which is correct.
        for (kind, entries) in [(ItemKind.card, eid.cards), (ItemKind.pill, eid.pills)] {
            for entry in entries.values.sorted(by: { $0.id < $1.id }) {
                let fromText = TextDelta.parse(entry.text)
                items.append(
                    Item(
                        id: entry.id, name: entry.name, kind: kind,
                        // Sliced out of the HUD card sheet by the harvest; pills share
                        // one icon because the game randomises pill colours per run.
                        gfx: kind == .card ? "card_\(entry.id).png" : "pill.png",
                        cache: [], special: false, maxCharges: nil, devilPrice: nil,
                        pools: [], delta: fromText ?? ItemDelta(), text: entry.text,
                        // Prose is the only source for these, so they never grade better
                        // than single-source -- as Cancer's -2 tear delay does.
                        confidence: fromText == nil
                            ? (TextDelta.isConditional(entry.text) ? .conditional : .nonNumeric)
                            : .singleSource,
                        achievement: consumableGates[Pair2(kind, entry.id)]))
            }
        }

        // The harvest already resolved every entity to its sheet (entity -> anm2 ->
        // Spritesheet), so this is a straight lookup rather than a guess. Colours are
        // measured off the pixels the same way the item index does it, because nothing
        // in the XML says what a monster looks like -- that is what makes searching by
        // description work.
        if let raw = try? Data(contentsOf: Extractor.monsterArtIndex),
           let artByRef = try? JSONDecoder().decode([String: String].self, from: raw) {
            var colors: [String: [String]] = [:]
            for key in Set(artByRef.values) {
                guard let img = IconAtlas.load(Extractor.monsterArtDir.appending(path: key))
                else { continue }
                // Sample the first frame only: the whole strip would average the sprite
                // with its own motion and wash the colours out.
                let one = img.cropping(to: CGRect(
                    x: 0, y: 0, width: img.width / Extractor.monsterFrames,
                    height: img.height)) ?? img
                colors[key] = SpriteColors.names(for: one)
            }
            entities = entities.map { e in
                var e = e
                if let art = artByRef["\(e.type).\(e.variant)"] {
                    e.art = art
                    e.colors = colors[art] ?? []
                }
                return e
            }
        }

        // Item sprite colours, measured once here rather than at every app launch --
        // cropping 674 sprites off the atlas takes seconds, which is fine in a build
        // and far too slow on the way to a first paint.
        var itemColors: [String: [String]] = [:]
        if let files = try? FileManager.default.contentsOfDirectory(
            atPath: Extractor.spritesDir.path) {
            for name in files where name.hasSuffix(".png") {
                guard let img = IconAtlas.load(Extractor.spritesDir.appending(path: name))
                else { continue }
                itemColors[name.lowercased()] = SpriteColors.names(for: img)
            }
        }
        items = items.map { item in
            var item = item
            item.colors = itemColors[item.gfx.lowercased()] ?? []
            return item
        }

        let bundle = ItemBundle(
            achievements: achievements, entities: entities, sources: sources, items: items,
            characters: Characters.all)

        // The weapon-override lattice lives in the EID mod's conditionals file, which
        // is code rather than data -- so it is only available when the mod folder is
        // present. Absent it, the app still works; it just has no cross-item verdicts.
        var synergyBundle: SynergyBundle?
        let conditionals = eidDir.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "features/eid_conditionals.lua")
        if FileManager.default.fileExists(atPath: conditionals.path) {
            do {
                synergyBundle = try SynergyIngest().load(
                    conditionals: conditionals,
                    descriptions: eid.conditionalDescs,
                    transformationAssignments: eid.transformations,
                    transformationNames: eid.transformationNames)
                sources["synergies"] = "eid_conditionals.lua"
            } catch {
                warnings.append("Could not read the synergy lattice: \(error.localizedDescription)")
            }
        } else if let vendoredSynergies {
            synergyBundle = vendoredSynergies
            sources["synergies"] = "vendored"
        } else {
            warnings.append(
                "Synergy lattice unavailable (EID's eid_conditionals.lua not found and "
                    + "none vendored); override and interaction verdicts will be missing.")
        }

        if validate {
            try Canaries.validate(items: bundle, pools: poolBundle, synergies: synergyBundle)
        }

        let report = BuildReport(
            itemCount: items.filter { $0.kind.isAutoTracked }.count,
            trinketCount: items.filter { $0.kind == .trinket }.count,
            cardCount: items.filter { $0.kind == .card }.count,
            pillCount: items.filter { $0.kind == .pill }.count,
            poolCount: poolBundle?.pools.count ?? 0,
            withNumbers: items.filter { !$0.delta.isEmpty }.count,
            sources: sources, warnings: warnings, bytesWritten: 0)
        return (bundle, poolBundle, synergyBundle, report)
    }

    /// Writes gzip-compressed JSON into a temp directory and swaps it in atomically,
    /// so quitting mid-rebuild cannot leave a half-written data set behind.
    @discardableResult
    public func write(
        items: ItemBundle, pools: PoolBundle?, synergies: SynergyBundle? = nil,
        to dir: URL = DataPaths.dataDir(.abplus)
    ) throws -> Int {
        let fm = FileManager.default
        let staging = dir.deletingLastPathComponent()
            .appending(path: dir.lastPathComponent + ".tmp")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        var written = 0
        func emit(_ value: some Encodable, _ name: String) throws {
            let data = try encoder.encode(value)
            let gz = try Gzip.compress(data)
            try gz.write(to: staging.appending(path: name))
            written += gz.count
        }
        try emit(items, "items.json.gz")
        if let pools { try emit(pools, "pools.json.gz") }
        if let synergies { try emit(synergies, "synergies.json.gz") }

        // Achievement badges, keyed by the `gfx` attribute in achievements.xml.
        if let files = try? FileManager.default.contentsOfDirectory(
            atPath: Extractor.achievementIconsDir.path) {
            // frame.png and bgblack.png are the popup's border and backing swatch,
            // not badges; they are the only two files that are not 263x176.
            let chrome: Set<String> = ["frame.png", "bgblack.png"]
            let imgs = files
                .filter { $0.hasSuffix(".png") && !chrome.contains($0.lowercased()) }
                .compactMap { name -> (String, CGImage)? in
                    IconAtlas.load(Extractor.achievementIconsDir.appending(path: name))
                        .map { (name.lowercased(), $0) }
                }
            // Badges are 263x176 hand-drawn cards. Packing them into a 64x64 square
            // squashed them 33% horizontally and threw away 91% of their pixels,
            // which is why the lettering was illegible. Store them at native size.
            if let (png, index) = IconAtlas.build(imgs, cell: 263, cellW: 263, cellH: 176) {
                try png.write(to: staging.appending(path: "achievements.png"))
                let d = try encoder.encode(index)
                try d.write(to: staging.appending(path: "achievements.index.json"))
                written += png.count + d.count
            }
        }

        // Enemy icons: a short idle strip per animation sheet. File names are
        // `TYPE.VARIANT_name.png`, which is the join key back to entities2.xml.
        if let files = try? FileManager.default.contentsOfDirectory(
            atPath: Extractor.monsterArtDir.path) {
            let imgs = files.filter { $0.hasSuffix(".png") }.compactMap { name -> (String, CGImage)? in
                IconAtlas.load(Extractor.monsterArtDir.appending(path: name))
                    .map { (name.lowercased(), $0) }
            }
            // Each cell holds the idle strip -- 64px boxes side by side -- so a sprite
            // can play its idle instead of standing still. 64 rather than 128 because
            // the sheet is now three times as wide; pixel art upscales cleanly anyway.
            let n = Extractor.monsterFrames
            if let (png, index) = IconAtlas.build(
                imgs, cell: 64, cellW: 64 * n, cellH: 64, steps: n) {
                try png.write(to: staging.appending(path: "monsters.png"))
                let d = try encoder.encode(index)
                try d.write(to: staging.appending(path: "monsters.index.json"))
                written += png.count + d.count
            }
        }

        // Every pill colour the game deals, as one strip. Pills all share an icon --
        // the game reshuffles which colour carries which effect each run -- so rather
        // than pick one arbitrarily the icon cycles through the lot.
        if let strip = try? Data(contentsOf: Extractor.pillStrip) {
            try strip.write(to: staging.appending(path: "pills.png"))
            written += strip.count
        }

        // The three rune stones the HUD draws, so the pocket reader can recognise "a
        // rune" without pretending to know which.
        if let runes = try? Data(contentsOf: Extractor.hudRunes) {
            try runes.write(to: staging.appending(path: "runes_hud.png"))
            written += runes.count
        }

        // The stat HUD's icons, verbatim. Sixteen-pixel cells, so no atlas index is
        // needed -- the layout is fixed by the game's own hudstats.anm2.
        if let hud = try? Data(contentsOf: Extractor.hudStats) {
            try hud.write(to: staging.appending(path: "hudstats.png"))
            written += hud.count
        }

        // One sprite sheet instead of ~680 tiny PNGs.
        if let (png, index) = buildAtlas(for: items) {
            try png.write(to: staging.appending(path: "atlas.png"))
            let indexData = try encoder.encode(index)
            try indexData.write(to: staging.appending(path: "atlas.index.json"))
            written += png.count + indexData.count
        }

        let backup = dir.deletingLastPathComponent()
            .appending(path: dir.lastPathComponent + ".old")
        try? fm.removeItem(at: backup)
        try fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)

        let hadExisting = fm.fileExists(atPath: dir.path)
        if hadExisting { try fm.moveItem(at: dir, to: backup) }
        do {
            try fm.moveItem(at: staging, to: dir)
        } catch {
            // Put the previous data back rather than leaving no data at all, which
            // would drop the app into first-run setup on next launch.
            if hadExisting { try? fm.moveItem(at: backup, to: dir) }
            throw error
        }
        try? fm.removeItem(at: backup)
        return written
    }

    /// Matches items to harvested sprite files. The extractor lowercases filenames
    /// while items.xml refers to them in mixed case, so the join is case-insensitive.
    private func buildAtlas(for bundle: ItemBundle) -> (png: Data, index: Atlas.Index)? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: Extractor.spritesDir.path),
            !files.isEmpty
        else { return nil }
        let byLowercasedName = Dictionary(
            files.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })

        var sprites: [(key: String, url: URL)] = []
        for item in bundle.items where !item.gfx.isEmpty {
            guard let file = byLowercasedName[item.gfx.lowercased()] else { continue }
            sprites.append((item.gfx, Extractor.spritesDir.appending(path: file)))
        }
        return Atlas.build(sprites: sprites)
    }

    public static func loadAtlasIndex(from dir: URL = DataPaths.dataDir(.abplus))
        -> Atlas.Index?
    {
        guard let data = try? Data(contentsOf: dir.appending(path: "atlas.index.json"))
        else { return nil }
        return try? JSONDecoder().decode(Atlas.Index.self, from: data)
    }

    public static func load(from dir: URL = DataPaths.dataDir(.abplus)) throws -> (
        ItemBundle, PoolBundle?, SynergyBundle?
    ) {
        let decoder = JSONDecoder()
        let itemData = try Gzip.decompress(Data(contentsOf: dir.appending(path: "items.json.gz")))
        let items = try decoder.decode(ItemBundle.self, from: itemData)
        func optional<T: Decodable>(_ name: String, _ type: T.Type) -> T? {
            guard let raw = try? Data(contentsOf: dir.appending(path: name)),
                  let decompressed = try? Gzip.decompress(raw) else { return nil }
            return try? decoder.decode(type, from: decompressed)
        }
        return (
            items, optional("pools.json.gz", PoolBundle.self),
            optional("synergies.json.gz", SynergyBundle.self)
        )
    }
}

/// Serialisable form of the EID ingest, so the app can ship a copy and stop
/// depending on the mod being installed.
/// The EID data frozen into the app bundle.
///
/// This is what the app runs on once the user deletes the mods — which they must, since
/// any enabled mod turns Steam achievements off. So it has to carry EVERYTHING the live
/// path produces, including the synergy lattice, which is parsed from the mod's
/// `eid_conditionals.lua` and has no other source.
///
/// Every field added after the first release is **optional**. A snapshot written by an
/// older build must still decode: making a new field non-optional turns a stale
/// snapshot into a hard decode failure, which is exactly how this broke once already
/// (adding `cards`/`pills` made the whole mods-deleted path fail with "no data
/// available"). Missing means empty, never fatal.
public struct VendoredEID: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var id: Int
        public var name: String
        public var text: String
        public var delta: ItemDelta
    }
    public var collectibles: [Entry]
    public var trinkets: [Entry]
    public var transformations: [String: [String]]
    public var cards: [Entry]?
    public var pills: [Entry]?
    public var conditionalDescs: [String: String]?
    public var transformationNames: [String]?
    /// The parsed override/synergy lattice. Vendored because its source file lives
    /// inside the mod folder and disappears with it.
    public var synergies: SynergyBundle?

    public init(_ r: EIDIngest.Result, synergies: SynergyBundle? = nil) {
        func map(_ d: [Int: EIDIngest.Entry]) -> [Entry] {
            d.values.map { Entry(id: $0.id, name: $0.name, text: $0.text, delta: $0.delta) }
                .sorted { $0.id < $1.id }
        }
        collectibles = map(r.collectibles)
        trinkets = map(r.trinkets)
        cards = map(r.cards)
        pills = map(r.pills)
        conditionalDescs = r.conditionalDescs
        transformationNames = r.transformationNames
        transformations = Dictionary(
            uniqueKeysWithValues: r.transformations.map { (String($0.key), $0.value) })
        self.synergies = synergies
    }

    public func asResult() -> EIDIngest.Result {
        var out = EIDIngest.Result()
        func absorb(_ entries: [Entry]?, into dict: inout [Int: EIDIngest.Entry]) {
            for e in entries ?? [] {
                dict[e.id] = .init(id: e.id, name: e.name, text: e.text, delta: e.delta)
            }
        }
        absorb(collectibles, into: &out.collectibles)
        absorb(trinkets, into: &out.trinkets)
        absorb(cards, into: &out.cards)
        absorb(pills, into: &out.pills)
        out.conditionalDescs = conditionalDescs ?? [:]
        out.transformationNames = transformationNames ?? []
        for (k, v) in transformations { if let id = Int(k) { out.transformations[id] = v } }
        return out
    }

    /// What this snapshot cannot supply, for the build report. Silence here would let
    /// the app quietly lose features the moment the mods come out.
    public var gaps: [String] {
        var missing: [String] = []
        if (cards ?? []).isEmpty { missing.append("cards") }
        if (pills ?? []).isEmpty { missing.append("pills") }
        if (conditionalDescs ?? [:]).isEmpty { missing.append("synergy descriptions") }
        if synergies == nil { missing.append("the weapon-override lattice") }
        return missing
    }
}
