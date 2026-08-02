import Testing
import Foundation
@testable import Ingest
@testable import IsaacCore

private let loaded: (ItemBundle, PoolBundle?, SynergyBundle?)? = try? Pipeline.load()

@Suite(.enabled(if: loaded?.1 != nil, "no pool data built"))
struct PoolAdvisorTests {
    let bundle = loaded!.0
    let pools = loaded!.1!

    private var catalogue: [Int: Item] {
        Dictionary(
            bundle.items.filter { $0.kind.isAutoTracked }.map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a })
    }
    private var isaac: Character { bundle.characters.first { $0.id == 0 }! }
    /// The weapon replacers, straight from the lattice -- these are exactly the items
    /// a DPS score cannot represent.
    private var replacers: Set<Int> { Set((loaded!.2?.layers ?? [:]).keys) }
    private var treasure: Pool { pools.pools.first { $0.name == "treasure" }! }

    @Test("A damage item scores above 1, a pure downgrade below")
    func directionality() {
        let advisor = PoolAdvisor(character: isaac, held: [], unscorable: replacers)
        // Sad Onion (+0.7 tears) must be an improvement.
        #expect(advisor.ratio(adding: catalogue[1]!) > 1.0)
        // Cricket's Head (+0.5 damage, x1.5) must beat it.
        #expect(advisor.ratio(adding: catalogue[4]!) > advisor.ratio(adding: catalogue[1]!))
        // An item that changes nothing measurable leaves the ratio at exactly 1.
        let inert = Item(id: 9999, name: "Inert", kind: .passive, gfx: "")
        #expect(abs(advisor.ratio(adding: inert) - 1.0) < 1e-9)
    }

    @Test("Expected ratio is a weighted average, and coverage is reported honestly")
    func expectation() {
        let advisor = PoolAdvisor(character: isaac, held: [], unscorable: replacers)
        let advice = advisor.advise(pool: treasure, catalogue: catalogue)
        #expect(advice.poolSize > 100, "treasure pool should be large")
        // A random treasure item is on average an improvement, but not a huge one.
        #expect(advice.expectedRatio > 1.0)
        #expect(advice.expectedRatio < 2.0)
        // Most treasure items ARE scorable — an item with no delta still scores
        // honestly as "no DPS gain". What must stay excluded is the weapon replacers,
        // so coverage should be high but never 1.0. (Measured: 0.935, 22 of 339.)
        #expect(advice.coverage > 0.85, "coverage \(advice.coverage)")
        #expect(advice.coverage < 1.0, "weapon replacers must not be counted as scorable")
        let unscorableNames = advice.best.filter { !$0.quantified }.map(\.name)
        #expect(unscorableNames.isEmpty, "an unscorable item must never top the ranking")
        #expect(advice.best.first!.ratio >= advice.best.last!.ratio)
    }

    @Test("Items already held are excluded from the draw")
    func excludesHeld() {
        let advisor = PoolAdvisor(character: isaac, held: [], unscorable: replacers)
        let before = advisor.advise(pool: treasure, catalogue: catalogue).poolSize

        let someTreasure = treasure.entries.prefix(5).compactMap { catalogue[$0.id] }
        let withHeld = PoolAdvisor(
            character: isaac, held: someTreasure, unscorable: replacers)
        let after = withHeld.advise(pool: treasure, catalogue: catalogue).poolSize
        #expect(after == before - someTreasure.count, "held items must leave the pool")
    }

    @Test("A strong candidate beats the pool average; a weak one does not")
    func rerollVerdict() {
        let advisor = PoolAdvisor(character: isaac, held: [], unscorable: replacers)
        // Sacred Heart (x2.3 damage, homing) is one of the best items in the game.
        let strong = advisor.advise(
            pool: treasure, catalogue: catalogue, candidate: catalogue[182]!)
        #expect(strong.rerollLooksBetter == false, "should not re-roll Sacred Heart")

        // Lunch is pure health. It has no delta at all, but that is still a perfectly
        // honest score of "no DPS gain" -- so it IS scorable, and re-rolling wins.
        let weak = advisor.advise(
            pool: treasure, catalogue: catalogue, candidate: catalogue[22]!)  // Lunch
        #expect(weak.candidate?.quantified == true, "no delta != unscorable")
        #expect(weak.rerollLooksBetter == true, "Lunch should be worth re-rolling")
    }

    @Test("An unquantified candidate returns no verdict rather than a wrong one")
    func honestAboutUnknowns() {
        let advisor = PoolAdvisor(character: isaac, held: [], unscorable: replacers)
        // Brimstone replaces tears rather than adding to a stat, so a stat-only score
        // reads it as ~zero. Claiming "re-roll Brimstone" would be badly wrong, so the
        // advisor must decline to answer instead.
        let brimstone = catalogue[118]!
        let advice = advisor.advise(
            pool: pools.pools.first { $0.name == "devil" }!, catalogue: catalogue,
            candidate: brimstone)
        #expect(advice.candidate?.quantified == false)
        #expect(advice.rerollLooksBetter == nil, "must not judge an unquantified item")
    }

    @Test("Scoring reflects the CURRENT build, not a fixed ranking")
    func buildRelative() {
        // Cricket's Head is a damage multiplier, so it is worth more once you already
        // have flat damage to multiply. A fixed item ranking could not express this.
        let bare = PoolAdvisor(character: isaac, held: [], unscorable: replacers)
        let withFlatDamage = PoolAdvisor(
            character: isaac, held: [catalogue[7]!], unscorable: replacers)
        #expect(
            withFlatDamage.ratio(adding: catalogue[4]!) != bare.ratio(adding: catalogue[4]!),
            "a multiplier's value must depend on what it multiplies")
    }
}
