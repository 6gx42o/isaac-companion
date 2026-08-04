import Testing
import Foundation
@testable import Ingest
@testable import IsaacCore

@Suite("Slot grants")
struct SlotGrantTests {

    @Test("Reads capacity out of EID's own wording")
    func parses() {
        #expect(
            SlotGrants.parse(text: "{{Trinket}} Isaac can hold 2 trinkets")
                == SlotGrant(section: .trinkets, capacity: 2))
        #expect(
            SlotGrants.parse(text: "{{Trinket}} Allows Isaac to carry 2 trinkets#Spawns a trinket")
                == SlotGrant(section: .trinkets, capacity: 2))
        // "two" spelled out, and the noun is a rune rather than a card.
        #expect(
            SlotGrants.parse(text: "Allows Isaac to carry two runes/cards/pills")
                == SlotGrant(section: .consumables, capacity: 2))
        #expect(
            SlotGrants.parse(text: "Isaac can carry 2 cards#Turns all pills into cards")
                == SlotGrant(section: .consumables, capacity: 2))
    }

    /// Schoolbag is an Afterbirth+ item, not just a Repentance one -- it is in the
    /// game's own items.xml with achievement 379. The parser knew about trinkets and
    /// pocket items and silently ignored it, so a second active never showed.
    @Test("Reads the active-item slot too")
    func activeSlot() {
        #expect(
            SlotGrants.parse(
                text: "Allows Isaac to hold 2 active items#The items can be swapped")
                == SlotGrant(section: .actives, capacity: 2))
    }

    @Test("Does not fire on items that merely mention a trinket or card")
    func noFalsePositives() {
        #expect(SlotGrants.parse(text: "Spawns a random trinket") == nil)
        #expect(SlotGrants.parse(text: "{{Card}} Spawns 1 card on pickup") == nil)
        #expect(
            SlotGrants.parse(text: "Triggers the effect of the card Isaac holds") == nil)
        #expect(SlotGrants.parse(text: "↑ {{Damage}} +1 Damage") == nil)
        // A stated capacity of 1 widens nothing.
        #expect(SlotGrants.parse(text: "Isaac can hold 1 trinket") == nil)
    }

    @Test("The built bundle finds exactly the six AB+ slot items")
    func inBundle() throws {
        guard let bundle = try? Pipeline.load().0 else { return }
        let granting = bundle.items.filter { $0.slots != nil }
        let ids = Set(granting.map(\.id))
        // Trinkets: Mom's Purse, Belly Button.
        #expect(ids.contains(139))
        #expect(ids.contains(458))
        // Pocket: Starter Deck, Little Baggy, Deep Pockets, Polydactyly.
        #expect(ids.isSuperset(of: [251, 252, 416, 454]))
        // Schoolbag: the active-item slot.
        #expect(ids.contains(534))
        #expect(granting.count == 7, "unexpected extras: \(granting.map(\.name))")

        #expect(bundle.items.first { $0.id == 139 }?.slots?.section == .trinkets)
        #expect(bundle.items.first { $0.id == 416 }?.slots?.section == .consumables)
    }
}

@Suite("Slot capacity")
struct SlotCapacityTests {

    @Test("One slot by default: a second trinket replaces the first")
    func defaultOneSlot() {
        var reducer = RunReducer()
        var state = RunState()
        reducer.manualAdd(itemID: 23, name: "Missing Poster", kind: .trinket, to: &state)
        reducer.manualAdd(itemID: 45, name: "Cancer", kind: .trinket, capacity: 1, to: &state)
        #expect(state.items.count == 1)
        #expect(state.items.first?.name == "Cancer")
    }

    @Test("With capacity 2 both trinkets are kept")
    func twoSlots() {
        var reducer = RunReducer()
        var state = RunState()
        reducer.manualAdd(itemID: 23, name: "Missing Poster", kind: .trinket, capacity: 2, to: &state)
        reducer.manualAdd(itemID: 45, name: "Cancer", kind: .trinket, capacity: 2, to: &state)
        #expect(state.items.count == 2)
        #expect(state.items.map(\.name) == ["Missing Poster", "Cancer"])

        // A third evicts the OLDEST, as walking over a trinket does in game.
        reducer.manualAdd(itemID: 88, name: "Blister", kind: .trinket, capacity: 2, to: &state)
        #expect(state.items.count == 2)
        #expect(state.items.map(\.name) == ["Cancer", "Blister"])
    }

    @Test("Trinket and pocket slots are independent")
    func independentSections() {
        var reducer = RunReducer()
        var state = RunState()
        reducer.manualAdd(itemID: 23, name: "Missing Poster", kind: .trinket, capacity: 1, to: &state)
        reducer.manualAdd(itemID: 1, name: "0 - The Fool", kind: .card, capacity: 2, to: &state)
        reducer.manualAdd(itemID: 0, name: "Bad Gas", kind: .pill, capacity: 2, to: &state)
        // Cards and pills share the pocket slot, so 2 there plus 1 trinket.
        #expect(state.items.count == 3)

        // Filling the pocket further evicts only a pocket item, never the trinket.
        reducer.manualAdd(itemID: 2, name: "I - The Magician", kind: .card, capacity: 2, to: &state)
        #expect(state.items.count == 3)
        #expect(state.items.contains { $0.name == "Missing Poster" })
        #expect(!state.items.contains { $0.name == "0 - The Fool" })
    }

    @Test("Collectibles are never evicted by slot limits")
    func collectiblesUnaffected() {
        var reducer = RunReducer()
        var state = RunState()
        for id in 1...5 { reducer.manualAdd(itemID: id, name: "Item \(id)", to: &state) }
        reducer.manualAdd(itemID: 23, name: "Missing Poster", kind: .trinket, to: &state)
        reducer.manualAdd(itemID: 45, name: "Cancer", kind: .trinket, to: &state)
        #expect(state.items.filter { $0.kind == nil }.count == 5)
        #expect(state.items.filter { $0.kind == .trinket }.count == 1)
    }
}
