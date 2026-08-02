import Testing
import Foundation
@testable import Ingest
@testable import IsaacCore

/// Regressions for bugs found by the adversarial review pass. Each one was confirmed
/// reachable through the shipped UI before being fixed.
private let loaded: (ItemBundle, PoolBundle?, SynergyBundle?)? = try? Pipeline.load()

@Suite(.enabled(if: loaded?.2 != nil, "no synergy bundle"))
struct OverrideVerdictRegressions {
    let bundle = loaded!.0
    let syn = loaded!.2!
    var engine: SynergyEngine { SynergyEngine(bundle: syn) }
    private func item(_ id: Int) -> Item {
        bundle.items.first { $0.id == id && $0.kind.isAutoTracked }!
    }

    @Test("Explicit edge losers get an overridden verdict even without a layer")
    func nonReplacerLosersWarn() {
        // Was: `.overridden` came only from `layers`, so 144 of 147 edges were silent.
        // Cursed Eye has no layer of its own but IS listed as a loser to Brimstone.
        let v = engine.verdicts(for: item(316), held: [item(118)])
        guard case .overridden(let by, _, _)? = v.first(where: {
            if case .overridden = $0 { return true } else { return false }
        }) else {
            Issue.record("Cursed Eye + Brimstone produced no overridden verdict: \(v)")
            return
        }
        #expect(by == 118)
    }

    @Test("Every explicit override edge warns its loser")
    func allEdgesWarn() {
        var silent: [Int] = []
        for edge in syn.overrides {
            guard let loser = bundle.items.first(where: { $0.id == edge.loser && $0.kind.isAutoTracked }),
                  let winner = bundle.items.first(where: { $0.id == edge.winner && $0.kind.isAutoTracked })
            else { continue }
            let v = engine.verdicts(for: loser, held: [winner])
            if !v.contains(where: { if case .overridden = $0 { true } else { false } }) {
                silent.append(edge.loser)
            }
        }
        #expect(silent.isEmpty, "\(silent.count) edges still silent: \(Set(silent).sorted().prefix(10))")
    }

    @Test("Layer precedence still decides replacer-vs-replacer, in one direction only")
    func layerPrecedenceIntact() {
        let loses = engine.verdicts(for: item(68), held: [item(118)])   // Technology + Brimstone
        #expect(loses.contains { if case .overridden(let by, _, _) = $0 { by == 118 } else { false } })
        let wins = engine.verdicts(for: item(118), held: [item(68)])
        #expect(!wins.contains { if case .overridden = $0 { true } else { false } })
        #expect(wins.contains { if case .overrides = $0 { true } else { false } })
    }
}

@Suite(.enabled(if: loaded != nil, "no bundle"))
struct IngestRegressions {
    let bundle = loaded!.0

    @Test("Multishot is not inflated by burst-fire prose")
    func multishotGated() {
        // Was: the "shoots N tears" regex matched actives and familiars that fire a
        // burst on use, so their one-off shots were added to the run's shot count.
        // Only passives can raise Isaac's shot count. Actives fire a burst on use and
        // familiars shoot their own tears; both match the prose but neither changes
        // what Isaac fires.
        let bogus = bundle.items.filter { $0.delta.shots != nil && $0.kind != .passive }
        #expect(bogus.isEmpty, "non-passive items carry shots: \(bogus.map(\.name))")

        // The genuine permanent multishot items must survive the gate.
        for id in [2, 153, 245] {   // Inner Eye, Mutant Spider, 20/20
            let item = bundle.items.first { $0.id == id && $0.kind.isAutoTracked }
            #expect((item?.delta.shots ?? 0) > 0, "\(item?.name ?? "#\(id)") lost its multishot")
        }
    }

    @Test("Cards and pills do not inherit a collectible's item pools")
    func noPoolBleed() {
        // Pool membership is keyed by collectible id, and ids collide across kinds.
        for item in bundle.items where !item.kind.isAutoTracked {
            #expect(item.pools.isEmpty, "\(item.kind.rawValue) \(item.name) has pools")
        }
    }

    @Test("Named synergies are deduplicated")
    func namedDeduped() {
        guard let syn = loaded!.2 else { return }
        var seen = Set<String>()
        var dupes = 0
        for n in syn.named {
            let key = "\(min(n.a, n.b))-\(max(n.a, n.b))-\(n.key)"
            if !seen.insert(key).inserted { dupes += 1 }
        }
        #expect(dupes == 0, "\(dupes) duplicate named synergies")
    }
}

@Suite("Log parser regressions")
struct LogParserRegressions {

    @Test("Curses parse with or without a trailing exclamation mark")
    func curseWithoutBang() {
        // The real AB+ log writes most curses with no punctuation; requiring "!"
        // silently dropped 2 of the 3 curses in the user's own log.
        #expect(LogParser().parse(line: "[INFO] - Curse of Blind") == .curse("Curse of Blind"))
        #expect(LogParser().parse(line: "[INFO] - Curse of Darkness!") == .curse("Curse of Darkness"))
        #expect(LogParser().parse(line: "[INFO] - Curse of the Maze") == .curse("Curse of the Maze"))
        // Still must not swallow unrelated prose that merely starts the same way.
        #expect(LogParser().parse(line: "[INFO] - Curse of Blind was removed by 42") == nil)
    }
}

@Suite("Pedestal geometry")
struct PedestalGeometryRegressions {

    @Test("Shop items sit a full tile below collectibles")
    func shopItemsAreLower() {
        // Measured from 77 collectible and 56 shop-item spawns in a real log:
        // collectibles land at y=280, shop items at y=320. The old fallback used 280
        // everywhere, and RoomScanner only crops about +/-30 units — so the scanner
        // was matching against empty floor and could still name something.
        #expect(RoomType.treasure.likelyPedestals.allSatisfy { $0.y == 280 })
        #expect(RoomType.shop.likelyPedestals.allSatisfy { $0.y == 320 })
        #expect(RoomType.devil.likelyPedestals.allSatisfy { $0.y == 320 })
        #expect(RoomType.angel.likelyPedestals.allSatisfy { $0.y == 320 })
        // Every observed x must be covered.
        let shopX = Set(RoomType.shop.likelyPedestals.map(\.x))
        #expect(shopX.isSuperset(of: [240, 280, 320, 360, 400]))
        #expect(Set(RoomType.devil.likelyPedestals.map(\.x)).isSuperset(of: [240, 320, 400]))
    }

    @Test("Shop-item slots are parsed as pedestals")
    func shopSlotsParse() {
        // Variant 150 is a purchasable slot. Before this the parser only knew Variant
        // 100, so a shop or devil room reported zero pedestals.
        let shop = LogParser().parse(
            line: "[INFO] - Spawn Entity with Type(5), Variant(150), Pos(240.00,320.00)")
        #expect(shop == .pedestalSpawned(x: 240, y: 320))
        let collectible = LogParser().parse(
            line: "[INFO] - Spawn Entity with Type(5), Variant(100), Pos(320.00,280.00)")
        #expect(collectible == .pedestalSpawned(x: 320, y: 280))
        // Other pickups must NOT be read as pedestals: 20 is a coin, 10 a heart.
        for variant in [0, 10, 20, 30, 40, 50, 300, 350] {
            #expect(
                LogParser().parse(
                    line: "[INFO] - Spawn Entity with Type(5), Variant(\(variant)), Pos(1,2)") == nil,
                "variant \(variant) must not be a pedestal")
        }
    }
}

private let entityBundle: ItemBundle? = try? Pipeline.load().0

@Suite(.enabled(if: (entityBundle?.entities.count ?? 0) > 0, "no entities built"))
struct BestiaryTests {
    let bundle = entityBundle!
    var bestiary: Bestiary { Bestiary(bundle.entities) }

    @Test("entities2.xml parses despite non-self-closing tags")
    func parses() {
        // Each <entity> wraps a <gibs/> child, so a `/>` pattern finds nothing.
        #expect(bundle.entities.count == 763)
        #expect(bundle.entities.filter(\.isBoss).count > 80)
    }

    @Test("A death decodes to names")
    func deaths() {
        // Straight from the real log: "Killed by (9.0) spawned by (20.0)".
        let d = DeathRecord(
            killedBy: EntityRef(type: 9, variant: 0),
            spawnedBy: EntityRef(type: 20, variant: 0), stage: 3)
        #expect(bestiary.describeDeath(d) == "Projectile, from Monstro")

        // A null killer is a real answer, not missing data.
        let env = DeathRecord(killedBy: EntityRef(type: 0, variant: 0), spawnedBy: nil, stage: 1)
        #expect(bestiary.describeDeath(env).contains("no attributable source"))
    }

    @Test("bossID resolves to the parent row, not a fragment")
    func bossIDs() {
        // bossID 1 is Monstro. 18 is Fistula, which also has Medium/Small rows — the
        // `boss="1"` parent is the name a player would recognise.
        #expect(bestiary.boss(1)?.name == "Monstro")
        #expect(bestiary.boss(18)?.name == "Fistula")
        #expect(bestiary.boss(1)?.baseHP == 250)
    }

    @Test("Props that do not hold the doors are flagged")
    func shutdoors() {
        // shutdoors="false" is the meaningful flag; the DEFAULT is to lock. Fire Place
        // is the single most-spawned entity in a real log, so getting this backwards
        // would break any enemies-remaining count.
        let fire = bundle.entities.first { $0.type == 33 && $0.variant == 0 }
        #expect(fire?.blocksClear == false, "Fire Place must not block a clear")
        let monstro = bundle.entities.first { $0.type == 20 && $0.variant == 0 }
        #expect(monstro?.blocksClear == true)
    }

    @Test("Death and boss lines parse out of the log")
    func logLines() {
        #expect(
            LogParser().parse(line: "[INFO] - Game Over. Killed by (9.0) spawned by (20.0) damage flags (0)")
                == .died(killedBy: EntityRef(type: 9, variant: 0),
                         spawnedBy: EntityRef(type: 20, variant: 0)))
        // A (0.0) source is dropped to nil rather than pretending entity 0 killed you.
        #expect(
            LogParser().parse(line: "[INFO] - Game Over. Killed by (284.0) spawned by (0.0) damage flags (0)")
                == .died(killedBy: EntityRef(type: 284, variant: 0), spawnedBy: nil))
        #expect(LogParser().parse(line: "[INFO] - Boss 17 added to SaveState") == .bossDefeated(bossID: 17))
    }
}
