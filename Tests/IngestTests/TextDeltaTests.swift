import Testing
@testable import Ingest
@testable import IsaacCore

/// Every string here is a verbatim EID description. The asymmetry matters: wrongly
/// treating a conditional effect as permanent silently corrupts the numbers the app
/// shows, whereas wrongly treating a permanent one as conditional only shows up as
/// a known gap. So these tests lean hard on the refusal cases.
@Suite("TextDelta")
struct TextDeltaTests {

    @Test("Unconditional numbers are extracted")
    func extractsPermanent() {
        let cancer = TextDelta.parse("↑ {{Tears}} -2 Tear delay")
        #expect(cancer?.tearDelay == -2)

        let tapeWorm = TextDelta.parse("↑ {{Range}} x2 Range multiplier#↓ x0.5 Tear height")
        #expect(tapeWorm?.rangeMultiplier == 2)

        let onion = TextDelta.parse("↑ {{Tears}} +0.7 Tears")
        #expect(onion?.tears == 0.7)

        let cricket = TextDelta.parse(
            "↑ {{Damage}} +0.5 Damage#↑ {{Damage}} x1.5 Damage multiplier")
        #expect(cricket?.damage == 0.5)
        #expect(cricket?.damageMultiplier == 1.5)
    }

    @Test("Multiplier text is never read as a flat stat up")
    func multiplierNotFlat() {
        let d = TextDelta.parse("↓ {{Tears}} x0.48 Tears multiplier#↓ {{Tears}} +3 Tear delay")
        #expect(d?.tearsMultiplier == 0.48)
        #expect(d?.tearDelay == 3)
        #expect(d?.tears == nil)
    }

    @Test("Conditional and temporary effects are refused")
    func refusesConditional() {
        // Each of these produced a wrong permanent delta before the marker list
        // was tightened.
        let conditional = [
            "↑ {{Damage}} +0.04 Damage for every {{Coin}} coin Isaac has",         // Money = Power
            "↑ {{Damage}} +2 Damage for the left eye",                             // Chemical Peel
            "↑ {{Damage}} +1 Damage for the left eye#↑ {{Range}} +5 Range for the left eye",
            "For every empty heart container:#↑ {{Damage}} +0.2 Damage",           // Adrenaline
            "Upon losing a Bone Heart:#↑ {{Tears}} +0.5 Tears",                    // Brittle Bones
            "↑ {{Damage}} x1.5 Damage multiplier while standing in the aura",      // Succubus
            "{{Timer}} Receive for the room:#↑ {{Damage}} +2 Damage",              // Book of Belial
            "When on half a Red Heart or less:#↑ {{Speed}} +0.3 Speed#↑ {{Damage}} +1.5 Damage",
            "↑ {{Damage}} +0.5 Damage for each enemy killed in the room#Caps at +5 Damage",
            "Holding a fully charged active item grants:#↑ {{Speed}} +0.25 Speed",
        ]
        for text in conditional {
            #expect(TextDelta.parse(text) == nil, "should refuse: \(text)")
            #expect(TextDelta.isConditional(text))
        }
    }

    @Test("Disagreements between the two sources are reported")
    func disagreements() {
        let typed = ItemDelta(tears: 0.3)
        let text = ItemDelta(tears: 0.4)
        #expect(TextDelta.disagreements(typed, text).count == 1)
        #expect(TextDelta.disagreements(typed, typed).isEmpty)
        // A field present in only one source is not a disagreement.
        #expect(TextDelta.disagreements(ItemDelta(tears: 0.3), ItemDelta(damage: 1)).isEmpty)
    }

    @Test("Non-stat text yields nothing rather than a bogus delta")
    func nonStatText() {
        #expect(TextDelta.parse("{{Key}} +99 Keys") == nil)
        #expect(TextDelta.parse("↑ {{Heart}} +1 Health") == nil)
        #expect(TextDelta.parse("") == nil)
    }
}
