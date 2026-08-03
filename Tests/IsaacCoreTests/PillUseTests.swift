import Foundation
import Testing

@testable import IsaacCore

/// The rules the app's pill loop follows, exercised on PillMemory alone so they are
/// testable without a screen. The app wires these to the log's `pocketItemUsed` event
/// and to the colour read off the pocket slot; what is asserted here is the logic that
/// decides what a swallow means.
@Suite("Pill use - attributing a swallow")
struct PillUseTests {

    /// Model of what AppModel does on `.pocketItemUsed`: attribute the swallow to the
    /// colour last seen in the pocket slot, park it if the effect is unknown.
    private struct Loop {
        var memory = PillMemory()
        var held: Int?
        var awaiting: [Int] = []
        var run: [Int] = []                       // effect ids that reached the run

        mutating func sawInPocket(_ colour: Int) {
            held = colour
            memory.note(colour: colour)
        }

        mutating func used() {
            guard let colour = held else { return }
            memory.note(colour: colour)
            if let known = memory.effect(of: colour) {
                run.append(known.effectID)
            } else {
                awaiting.append(colour)
            }
            held = nil
        }

        mutating func identify(_ colour: Int, as effectID: Int) {
            memory.learn(colour: colour, effectID: effectID, source: .identified)
            let owed = awaiting.filter { $0 == colour }.count
            awaiting.removeAll { $0 == colour }
            run.append(contentsOf: Array(repeating: effectID, count: owed))
        }
    }

    /// The payoff: once a colour is named, every later pill of it lands in the run with
    /// nothing asked of anyone.
    @Test("a known colour is recorded automatically, every time")
    func knownColourNeedsNoInteraction() {
        var loop = Loop()
        loop.sawInPocket(6)
        loop.identify(6, as: 14)                  // Speed Up
        loop.used()
        #expect(loop.run == [14])

        loop.sawInPocket(6)
        loop.used()
        loop.sawInPocket(6)
        loop.used()
        #expect(loop.run == [14, 14, 14], "later pills of a known colour need no prompt")
        #expect(loop.awaiting.isEmpty)
    }

    /// The first pill of a colour is the one that TELLS you what the colour does, so it
    /// is the one you least want dropped -- and the easiest to drop, because at the
    /// moment it is swallowed nothing knows what it was.
    @Test("the first pill of a colour is backfilled when the colour is named")
    func firstPillIsNotLost() {
        var loop = Loop()
        loop.sawInPocket(2)
        loop.used()
        #expect(loop.run.isEmpty, "nothing is known yet, so nothing is claimed")
        #expect(loop.awaiting == [2])

        loop.identify(2, as: 16)                  // "that was Tears Up"
        #expect(loop.run == [16], "the pill already swallowed must reach the run")
        #expect(loop.awaiting.isEmpty)
    }

    @Test("several pills of one colour taken before naming are all backfilled")
    func backfillsEveryOne() {
        var loop = Loop()
        for _ in 0..<3 {
            loop.sawInPocket(9)
            loop.used()
        }
        #expect(loop.awaiting == [9, 9, 9])
        loop.identify(9, as: 12)                  // Range Up
        #expect(loop.run == [12, 12, 12])
    }

    /// Naming one colour must not sweep up pills of a different one.
    @Test("naming a colour leaves other colours parked")
    func onlyTheNamedColour() {
        var loop = Loop()
        loop.sawInPocket(1); loop.used()
        loop.sawInPocket(4); loop.used()
        loop.sawInPocket(1); loop.used()
        #expect(loop.awaiting == [1, 4, 1])

        loop.identify(1, as: 18)                  // Luck Up
        #expect(loop.run == [18, 18])
        #expect(loop.awaiting == [4], "the other colour is still a mystery")
    }

    /// The log says "PillCard", not "Pill". Using a card with nothing read from the
    /// pocket slot must not invent a pill.
    @Test("a use with nothing held is ignored, not guessed")
    func cardUseIsNotAPill() {
        var loop = Loop()
        loop.used()
        #expect(loop.run.isEmpty)
        #expect(loop.awaiting.isEmpty)
        #expect(loop.memory.seen.isEmpty)
    }

    @Test("swallowing empties the slot, so one read is not counted twice")
    func slotEmptiesOnUse() {
        var loop = Loop()
        loop.sawInPocket(5)
        loop.identify(5, as: 13)
        loop.used()
        loop.used()                               // no second pill was picked up
        #expect(loop.run == [13], "one pill read, one pill recorded")
    }
}
