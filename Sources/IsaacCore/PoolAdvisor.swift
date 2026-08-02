import Foundation

/// "Is this pedestal better than a re-roll?", answered from the real item pools.
///
/// The pool tables carry a weight per entry, so a draw is a weighted sample. For each
/// candidate this computes what the item would actually do to *your* stats, using the
/// same StatEngine the run view uses, and averages that over the pool.
///
/// The honest limitation, surfaced in `coverage`: a stat score cannot represent every
/// item. Weapon replacers are the sharp case -- Brimstone's recorded delta is tears
/// x0.33, which reads as a *downgrade* when it is in fact one of the strongest items in
/// the game. Those are excluded rather than mis-scored, and the advice is always
/// "expected DPS gain", never "expected item quality".
public struct PoolAdvisor: Sendable {

    /// A single stat-space score for an item, given the build it would join.
    ///
    /// Damage and rate are combined multiplicatively because that is how they combine
    /// in play: doubling your damage and doubling your fire rate are both "2x DPS".
    /// Everything else is deliberately excluded — range and speed matter, but folding
    /// them into one number would invent a trade-off the game does not define.
    public static func dpsScore(_ stats: ComputedStats) -> Double {
        stats.damage.value * stats.tears.value * Double(stats.shots)
    }

    public struct Outcome: Sendable, Equatable {
        public var itemID: Int
        public var name: String
        /// Multiplier on current DPS, e.g. 1.25 == a 25% gain.
        public var ratio: Double
        public var weight: Double
        /// False when a stat-only score cannot represent this item, so `ratio` is
        /// meaningless for it rather than merely small.
        public var quantified: Bool
    }

    public struct Advice: Sendable {
        public var pool: String
        /// Expected DPS multiplier from one weighted draw.
        public var expectedRatio: Double
        /// The candidate currently on the pedestal, if one was named.
        public var candidate: Outcome?
        public var best: [Outcome]
        /// Share of pool weight whose items carry usable numbers.
        public var coverage: Double
        public var poolSize: Int

        /// Only meaningful when the candidate itself is quantified; otherwise the
        /// comparison is between a real number and a floor of zero.
        public var rerollLooksBetter: Bool? {
            guard let candidate, candidate.quantified else { return nil }
            return expectedRatio > candidate.ratio
        }
    }

    public let character: Character
    public let held: [Item]
    /// Items a stat score cannot represent: the weapon replacers. Pass the synergy
    /// lattice's layer keys. Brimstone is the reason this exists -- it carries a real
    /// delta (tears x0.33) that reads as a *downgrade*, when in fact it throws your
    /// tears away and replaces them with a laser. Scoring it on stats is not merely
    /// imprecise, it is inverted.
    public let unscorable: Set<Int>
    private let baseline: Double

    public init(character: Character, held: [Item], unscorable: Set<Int> = []) {
        self.character = character
        self.held = held
        self.unscorable = unscorable
        self.baseline = Self.dpsScore(StatEngine.compute(character: character, items: held))
    }

    /// Whether a DPS ratio means anything for this item.
    ///
    /// Note this is NOT "has a numeric delta". An item with no delta at all (Lunch,
    /// which is pure health) is perfectly scorable: its honest score is "no DPS gain".
    /// What breaks scoring is a weapon replacement or an effect that only fires
    /// sometimes.
    public func isScorable(_ item: Item) -> Bool {
        !unscorable.contains(item.id) && item.confidence != .conditional
    }

    /// What one more item would do to your DPS, as a multiplier.
    public func ratio(adding item: Item) -> Double {
        guard baseline > 0 else { return 1 }
        let after = Self.dpsScore(StatEngine.compute(character: character, items: held + [item]))
        return after / baseline
    }

    public func advise(
        pool: Pool, catalogue: [Int: Item], candidate: Item? = nil, topN: Int = 5
    ) -> Advice {
        // Items already held cannot be rolled again, so they are excluded from the
        // draw -- otherwise a nearly-cleared pool would look far better than it is.
        let heldIDs = Set(held.map(\.id))
        let entries = pool.entries.filter { !heldIDs.contains($0.id) }

        var outcomes: [Outcome] = []
        var totalWeight = 0.0
        var quantifiedWeight = 0.0
        var weightedRatio = 0.0

        for entry in entries {
            guard let item = catalogue[entry.id] else { continue }
            let quantified = isScorable(item)
            let r = ratio(adding: item)
            totalWeight += entry.weight
            // Unscorable items contribute their weight to the denominator but a
            // neutral 1.0 to the mean: counting Brimstone's x0.33 would actively
            // mislead, and counting it as a gain would be a guess.
            if quantified {
                quantifiedWeight += entry.weight
                weightedRatio += r * entry.weight
            } else {
                weightedRatio += entry.weight
            }
            outcomes.append(
                Outcome(
                    itemID: item.id, name: item.name, ratio: r, weight: entry.weight,
                    quantified: quantified))
        }

        let expected = totalWeight > 0 ? weightedRatio / totalWeight : 1
        return Advice(
            pool: pool.name,
            expectedRatio: expected,
            candidate: candidate.map {
                Outcome(
                    itemID: $0.id, name: $0.name, ratio: ratio(adding: $0), weight: 0,
                    quantified: isScorable($0))
            },
            best: outcomes.sorted { $0.ratio > $1.ratio }.prefix(topN).map { $0 },
            coverage: totalWeight > 0 ? quantifiedWeight / totalWeight : 0,
            poolSize: outcomes.count)
    }
}
