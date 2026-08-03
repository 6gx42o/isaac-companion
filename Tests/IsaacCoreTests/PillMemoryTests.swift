import Foundation
import Testing

@testable import IsaacCore

@Suite("PillMemory - one shuffle per run")
struct PillMemoryTests {

    @Test("learning a colour once answers for every later pill of that colour")
    func learnOnce() {
        var m = PillMemory()
        #expect(m.effect(of: 6) == nil)
        m.learn(colour: 6, effectID: 14, source: .identified)      // Speed Up
        #expect(m.effect(of: 6)?.effectID == 14)
        // The second orange pill of a run must not have to be asked about.
        #expect(m.effect(of: 6)?.source == .identified)
    }

    @Test("a colour can be seen without its effect being claimed")
    func seenButUnknown() {
        var m = PillMemory()
        m.note(colour: 3)
        m.note(colour: 3)                                          // idempotent
        m.note(colour: 9)
        #expect(m.seen == [3, 9])
        #expect(m.unknownColours == [3, 9])
        m.learn(colour: 3, effectID: 18, source: .inferred)
        #expect(m.unknownColours == [9])
        #expect(m.seen == [3, 9], "learning must not reorder or drop what was seen")
    }

    /// The player watched the pill go down; the inference is arithmetic on a signal that
    /// several pills could explain. So the player wins.
    @Test("an inference never overwrites what the player said")
    func playerBeatsInference() {
        var m = PillMemory()
        m.learn(colour: 2, effectID: 14, source: .identified)       // "that was Speed Up"
        m.learn(colour: 2, effectID: 16, source: .inferred)         // a guess of Tears Up
        #expect(m.effect(of: 2)?.effectID == 14)
        #expect(m.effect(of: 2)?.source == .identified)
    }

    @Test("the player can correct themselves, and can overwrite a guess")
    func correction() {
        var m = PillMemory()
        m.learn(colour: 4, effectID: 11, source: .inferred)
        m.learn(colour: 4, effectID: 12, source: .identified)       // corrects the guess
        #expect(m.effect(of: 4)?.effectID == 12)
        m.learn(colour: 4, effectID: 13, source: .identified)       // and again
        #expect(m.effect(of: 4)?.effectID == 13)
        m.forget(colour: 4)
        #expect(m.effect(of: 4) == nil)
        #expect(m.seen.contains(4), "forgetting the effect does not unsee the colour")
    }

    /// Carrying a mapping into the next run would be worse than having none: the game
    /// reshuffles, so every entry would be confidently wrong.
    @Test("a new run voids the whole mapping")
    func resetOnNewRun() {
        var m = PillMemory()
        m.learn(colour: 1, effectID: 14, source: .identified)
        m.note(colour: 7)
        m.reset()
        #expect(m.byColour.isEmpty)
        #expect(m.seen.isEmpty)
        #expect(m.effect(of: 1) == nil)
    }

    @Test("survives a round trip, so it can be archived with the run")
    func codable() throws {
        var m = PillMemory()
        m.learn(colour: 5, effectID: 12, source: .identified)
        m.note(colour: 8)
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(PillMemory.self, from: data)
        #expect(back == m)
        #expect(back.effect(of: 5)?.effectID == 12)
        #expect(back.unknownColours == [8])
    }
}
