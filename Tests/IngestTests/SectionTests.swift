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

    /// This used to assert that pills carry no stat delta, which is how a Speed Up pill
    /// came to change nothing at all -- even when entered by hand. Eight pills move a
    /// stat permanently and say the number in their own text.
    @Test("Exactly the eight stat pills carry a delta; cards carry none")
    func pillDeltas() {
        let expected: [Int: String] = [
            11: "range", 12: "range", 13: "speed", 14: "speed",
            15: "tears", 16: "tears", 17: "luck", 18: "luck",
        ]
        for item in bundle.items where item.kind == .pill {
            if let stat = expected[item.id] {
                #expect(!item.delta.isEmpty, "\(item.name) should move \(stat)")
            } else {
                #expect(
                    item.delta.isEmpty,
                    "\(item.name) has no permanent stat change, got \(item.delta)")
            }
        }
        // Cards are instant or last "for the room", so TextDelta must refuse them all.
        for item in bundle.items where item.kind == .card {
            #expect(item.delta.isEmpty, "\(item.name) should have no permanent delta")
        }
    }

    @Test("Cards and pills are in no item pool")
    func noPools() {
        for item in bundle.items where item.kind == .card || item.kind == .pill {
            #expect(item.pools.isEmpty, "\(item.name) is not in an item pool")
        }
    }

    /// The four stat pills that go up must be exactly cancelled by the four that go down
    /// having the opposite sign -- a sign error here would read as a buff.
    @Test("Down pills go down")
    func downPillsGoDown() {
        func delta(_ id: Int) -> ItemDelta? {
            bundle.items.first { $0.kind == .pill && $0.id == id }?.delta
        }
        #expect((delta(11)?.range ?? 0) < 0, "Range Down")
        #expect((delta(12)?.range ?? 0) > 0, "Range Up")
        #expect((delta(13)?.speed ?? 0) < 0, "Speed Down")
        #expect((delta(14)?.speed ?? 0) > 0, "Speed Up")
        #expect((delta(15)?.tears ?? 0) < 0, "Tears Down")
        #expect((delta(16)?.tears ?? 0) > 0, "Tears Up")
        #expect((delta(17)?.luck ?? 0) < 0, "Luck Down")
        #expect((delta(18)?.luck ?? 0) > 0, "Luck Up")
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

@Suite("Used pills reach the numbers", .enabled(if: loaded != nil, "no built bundle"))
struct ConsumedPillStatsTests {
    let bundle = loaded!

    /// The whole point of tracking uses rather than holdings: a swallowed Speed Up must
    /// move the speed stat, and three of them must move it three times. Before, pills
    /// were excluded from the stat engine entirely AND displaced each other in the
    /// pocket slot, so the answer was 1.00 no matter how many you ate.
    @Test("three Speed Up pills move speed three times")
    func speedPillsAccumulate() {
        guard let speedUp = bundle.items.first(where: { $0.kind == .pill && $0.id == 14 })
        else {
            Issue.record("no Speed Up pill in the bundle")
            return
        }
        #expect(speedUp.delta.speed == 0.15, "Speed Up is +0.15")

        let isaac = Character(id: 0, name: "Isaac")
        let one = StatEngine.compute(character: isaac, items: [speedUp])
        let three = StatEngine.compute(character: isaac, items: [speedUp, speedUp, speedUp])
        #expect(abs(one.speed.value - 1.15) < 0.001, "one pill: \(one.speed.value)")
        #expect(abs(three.speed.value - 1.45) < 0.001, "three pills: \(three.speed.value)")
    }

    /// Range Down must go DOWN, since a sign error here would read as a buff.
    @Test("a Range Down pill lowers range")
    func downPillLowersStat() {
        guard let rangeDown = bundle.items.first(where: { $0.kind == .pill && $0.id == 11 })
        else { return }
        let isaac = Character(id: 0, name: "Isaac")
        let after = StatEngine.compute(character: isaac, items: [rangeDown])
        #expect(after.range.value < 23.75, "range \(after.range.value) should be below base")
    }
}
