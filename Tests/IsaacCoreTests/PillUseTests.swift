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
    struct Loop {
        var memory = PillMemory()
        var held: Int?
        var heldCard: Int?
        var cardAlternatives: [Int] = []
        var awaiting: [Int] = []
        var unidentified = 0
        var run: [Int] = []                       // effect ids that reached the run

        mutating func sawInPocket(_ colour: Int) {
            held = colour
            heldCard = nil
            cardAlternatives = []
            memory.note(colour: colour)
        }

        /// `alternatives` longer than one means the game draws them identically.
        mutating func sawCard(_ id: Int, alternatives: [Int] = []) {
            heldCard = id
            cardAlternatives = alternatives
            held = nil
        }

        /// A new run: the game reshuffles, so nothing about the pocket survives.
        mutating func newRun() {
            memory.reset()
            awaiting.removeAll()
            unidentified = 0
            held = nil
            heldCard = nil
            cardAlternatives = []
        }

        mutating func used() {
            if let card = heldCard {
                if cardAlternatives.count <= 1 { run.append(card) } else { unidentified += 1 }
                heldCard = nil
                cardAlternatives = []
                return
            }
            // Something was used but nothing had been read -- runtime spawns (Acid
            // Baby's pills) write no log line, so no read was ever scheduled. The gap
            // is counted where the UI can show it, never silently dropped.
            guard let colour = held else {
                unidentified += 1
                return
            }
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

    /// The log says "PillCard", not "Pill" -- and a runtime-spawned pill (Acid Baby's)
    /// writes no spawn line, so a use can arrive with nothing ever read. Found live: the
    /// first real pocket use of the session vanished without a trace. It must not be
    /// guessed at, but it must not vanish either.
    @Test("a use with nothing held is counted as unattributed, not guessed and not lost")
    func nothingHeldIsCountedNotGuessed() {
        var loop = Loop()
        loop.used()
        #expect(loop.run.isEmpty, "no guess enters the run")
        #expect(loop.awaiting.isEmpty)
        #expect(loop.memory.seen.isEmpty)
        #expect(loop.unidentified == 1, "but the run admits something was used")
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

@Suite("Pocket use - cards and run boundaries")
struct PocketUseTests {
    private typealias Loop = PillUseTests.Loop

    /// A card is a complete answer on sight, so using one records it outright.
    @Test("an identified card goes straight into the run")
    func cardRecorded() {
        var loop = PillUseTests.Loop()
        loop.sawCard(2)
        loop.used()
        #expect(loop.run == [2])
        #expect(loop.heldCard == nil, "the slot is empty now")
    }

    /// Blank Rune and Black Rune share their art. Recording a coin flip is worse than
    /// recording nothing -- but the held state must still clear, or the page goes on
    /// claiming the card is in your pocket after you have used it.
    @Test("an ambiguous card is not recorded, and does not stick in the slot")
    func ambiguousCardClears() {
        var loop = PillUseTests.Loop()
        loop.sawCard(40, alternatives: [40, 41])
        loop.used()
        #expect(loop.run.isEmpty, "a coin flip must not enter the run")
        #expect(loop.unidentified == 1, "but the gap is counted, not hidden")
        #expect(loop.heldCard == nil, "the slot must clear even when unattributed")
        #expect(loop.cardAlternatives.isEmpty)
    }

    /// The game reshuffles colour -> effect every run, so a colour still awaiting
    /// identification must not be carried across and backfilled into the next one.
    @Test("nothing about the pocket survives a new run")
    func newRunClearsEverything() {
        var loop = PillUseTests.Loop()
        loop.sawInPocket(3)
        loop.used()                                   // parked, effect unknown
        #expect(loop.awaiting == [3])

        loop.newRun()
        #expect(loop.awaiting.isEmpty, "a pill from the last run must not be backfilled")
        #expect(loop.memory.seen.isEmpty)
        #expect(loop.held == nil)
        #expect(loop.unidentified == 0)

        // And naming that colour in the new run must not resurrect the old pill.
        loop.sawInPocket(3)
        loop.identify(3, as: 14)
        #expect(loop.run.isEmpty, "no pill has been swallowed yet this run")
    }

    /// Picking up a card while a pill was remembered must not leave both set.
    @Test("the slot holds one thing at a time")
    func slotIsExclusive() {
        var loop = PillUseTests.Loop()
        loop.sawInPocket(5)
        loop.sawCard(7)
        #expect(loop.held == nil, "the pill is no longer in the slot")
        loop.used()
        #expect(loop.run == [7], "the card was used, not the pill")
    }
}

@Suite("Floor pills - answering the swallow the slot read misses")
struct FloorPillTests {
    /// Model of the floor-read attribution: a pill read off the floor answers a later
    /// swallow, but only while it is the sole candidate, and never across rooms.
    private struct Floor {
        var loop = PillUseTests.Loop()
        var floorColour: Int?
        var ambiguous = false

        mutating func sawOnFloor(_ colour: Int) {
            loop.memory.note(colour: colour)
            if let existing = floorColour, existing != colour {
                ambiguous = true
            } else {
                floorColour = colour
            }
        }

        mutating func newRoom() {
            floorColour = nil
            ambiguous = false
        }

        mutating func used() {
            if loop.held == nil, loop.heldCard == nil, !ambiguous, let c = floorColour {
                floorColour = nil
                loop.sawInPocket(c)
            }
            loop.used()
        }
    }

    /// The session that motivated this: every slot read came back empty because the
    /// player swallows within a second of grabbing. The floor read is taken while the
    /// pill still sits at its logged spawn position, so the swallow gets its answer.
    @Test("a lone floor pill answers the swallow the slot never saw")
    func lonePillAnswers() {
        var f = Floor()
        f.sawOnFloor(6)
        f.used()
        #expect(f.loop.awaiting == [6], "attributed to the floor colour, parked for naming")
        #expect(f.floorColour == nil, "one read answers one use")
    }

    @Test("a named floor colour goes straight into the run")
    func namedColourCounts() {
        var f = Floor()
        f.loop.identify(6, as: 14)                    // Speed Up, learned earlier
        f.sawOnFloor(6)
        f.used()
        #expect(f.loop.run == [14], "no interaction needed at all")
    }

    /// Two distinct colours in one room: attributing between them is a coin flip, and
    /// the app does not flip coins. The use stays unattributed and visible.
    @Test("two floor colours make the swallow unattributable")
    func twoColoursIsAmbiguous() {
        var f = Floor()
        f.sawOnFloor(3)
        f.sawOnFloor(9)
        f.used()
        #expect(f.loop.awaiting.isEmpty)
        #expect(f.loop.unidentified == 1, "counted, not guessed")
    }

    /// What was on the last room's floor says nothing about this one.
    @Test("a room change forgets the floor")
    func roomChangeForgets() {
        var f = Floor()
        f.sawOnFloor(5)
        f.newRoom()
        f.used()
        #expect(f.loop.unidentified == 1, "no stale answer crossed the door")
        #expect(f.loop.awaiting.isEmpty)
    }

    /// A slot read that DID see the pill wins over the floor deduction -- it is direct
    /// observation of the thing actually held.
    @Test("a held pill beats the floor deduction")
    func heldBeatsFloor() {
        var f = Floor()
        f.sawOnFloor(3)
        f.loop.sawInPocket(8)                          // the slot read caught it
        f.used()
        #expect(f.loop.awaiting == [8], "the observed colour, not the deduced one")
    }
}
