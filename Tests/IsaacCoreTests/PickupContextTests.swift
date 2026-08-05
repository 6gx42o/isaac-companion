import Testing
import Foundation
@testable import IsaacCore

/// The three things the log does NOT say about a pickup, reconstructed from context:
/// which floor it happened on, whether the floor was blind at the time, and whether it
/// arrived as a reroll. Two of the three are inference, so they are tested for what
/// they must NOT claim as hard as for what they should.
@Suite("Pickup context")
struct PickupContextTests {

    private func run(_ events: [RunEvent]) -> RunState {
        var reducer = RunReducer()
        var state = RunState()
        for e in events { reducer.apply(e, to: &state) }
        return state
    }

    @Test("Each pickup remembers the floor it happened on")
    func floorStamped() {
        let state = run([
            .runStarted(seed: "AAAA BBBB"),
            .levelInit(stage: 1, stageType: 0),
            .itemAdded(id: 1, name: "The Sad Onion"),
            .levelInit(stage: 3, stageType: 1),
            .itemAdded(id: 2, name: "The Inner Eye"),
        ])
        #expect(state.items.count == 2)
        #expect(state.items[0].stage == 1)
        #expect(state.items[0].stageType == 0)
        #expect(state.items[1].stage == 3, "picked up on Caves, not Basement")
        #expect(state.items[1].stageType == 1)
    }

    /// The bug this guards: curses accumulate over a whole run, so asking the run-level
    /// list whether the floor is blind answers "yes" for every floor after the cursed
    /// one -- marking items you could see perfectly well as blind pickups.
    @Test("Blind is per floor and does not leak into the next one")
    func blindDoesNotLeak() {
        let state = run([
            .runStarted(seed: "AAAA BBBB"),
            .levelInit(stage: 1, stageType: 0),
            .curse("Curse of Blind"),
            .itemAdded(id: 1, name: "taken blind"),
            .levelInit(stage: 2, stageType: 0),
            .itemAdded(id: 2, name: "seen clearly"),
        ])
        #expect(state.items[0].blind, "floor 1 was blind")
        #expect(!state.items[1].blind, "floor 2 was not, and must not inherit it")
        #expect(!state.blindNow, "the live flag follows the current floor")
        #expect(state.curses == ["Curse of Blind"], "the run history still remembers it")
        #expect(state.floorCurses.isEmpty, "but this floor is clean")
    }

    @Test("A different curse does not read as blind")
    func otherCursesAreNotBlind() {
        let state = run([
            .runStarted(seed: "AAAA BBBB"),
            .levelInit(stage: 1, stageType: 0),
            .curse("Curse of the Lost"),
            .itemAdded(id: 1, name: "The Sad Onion"),
        ])
        #expect(!state.items[0].blind)
        #expect(!state.blindNow)
    }

    /// A D4 removes everything then re-adds everything. Every replacement must be
    /// marked -- an earlier version counted the burst down directly, which dropped
    /// below the threshold partway and left the last item unmarked.
    @Test("A whole reroll is marked, including its last item")
    func rerollMarksEveryReplacement() {
        var events: [RunEvent] = [
            .runStarted(seed: "AAAA BBBB"), .levelInit(stage: 1, stageType: 0),
        ]
        for id in 1...5 { events.append(.itemAdded(id: id, name: "before \(id)")) }
        for id in 1...5 { events.append(.itemRemoved(id: id)) }
        for id in 11...15 { events.append(.itemAdded(id: id, name: "after \(id)")) }
        let state = run(events)

        #expect(state.items.count == 5)
        let marked = state.items.filter(\.rerolled).count
        #expect(marked == 5, "all five replacements are rerolls, got \(marked)")
        #expect(state.items.map(\.itemID) == [11, 12, 13, 14, 15])
    }

    /// The conservative half of the heuristic. One removal followed by one addition is
    /// not distinguishable from an ordinary pickup, so it must not be claimed as one.
    @Test("A single removal is not a reroll")
    func singleRemovalIsNotAReroll() {
        let state = run([
            .runStarted(seed: "AAAA BBBB"),
            .levelInit(stage: 1, stageType: 0),
            .itemAdded(id: 1, name: "The Sad Onion"),
            .itemRemoved(id: 1),
            .itemAdded(id: 2, name: "The Inner Eye"),
        ])
        #expect(state.items.count == 1)
        #expect(!state.items[0].rerolled, "one-for-one is ambiguous; do not guess")
    }

    /// Without this bound, a burst on one floor could still be crediting rerolls to a
    /// pedestal picked up several rooms later.
    @Test("A burst does not reach across a room or floor change")
    func burstIsBounded() {
        let state = run([
            .runStarted(seed: "AAAA BBBB"),
            .levelInit(stage: 1, stageType: 0),
            .itemAdded(id: 1, name: "a"), .itemAdded(id: 2, name: "b"),
            .itemRemoved(id: 1), .itemRemoved(id: 2),
            .roomEntered(type: .treasure, variant: 0),
            .itemAdded(id: 3, name: "an ordinary pedestal"),
        ])
        #expect(state.items.count == 1)
        #expect(!state.items[0].rerolled, "a new room ends the burst")
    }

    @Test("A new run clears the context")
    func newRunClears() {
        let state = run([
            .runStarted(seed: "AAAA BBBB"),
            .levelInit(stage: 4, stageType: 0),
            .curse("Curse of Blind"),
            .itemAdded(id: 1, name: "a"), .itemAdded(id: 2, name: "b"),
            .itemRemoved(id: 1), .itemRemoved(id: 2),
            .runStarted(seed: "CCCC DDDD"),
            .levelInit(stage: 1, stageType: 0),
            .itemAdded(id: 3, name: "fresh"),
        ])
        #expect(state.items.count == 1)
        #expect(state.items[0].stage == 1)
        #expect(!state.items[0].blind)
        #expect(!state.items[0].rerolled)
        #expect(state.floorCurses.isEmpty)
    }
}
