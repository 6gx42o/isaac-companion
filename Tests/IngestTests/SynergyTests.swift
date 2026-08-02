import Testing
import Foundation
@testable import Ingest
@testable import IsaacCore

private let bundle: SynergyBundle? = try? Pipeline.load().2

@Suite(.enabled(if: bundle != nil, "no built synergy bundle"))
struct SynergyLatticeTests {
    let s = bundle!

    @Test("The AB+ precedence ladder is intact and in the right order")
    func ladder() {
        // Epic Fetus > Dr. Fetus > Mom's Knife > Brimstone > Tech X > Technology > Ludovico
        let order = [168, 52, 114, 118, 395, 68, 329]
        let layers = order.map { s.layers[$0] }
        #expect(layers.allSatisfy { $0 != nil }, "every rung must be present: \(layers)")
        for (a, b) in zip(layers, layers.dropFirst()) {
            #expect(a! > b!, "\(a!) should outrank \(b!)")
        }
        #expect(s.layers[168] == 900)
        #expect(s.layers[118] == 666)
        #expect(s.layers[329] == 300)
    }

    @Test("Repentance-only rungs never made it in")
    func noRepentanceRungs() {
        // Spirit Sword (579) and C Section (678) are Repentance and out of AB+'s range.
        #expect(s.layers[579] == nil)
        #expect(s.layers[678] == nil)
        #expect(s.layers.keys.allSatisfy { $0 <= 552 })
    }

    @Test("Named interactions carry real text")
    func namedInteractions() {
        let brimIpecac = s.named.first {
            ($0.a == 118 && $0.b == 149) || ($0.a == 149 && $0.b == 118)
        }
        #expect(brimIpecac != nil)
        #expect(brimIpecac?.text.contains("Ipecac tears are fired while charging") == true)
        #expect(s.named.count > 10)
    }

    @Test("Transformations parsed with names and members")
    func transformations() {
        #expect(s.transformations.count >= 13)
        let guppy = s.transformations.first { $0.name == "Guppy" }
        #expect(guppy != nil)
        #expect(guppy?.threshold == 3)
        // Guppy's Paw (133) and Dead Cat (81) are Guppy items.
        #expect(guppy?.itemIDs.contains(133) == true)
        // Halo of Flies (10) is a FLY item -- Beelzebub, not Guppy. Getting the
        // name/index mapping off by one would silently mislabel every set.
        #expect(guppy?.itemIDs.contains(10) == false)
        let beelzebub = s.transformations.first { $0.name == "Beelzebub" }
        #expect(beelzebub?.itemIDs.contains(10) == true)
    }

    @Test("Haemolacria sits between Mom's Knife and Brimstone")
    func haemolacriaLayer() {
        // 531 is a genuine Afterbirth+ item (Booster Pack 5), not Repentance-only --
        // it is in the game's own items.xml. Its rung is 675: below Mom's Knife's 700
        // and above Brimstone's 666.
        #expect(s.layers[531] == 675)
        #expect(s.layers[531]! < s.layers[114]!)
        #expect(s.layers[531]! > s.layers[118]!)
    }
}

@Suite(.enabled(if: bundle != nil, "no built synergy bundle"))
struct SynergyEngineTests {
    let engine = SynergyEngine(bundle: bundle!)
    let items: [Int: Item] = {
        guard let loaded = try? Pipeline.load().0 else { return [:] }
        return Dictionary(
            loaded.items.filter { $0.kind != .trinket }.map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a })
    }()

    private func item(_ id: Int) -> Item { items[id]! }

    @Test("Technology is overridden by Brimstone, and never the reverse")
    func brimstoneBeatsTechnology() {
        let verdicts = engine.verdicts(for: item(68), held: [item(118)])
        guard case .overridden(let by, let win, let lose)? = verdicts.first(where: {
            if case .overridden = $0 { return true } else { return false }
        }) else {
            Issue.record("expected Technology to be overridden, got \(verdicts)")
            return
        }
        #expect(by == 118)
        #expect(win == 666)
        #expect(lose == 400)

        // The reverse must report Brimstone as the winner, not the loser.
        let reverse = engine.verdicts(for: item(118), held: [item(68)])
        #expect(!reverse.contains { if case .overridden = $0 { true } else { false } })
        #expect(reverse.contains { if case .overrides = $0 { true } else { false } })
    }

    @Test("Epic Fetus beats everything below it")
    func epicFetusWins() {
        for loser in [52, 114, 118, 395, 68, 329] {
            let v = engine.verdicts(for: item(loser), held: [item(168)])
            #expect(
                v.contains { if case .overridden(let by, _, _) = $0 { by == 168 } else { false } },
                "Epic Fetus should override \(loser)")
        }
    }

    @Test("Brimstone + Ipecac surfaces the documented interaction, not an override")
    func brimstoneIpecac() {
        let v = engine.verdicts(for: item(118), held: [item(149)])
        let named = v.compactMap { if case .named(_, let t) = $0 { t } else { nil } }
        #expect(named.contains { $0.contains("Ipecac") })
    }

    @Test("A second homing source is flagged as redundant")
    func homingRedundancy() {
        // Spoon Bender (3) and Sacred Heart (182) both grant Homing.
        #expect(item(3).delta.tearEffect == "Homing")
        let v = engine.verdicts(for: item(3), held: [item(182)])
        #expect(
            v.contains { if case .redundant(let e, _) = $0 { e == "Homing" } else { false } },
            "expected a Homing redundancy, got \(v)")

        // With no other homing source there is nothing to flag.
        let alone = engine.verdicts(for: item(3), held: [item(1)])
        #expect(!alone.contains { if case .redundant = $0 { true } else { false } })
    }

    @Test("Multishot adds rather than multiplies")
    func multishotAdds() {
        // Inner Eye (+2) and Mutant Spider (+3) => 1 + 2 + 3 = 6, not 12.
        let v = engine.verdicts(for: item(153), held: [item(2), item(153)])
        guard case .multishot(_, let total)? = v.first(where: {
            if case .multishot = $0 { return true } else { return false }
        }) else {
            Issue.record("expected a multishot verdict, got \(v)")
            return
        }
        #expect(total == 6)
    }

    @Test("Active weapon is the highest layer held")
    func activeWeapon() {
        #expect(engine.activeWeapon(held: [item(68), item(118)]) == 118)
        #expect(engine.activeWeapon(held: [item(118), item(168)]) == 168)
        #expect(engine.activeWeapon(held: [item(1)]) == nil)
    }

    @Test("Transformation progress counts held members")
    func transformationProgress() {
        guard let guppy = bundle!.transformations.first(where: { $0.name == "Guppy" }),
              guppy.itemIDs.count >= 2
        else { return }
        let held = guppy.itemIDs.prefix(2).compactMap { items[$0] }
        let progress = engine.transformationProgress(held: held)
        #expect(progress.contains { $0.0.name == "Guppy" && $0.1 == held.count })
    }
}
