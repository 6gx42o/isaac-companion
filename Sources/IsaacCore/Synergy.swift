import Foundation

/// One weapon-replacing item beating another.
///
/// Afterbirth+ resolves these by a fixed precedence: Epic Fetus (900) > Dr. Fetus
/// (800) > Mom's Knife (700) > Brimstone (666) > Tech X (600) > Technology (400) >
/// Ludovico (300). Holding two of them is not a synergy -- the loser's tear effect
/// simply never fires, and only its stat changes still apply.
public struct WeaponOverride: Codable, Sendable, Equatable {
    public var winner: Int
    public var loser: Int
    public var layer: Int
    public init(winner: Int, loser: Int, layer: Int) {
        self.winner = winner; self.loser = loser; self.layer = layer
    }
}

/// A specifically-documented interaction between two items, e.g. Brimstone + Ipecac.
public struct NamedSynergy: Codable, Sendable, Equatable {
    public var a: Int
    public var b: Int
    public var key: String
    public var text: String
    public init(a: Int, b: Int, key: String, text: String) {
        self.a = a; self.b = b; self.key = key; self.text = text
    }
    public func involves(_ id: Int) -> Bool { a == id || b == id }
    public func other(than id: Int) -> Int { a == id ? b : a }
}

public struct TransformationDef: Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var itemIDs: [Int]
    public var threshold: Int
    public init(id: String, name: String, itemIDs: [Int], threshold: Int = 3) {
        self.id = id; self.name = name; self.itemIDs = itemIDs; self.threshold = threshold
    }
}

public struct SynergyBundle: Codable, Sendable {
    public var schema: Int
    public var gameVersion: GameVersion
    /// itemID -> precedence layer, for the weapon-replacing items only.
    public var layers: [Int: Int]
    public var overrides: [WeaponOverride]
    public var named: [NamedSynergy]
    public var transformations: [TransformationDef]

    public init(
        schema: Int = 1, gameVersion: GameVersion = .abplus, layers: [Int: Int] = [:],
        overrides: [WeaponOverride] = [], named: [NamedSynergy] = [],
        transformations: [TransformationDef] = []
    ) {
        self.schema = schema; self.gameVersion = gameVersion; self.layers = layers
        self.overrides = overrides; self.named = named; self.transformations = transformations
    }
}

/// What the tool has to say about one item given a build.
public enum Verdict: Sendable, Equatable {
    /// This item's weapon effect will never fire because something beats it.
    case overridden(by: Int, winnerLayer: Int, loserLayer: Int)
    /// This item beats things already held.
    case overrides([Int])
    /// A documented interaction with something already held.
    case named(with: Int, text: String)
    /// Its tear effect is already provided by something else, so only stats apply.
    case redundant(effect: String, with: [Int])
    /// Contributes extra shots; these add rather than multiply.
    case multishot(extra: Int, total: Int)
    /// Completes or advances a transformation.
    case transformation(name: String, have: Int, need: Int)

    public var isNegative: Bool {
        switch self {
        case .overridden, .redundant: true
        default: false
        }
    }
}

/// Cross-item reasoning over a build.
///
/// This is the part no existing tool does: EID shows one pedestal's text with no
/// knowledge of what you are already holding, so it cannot tell you that the
/// Technology you are about to take will do nothing because you have Brimstone.
public struct SynergyEngine: Sendable {
    public let bundle: SynergyBundle
    public init(bundle: SynergyBundle) { self.bundle = bundle }

    /// Verdicts for `candidate` given the items already held.
    /// `candidate` may itself already be in `held` (the run view calls it that way).
    public func verdicts(for candidate: Item, held: [Item]) -> [Verdict] {
        var out: [Verdict] = []
        let heldIDs = held.map(\.id)
        let others = held.filter { $0.id != candidate.id }
        let otherIDs = Set(others.map(\.id))

        // --- weapon replacement ------------------------------------------
        // Two sources of "this item is overridden":
        //  1. Both are weapon replacers -> the higher LAYER wins. EID does not write an
        //     edge for every such pair (there is no Brimstone-beats-Technology edge,
        //     just 666 vs 400), so layers are authoritative there.
        //  2. An explicit edge names a loser that is NOT itself a replacer -- Cursed
        //     Eye, Evil Eye, Trisagion and 34 others. These have no layer at all, so a
        //     layer-only rule left 144 of the 147 edges silent and the user got no
        //     warning that the item they just took does nothing.
        let myLayer = bundle.layers[candidate.id]

        var winners: [(id: Int, layer: Int)] = []
        if let myLayer {
            winners += otherIDs
                .compactMap { id in bundle.layers[id].map { (id, $0) } }
                .filter { $0.1 > myLayer }
        }
        winners += bundle.overrides
            .filter { $0.loser == candidate.id && otherIDs.contains($0.winner) }
            .map { ($0.winner, bundle.layers[$0.winner] ?? $0.layer) }

        if let top = winners.max(by: { $0.layer < $1.layer }) {
            out.append(
                .overridden(by: top.id, winnerLayer: top.layer, loserLayer: myLayer ?? 0))
        }

        // The winner-facing side: what this item beats.
        var beaten = Set(
            bundle.overrides
                .filter { $0.winner == candidate.id && otherIDs.contains($0.loser) }
                .map(\.loser))
        if let myLayer {
            beaten.formUnion(
                otherIDs
                    .compactMap { id in bundle.layers[id].map { (id, $0) } }
                    .filter { $0.1 < myLayer }
                    .map(\.0))
        }
        if !beaten.isEmpty { out.append(.overrides(beaten.sorted())) }

        // --- documented interactions -------------------------------------
        for synergy in bundle.named where synergy.involves(candidate.id) {
            let partner = synergy.other(than: candidate.id)
            if otherIDs.contains(partner) {
                out.append(.named(with: partner, text: synergy.text))
            }
        }

        // --- tear-effect redundancy --------------------------------------
        if let effect = candidate.delta.tearEffect {
            let duplicates = others.filter { $0.delta.tearEffect == effect }.map(\.id)
            if !duplicates.isEmpty {
                out.append(.redundant(effect: effect, with: duplicates.sorted()))
            }
        }

        // --- multishot ----------------------------------------------------
        if let extra = candidate.delta.shots {
            let total = 1 + held.compactMap(\.delta.shots).reduce(0, +)
                + (heldIDs.contains(candidate.id) ? 0 : extra)
            out.append(.multishot(extra: extra, total: total))
        }

        // --- transformations ----------------------------------------------
        for transform in bundle.transformations where transform.itemIDs.contains(candidate.id) {
            let have = Set(heldIDs).union([candidate.id]).intersection(transform.itemIDs).count
            out.append(
                .transformation(name: transform.name, have: have, need: transform.threshold))
        }
        return out
    }

    /// Which weapon-replacing item is actually firing, given the build.
    public func activeWeapon(held: [Item]) -> Int? {
        held.map(\.id)
            .compactMap { id in bundle.layers[id].map { (id, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    /// Transformation progress across the whole run.
    public func transformationProgress(held: [Item]) -> [(TransformationDef, Int)] {
        let ids = Set(held.map(\.id))
        return bundle.transformations.compactMap { transform in
            let have = ids.intersection(transform.itemIDs).count
            return have > 0 ? (transform, have) : nil
        }
        .sorted { ($0.1, $1.0.name) > ($1.1, $0.0.name) }
    }
}
