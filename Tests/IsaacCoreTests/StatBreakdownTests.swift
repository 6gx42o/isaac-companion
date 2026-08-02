import Testing
@testable import IsaacCore

/// The run view prints `base`, a delta, and a total. If those three ever stop
/// reconciling, the readout is lying to the player — so the invariant is tested
/// directly rather than eyeballed.
@Suite("Stat breakdown")
struct StatBreakdownTests {

    private func item(_ name: String, _ delta: ItemDelta) -> Item {
        Item(
            id: 1, name: name, kind: .passive, gfx: "", cache: [], special: false,
            maxCharges: nil, devilPrice: nil, pools: [], delta: delta, text: "",
            confidence: .verified)
    }

    // Built inline rather than pulled from Ingest's table: this suite is about the
    // arithmetic, so it should not break when the roster data changes.
    private let isaac = Character(id: 0, name: "Isaac")
    private let cain = Character(id: 2, name: "Cain", speed: 1.1)
    private let judas = Character(id: 3, name: "Judas", damageMultiplier: 1.35)

    @Test("base + fromItems always equals the total")
    func reconciles() {
        let build = [
            item("Cricket's Head", ItemDelta(damage: 0.5, damageMultiplier: 1.5)),
            item("The Sad Onion", ItemDelta(tears: 0.7)),
            item("Mom's Heels", ItemDelta(range: 5.25)),
            item("Wooden Spoon", ItemDelta(speed: 0.3)),
            item("Lucky Foot", ItemDelta(luck: 1)),
        ]
        let s = StatEngine.compute(character: cain, items: build)
        for (label, stat) in [
            ("damage", s.damage), ("tears", s.tears), ("delay", s.tearDelay),
            ("range", s.range), ("shotSpeed", s.shotSpeed), ("speed", s.speed),
            ("luck", s.luck),
        ] {
            #expect(
                abs((stat.base + stat.fromItems) - stat.value) < 1e-9,
                "\(label): \(stat.base) + \(stat.fromItems) != \(stat.value)")
        }
    }

    @Test("With no items every stat is exactly its base")
    func emptyBuild() {
        let s = StatEngine.compute(character: isaac, items: [])
        let all: [Stat] = [
            s.damage, s.tears, s.tearDelay, s.range, s.shotSpeed, s.speed, s.luck,
        ]
        for stat in all {
            #expect(abs(stat.fromItems) < 1e-9, "expected no movement, got \(stat.fromItems)")
            #expect(abs(stat.value - stat.base) < 1e-9)
        }
    }

    @Test("Damage base includes the character's innate multiplier, not item ones")
    func damageBase() {
        // Isaac is 3.5 flat. Judas is 3.5 x1.35 = 4.725 before any item.
        #expect(abs(StatEngine.compute(character: isaac, items: []).damage.base - 3.5) < 1e-9)
        #expect(abs(StatEngine.compute(character: judas, items: []).damage.base - 4.725) < 1e-6)

        // An item multiplier moves the total but must NOT move the base.
        let withCricket = StatEngine.compute(
            character: isaac, items: [item("Cricket's Head", ItemDelta(damageMultiplier: 1.5))])
        #expect(abs(withCricket.damage.base - 3.5) < 1e-9)
        #expect(withCricket.damage.value > withCricket.damage.base)
    }

    @Test("A downgrade reports a negative contribution")
    func downgrades() {
        // Number One is +1.5 tears but -17.62 range.
        let s = StatEngine.compute(
            character: isaac, items: [item("Number One", ItemDelta(tears: 1.5, range: -17.62))])
        #expect(s.range.fromItems < 0, "range should have gone down")
        #expect(s.tears.fromItems > 0, "tears should have gone up")
        #expect(abs((s.range.base + s.range.fromItems) - s.range.value) < 1e-9)
    }

    @Test("Clamped stats still reconcile")
    func clamping() {
        // Range floors at 5 and speed at 0.1; the delta must reflect the CLAMPED
        // result, not the raw sum, or the printed arithmetic breaks.
        let s = StatEngine.compute(
            character: isaac,
            items: [item("absurd", ItemDelta(range: -999, speed: -999))])
        #expect(abs(s.range.value - 5.0) < 1e-9)
        #expect(abs(s.speed.value - 0.1) < 1e-9)
        #expect(abs((s.range.base + s.range.fromItems) - s.range.value) < 1e-9)
        #expect(abs((s.speed.base + s.speed.fromItems) - s.speed.value) < 1e-9)
    }
}
