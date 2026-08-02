import Testing
import Foundation
@testable import Ingest
@testable import IsaacCore

private let loaded = try? Pipeline.load().0

@Suite(.enabled(if: loaded != nil, "no built bundle"))
struct CardPillTests {
    let bundle = loaded!

    @Test("Cards and pills are ingested alongside collectibles")
    func present() {
        let cards = bundle.items.filter { $0.kind == .card }
        let pills = bundle.items.filter { $0.kind == .pill }
        #expect(cards.count == 54, "AB+ has 54 cards/runes, got \(cards.count)")
        #expect(pills.count == 47, "AB+ has 47 pill effects, got \(pills.count)")
        #expect(cards.allSatisfy { !$0.text.isEmpty })
        #expect(pills.allSatisfy { !$0.text.isEmpty })
    }

    @Test("Ids collide across kinds, so kind is load-bearing")
    func idsCollide() {
        // This is the whole reason PickupRecord carries a kind: looking up by id
        // alone would hand back the wrong entity entirely.
        let byKind = Dictionary(grouping: bundle.items, by: \.kind)
        let card1 = byKind[.card]?.first { $0.id == 1 }
        let pill1 = byKind[.pill]?.first { $0.id == 1 }
        let collectible1 = byKind[.passive]?.first { $0.id == 1 }
        #expect(card1?.name == "0 - The Fool")
        #expect(pill1?.name == "Bad Trip")
        #expect(collectible1?.name == "The Sad Onion")
        #expect(card1?.name != collectible1?.name)
    }

    @Test("Cards and pills carry no stat deltas and no pools")
    func inert() {
        for item in bundle.items where item.kind == .card || item.kind == .pill {
            #expect(item.delta.isEmpty, "\(item.name) should have no permanent delta")
            #expect(item.pools.isEmpty, "\(item.name) is not in an item pool")
        }
    }

    @Test("Only collectibles are auto-tracked")
    func autoTracking() {
        #expect(ItemKind.passive.isAutoTracked)
        #expect(ItemKind.active.isAutoTracked)
        #expect(ItemKind.familiar.isAutoTracked)
        // The log emits no line at all for these, so they can only be entered by hand.
        #expect(!ItemKind.trinket.isAutoTracked)
        #expect(!ItemKind.card.isAutoTracked)
        #expect(!ItemKind.pill.isAutoTracked)
    }

    @Test("Sections group the kinds as the run view expects")
    func sections() {
        #expect(ItemKind.passive.section == .passives)
        #expect(ItemKind.active.section == .actives)
        #expect(ItemKind.familiar.section == .familiars)
        #expect(ItemKind.trinket.section == .trinkets)
        #expect(ItemKind.card.section == .consumables)
        #expect(ItemKind.pill.section == .consumables)
        // Manual-only sections must explain themselves; auto ones need no note.
        #expect(ItemSection.passives.note == nil)
        #expect(ItemSection.trinkets.note != nil)
        #expect(ItemSection.consumables.note != nil)
    }
}

@Suite("Manual pickups")
struct ManualPickupTests {

    @Test("Single-slot kinds replace rather than stack")
    func singleSlots() {
        var reducer = RunReducer()
        var state = RunState()
        // One trinket slot and one pocket slot: a second card replaces the first.
        reducer.manualAdd(itemID: 1, name: "0 - The Fool", kind: .card, to: &state)
        reducer.manualAdd(itemID: 2, name: "I - The Magician", kind: .card, to: &state)
        #expect(state.items.count == 1)
        #expect(state.items.first?.name == "I - The Magician")

        // A pill shares the pocket slot with cards, so it replaces the card too.
        reducer.manualAdd(itemID: 0, name: "Bad Gas", kind: .pill, to: &state)
        #expect(state.items.count == 1)
        #expect(state.items.first?.kind == .pill)

        // A trinket is a different slot and coexists.
        reducer.manualAdd(itemID: 23, name: "Missing Poster", kind: .trinket, to: &state)
        #expect(state.items.count == 2)
    }

    @Test("Collectibles still stack normally")
    func collectiblesStack() {
        var reducer = RunReducer()
        var state = RunState()
        reducer.manualAdd(itemID: 1, name: "The Sad Onion", to: &state)
        reducer.manualAdd(itemID: 2, name: "The Inner Eye", to: &state)
        reducer.manualAdd(itemID: 1, name: "The Sad Onion", to: &state)
        #expect(state.items.count == 3, "collectibles stack; nothing should be replaced")
        #expect(state.items.allSatisfy { $0.kind == nil })
    }
}
