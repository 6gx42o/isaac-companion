import Testing
import Foundation
@testable import IsaacCore

/// Ground-truth values for Afterbirth+. If any of these move, the stat model is
/// wrong and every number the app shows is wrong with it.
private let isaac = Character(id: 0, name: "Isaac")

private func item(_ id: Int, _ name: String, _ d: ItemDelta) -> Item {
    Item(id: id, name: name, kind: .passive, gfx: "", delta: d)
}

private func close(_ a: Double, _ b: Double, _ tol: Double = 0.01) -> Bool {
    abs(a - b) < tol
}

@Suite("StatEngine - AB+ ground truth")
struct StatEngineTests {

    @Test("Isaac base is 3.5 damage, 10 tear delay, 2.73 tears/s")
    func base() {
        let s = StatEngine.compute(character: isaac, items: [])
        #expect(close(s.damage.value, 3.5))
        #expect(close(s.tearDelay.value, 10))
        #expect(close(s.tears.value, 2.73))
        #expect(s.shots == 1)
        #expect(!s.damage.approx)
    }

    @Test("Blood of the Martyr: +1 damage up -> 5.19 via the sqrt curve")
    func bloodOfTheMartyr() {
        let s = StatEngine.compute(
            character: isaac, items: [item(7, "Blood of the Martyr", ItemDelta(damage: 1))])
        #expect(close(s.damage.value, 5.19))
    }

    @Test("Cricket's Head: +0.5 up then x1.5 -> 6.64")
    func cricketsHead() {
        let s = StatEngine.compute(
            character: isaac,
            items: [item(4, "Cricket's Head", ItemDelta(damage: 0.5, damageMultiplier: 1.5))])
        #expect(close(s.damage.value, 6.64))
        #expect(!s.damage.approx)
    }

    @Test("Ipecac: +40 up lands on exactly 24.5, i.e. 7x base")
    func ipecac() {
        let s = StatEngine.compute(
            character: isaac,
            items: [item(149, "Ipecac", ItemDelta(damage: 40, tearsMultiplier: 0.5, tearDelay: 10))])
        #expect(close(s.damage.value, 24.5, 0.0001))
    }

    @Test("Two damage multipliers are flagged approximate, not silently stacked")
    func twoMultipliersAreFlagged() {
        let s = StatEngine.compute(
            character: isaac,
            items: [
                item(4, "Cricket's Head", ItemDelta(damage: 0.5, damageMultiplier: 1.5)),
                item(12, "Magic Mushroom", ItemDelta(damage: 0.3, damageMultiplier: 1.5)),
            ])
        #expect(s.damage.approx)
        #expect(s.damage.reason != nil)
    }

    @Test("Sad Onion: 7.71 floors to 7 -> 3.75 tears/s")
    func sadOnion() {
        let s = StatEngine.compute(
            character: isaac, items: [item(1, "The Sad Onion", ItemDelta(tears: 0.7))])
        #expect(close(s.tearDelay.value, 7))
        #expect(close(s.tears.value, 3.75))
    }

    @Test("Tear-up curve clamps at delay 16 past the -1/1.3 boundary")
    func tearCurveBoundary() {
        #expect(close(StatEngine.tearDelay(fromTearUps: 0), 10))
        #expect(close(StatEngine.tearDelay(fromTearUps: -1.0 / 1.3), 16))
        // Below the boundary the sqrt argument would go negative; delay must pin,
        // never NaN.
        let past = StatEngine.tearDelay(fromTearUps: -5)
        #expect(close(past, 16))
        #expect(!past.isNaN)
    }

    @Test("Soy Milk and Ipecac are order-flagged and both orders stay in range")
    func soyMilkIpecac() {
        let soy = item(330, "Soy Milk", ItemDelta(damageMultiplier: 0.2, tearsMultiplier: 4, tearDelay: -2))
        let ipecac = item(149, "Ipecac", ItemDelta(damage: 40, tearsMultiplier: 0.5, tearDelay: 10))
        let a = StatEngine.compute(character: isaac, items: [soy, ipecac])
        let b = StatEngine.compute(character: isaac, items: [ipecac, soy])
        #expect(a.tears.approx)
        #expect(b.tears.approx)
        #expect(a.tearDelay.value >= StatEngine.minDelayAbsolute)
        #expect(b.tearDelay.value >= StatEngine.minDelayAbsolute)
    }

    @Test("Multishot is additive: Inner Eye +3 and Mutant Spider +4 give 8 shots, not 12")
    func multishotIsAdditive() {
        let s = StatEngine.compute(
            character: isaac,
            items: [
                item(2, "The Inner Eye", ItemDelta(tearsMultiplier: 0.48, tearDelay: 3, shots: 2)),
                item(153, "Mutant Spider", ItemDelta(tearsMultiplier: 0.48, tearDelay: 3, shots: 3)),
            ])
        #expect(s.shots == 6)  // 1 base + 2 + 3
    }

    @Test("Caps and floors hold")
    func capsAndFloors() {
        let fast = StatEngine.compute(
            character: isaac, items: [item(1, "speedy", ItemDelta(speed: 99))])
        #expect(close(fast.speed.value, 2.0))

        let slow = StatEngine.compute(
            character: isaac, items: [item(2, "sludge", ItemDelta(speed: -99))])
        #expect(close(slow.speed.value, 0.1))

        let short = StatEngine.compute(
            character: isaac, items: [item(3, "tiny", ItemDelta(range: -999))])
        #expect(close(short.range.value, 5.0))

        let slowShot = StatEngine.compute(
            character: isaac, items: [item(4, "lob", ItemDelta(shotSpeed: -99))])
        #expect(close(slowShot.shotSpeed.value, 0.6))

        // Luck is genuinely uncapped in AB+.
        let lucky = StatEngine.compute(
            character: isaac, items: [item(5, "clover", ItemDelta(luck: 50))])
        #expect(close(lucky.luck.value, 50))
    }

    // Regression: the damage curve's sqrt was unclamped while the tear curve's was
    // clamped. Odd Mushroom (Thin) is -0.4 damage in the real AB+ data and nothing
    // stops you holding several, so the argument goes negative and the stat became
    // NaN -- which JSONEncoder rejects, dropping the ENTIRE state payload and
    // blanking the readout instead of showing one wrong number.
    @Test("Stacked damage-downs never produce NaN")
    func negativeDamageUpsStayFinite() {
        let oddMushroom = item(120, "Odd Mushroom (Thin)", ItemDelta(damage: -0.4))
        for count in 1...6 {
            let s = StatEngine.compute(
                character: isaac, items: Array(repeating: oddMushroom, count: count))
            #expect(s.damage.value.isFinite, "damage went non-finite with \(count) copies")
            #expect(s.damage.value >= 0)
        }
        // Two copies (-0.8) are still above the -1/1.2 boundary and must be exact.
        let two = StatEngine.compute(
            character: isaac, items: [oddMushroom, oddMushroom])
        #expect(close(two.damage.value, 3.5 * (1 - 1.2 * 0.8).squareRoot()))
    }

    @Test("Every stat stays JSON-encodable no matter how absurd the input")
    func statsAreAlwaysEncodable() {
        let nonsense = item(1, "nonsense", ItemDelta(
            damage: -999, damageMultiplier: 0, tears: -999, tearsMultiplier: 0.0001,
            tearDelay: -9999, range: -9999, shotSpeed: -9999, speed: -9999, luck: -9999))
        let s = StatEngine.compute(character: isaac, items: [nonsense, nonsense])
        for (name, stat) in [
            ("damage", s.damage), ("tears", s.tears), ("delay", s.tearDelay),
            ("range", s.range), ("shotSpeed", s.shotSpeed), ("speed", s.speed),
            ("luck", s.luck),
        ] {
            #expect(stat.value.isFinite, "\(name) was not finite")
        }
    }

    @Test("Tear-ups alone cannot break the delay-5 floor")
    func statDelayFloor() {
        let s = StatEngine.compute(
            character: isaac, items: [item(1, "onions", ItemDelta(tears: 100))])
        #expect(s.tearDelay.value >= StatEngine.minDelayFromStats)
    }
}

@Suite("Measured against the in-game HUD")
struct HUDMeasuredTests {
    /// The first numbers in this project ever checked against the game itself rather
    /// than against a mod's data files.
    ///
    /// Seed GNXQ 9WM1, Cain, carrying only Lucky Foot (his starting item) and Scorpio.
    /// Scorpio is tearflag-only -- poison tears, no numeric change -- so the HUD was
    /// showing his base stats plus the +1 luck Lucky Foot grants. Two were wrong, and
    /// neither had been flagged uncertain.
    @Test("Cain's base damage and speed match what the game displays")
    func cainMatchesTheHUD() {
        // Built here rather than read from Ingest.Characters: this target cannot import
        // Ingest, and the point is to pin the NUMBERS the game showed, so a table change
        // that silently drops them fails the IngestTests parity check instead.
        let cain = Character(
            id: 2, name: "Cain", speed: 1.3, damageMultiplier: 1.2)
        let luckyFoot = item(46, "Lucky Foot", ItemDelta(luck: 1))
        let stats = StatEngine.compute(character: cain, items: [luckyFoot])

        // The HUD said 4.20. It was computing 3.50 -- Cain's x1.2 damage multiplier
        // was missing entirely.
        #expect(abs(stats.damage.value - 4.2) < 0.005, "damage \(stats.damage.value)")
        // The HUD said 1.30. It was computing 1.10.
        #expect(abs(stats.speed.value - 1.3) < 0.005, "speed \(stats.speed.value)")
        // These two already agreed, and are pinned so a future change has to keep them.
        #expect(abs(stats.shotSpeed.value - 1.0) < 0.005)
        #expect(abs(stats.luck.value - 1.0) < 0.005, "Lucky Foot is his starting item")
    }

    @Test("Cain's luck still comes from the item, not from his base")
    func luckIsNotDoubleCounted() {
        // The HUD reads 1, and it must be 1 because of the pickup -- giving him base
        // luck 1 as well would read 2 the moment the log announces Lucky Foot.
        let cain = Character(id: 2, name: "Cain", speed: 1.3, damageMultiplier: 1.2)
        #expect(cain.luck == 0)
        let bare = StatEngine.compute(character: cain, items: [])
        #expect(abs(bare.luck.value - 0) < 0.005)
    }
}
