import Foundation
import IsaacCore

/// Assertions that fail the data build loudly.
///
/// Every one of these exists because Repentance data is the default failure mode
/// of this project: almost every online source silently serves Repentance values,
/// and they are wrong for Afterbirth+ in ways that are invisible until the numbers
/// on screen are quietly incorrect. These run in the pipeline AND again as tests
/// against the built bundle, so a stale bundle cannot slip through.
public struct CanaryFailure: Error, CustomStringConvertible {
    public var checks: [String]
    public var description: String {
        "data canaries failed:\n" + checks.map { "  - \($0)" }.joined(separator: "\n")
    }
}

public enum Canaries {
    public static func check(items bundle: ItemBundle) -> [String] {
        var failures: [String] = []
        func require(_ condition: Bool, _ message: @autoclosure () -> String) {
            if !condition { failures.append(message()) }
        }

        let collectibles = bundle.items.filter { $0.kind != .trinket }
        let maxID = collectibles.map(\.id).max() ?? 0

        // AB+ stops at 552. Repentance goes to 732; Repentance+ and glitched items
        // go far higher. Any of those means the wrong data set was ingested.
        require(maxID <= 552, "max collectible id is \(maxID), expected <= 552 (>552 means Repentance)")
        require(collectibles.count >= 500, "only \(collectibles.count) collectibles, expected ~547")

        // Two spot values that differ between AB+ and Repentance.
        let onion = bundle.items.first { $0.id == 1 && $0.kind != .trinket }
        let onionTears: String = onion?.delta.tears.map { "\($0)" } ?? "nil"
        require(
            onion?.delta.tears == 0.7,
            "Sad Onion tears is \(onionTears), expected 0.7 (0.72 is the Repentance value)")
        let innerEye = bundle.items.first { $0.id == 2 && $0.kind != .trinket }
        let eyeMult: String = innerEye?.delta.tearsMultiplier.map { "\($0)" } ?? "nil"
        require(
            innerEye?.delta.tearsMultiplier == 0.48,
            "Inner Eye tearsMultiplier is \(eyeMult), expected 0.48 "
                + "(0.51 is the Repentance value)")

        // AB+ has no item quality; 12 `special` items are its only in-game flag.
        let special = collectibles.filter(\.special).count
        require(special == 12, "\(special) items flagged special, expected 12")

        // No item may claim a stat change and then carry no numbers -- that is a
        // silent data gap, which is exactly what this tool exists to not have.
        let gaps = bundle.items.filter {
            $0.claimsStatChange && $0.delta.isEmpty
                && $0.confidence != .nonNumeric && $0.confidence != .conditional
        }
        require(
            gaps.isEmpty,
            "\(gaps.count) items declare a stat cache flag but have no numeric data "
                + "(first: \(gaps.prefix(5).map(\.name).joined(separator: ", ")))")

        require(bundle.characters.count == 18, "\(bundle.characters.count) characters, expected 18")
        let samson = bundle.characters.first { $0.id == 6 }
        require(samson?.tears == -0.1, "Samson tears should be -0.1, not the old -0.05 wiki value")
        let azazel = bundle.characters.first { $0.id == 7 }
        require(
            azazel?.fireDelayMultiplier == 0.267,
            "Azazel fire delay should be 0.267 (x1/3 is Tainted Azazel, a Repentance character)")

        // Repentance-only vocabulary must never appear in ingested text.
        let poison = ["ActiveSlot", "Glitched item", "Birthright", "Planetarium"]
        for word in poison {
            if let hit = bundle.items.first(where: { $0.text.localizedCaseInsensitiveContains(word) }) {
                failures.append("Repentance-only term '\(word)' found in item \(hit.id) (\(hit.name))")
            }
        }
        return failures
    }

    public static func check(pools bundle: PoolBundle) -> [String] {
        var failures: [String] = []
        let expected = DataPaths.detected.expectedPoolCount
        if bundle.pools.count != expected {
            failures.append(
                "\(bundle.pools.count) item pools, expected \(expected) for "
                + DataPaths.detected.displayName)
        }
        // Repentance adds the planetarium pool and reaches 31; its presence is the
        // clearest single sign the wrong game's data got in.
        if bundle.pools.contains(where: { $0.name.lowercased().contains("planetarium") }) {
            failures.append("found a 'planetarium' pool -- that is Repentance data")
        }
        let total = bundle.pools.reduce(0) { $0 + $1.entries.count }
        if total != 1305 {
            failures.append("\(total) weighted pool entries, expected 1305 for AB+")
        }
        // The four pools that drive the phase-3 advice must actually exist.
        for required in ["treasure", "devil", "angel", "shop"]
        where !bundle.pools.contains(where: { $0.name == required }) {
            failures.append("missing the '\(required)' item pool")
        }
        if let maxID = bundle.pools.flatMap({ $0.entries }).map(\.id).max(), maxID > 552 {
            failures.append("pool references collectible \(maxID); AB+ stops at 552")
        }
        return failures
    }

    /// The AB+ weapon precedence ladder, from EID's own layer numbers. If the parse
    /// ever inverts a direction or drops a rung, the app would confidently tell you
    /// the wrong item wins -- so the ladder itself is asserted.
    public static func check(synergies bundle: SynergyBundle) -> [String] {
        var failures: [String] = []
        let expected: [(name: String, id: Int, layer: Int)] = [
            ("Epic Fetus", 168, 900), ("Dr. Fetus", 52, 800), ("Mom's Knife", 114, 700),
            ("Brimstone", 118, 666), ("Tech X", 395, 600), ("Technology", 68, 400),
            ("Ludovico", 329, 300),
        ]
        for entry in expected {
            guard let actual = bundle.layers[entry.id] else {
                failures.append("\(entry.name) (#\(entry.id)) is missing from the override ladder")
                continue
            }
            if actual != entry.layer {
                failures.append(
                    "\(entry.name) is at layer \(actual), expected \(entry.layer)")
            }
        }
        // Precedence between two replacers is decided by the layer numbers, not by an
        // explicit pairwise edge -- EID never writes a Brimstone-beats-Technology edge,
        // it just gives them 666 and 400. So the ordering is what gets asserted.
        let ladder = expected.compactMap { entry in bundle.layers[entry.id].map { (entry.name, $0) } }
        for (a, b) in zip(ladder, ladder.dropFirst()) where a.1 <= b.1 {
            failures.append(
                "precedence is out of order: \(a.0) (\(a.1)) should outrank \(b.0) (\(b.1))")
        }
        // Explicit edges must at least never contradict the ladder.
        for edge in bundle.overrides {
            guard let winner = bundle.layers[edge.winner], let loser = bundle.layers[edge.loser]
            else { continue }
            if loser > winner {
                failures.append(
                    "edge says \(edge.winner) beats \(edge.loser), but their layers say otherwise")
            }
        }
        // Anything past 552 is not an Afterbirth+ collectible.
        // (531/532/533 -- Haemolacria, Lachryphagy, Trisagion -- ARE AB+ items, added
        // in Booster Pack 5, so they are legitimate here.)
        for id in bundle.layers.keys.sorted() where id > 552 {
            failures.append("collectible \(id) is in the ladder but AB+ stops at 552")
        }
        if bundle.named.isEmpty {
            failures.append("no named interactions parsed (expected Brimstone+Ipecac and friends)")
        }
        if bundle.transformations.count < 10 {
            failures.append(
                "\(bundle.transformations.count) transformations, expected ~15 for AB+")
        }
        return failures
    }

    public static func validate(
        items: ItemBundle, pools: PoolBundle?, synergies: SynergyBundle? = nil
    ) throws {
        var all = check(items: items)
        if let pools { all += check(pools: pools) }
        if let synergies { all += check(synergies: synergies) }
        if !all.isEmpty { throw CanaryFailure(checks: all) }
    }
}
