import Testing
@testable import IsaacCore

/// Every fixture line here was copied verbatim out of the real
/// ~/Library/Application Support/Binding of Isaac Afterbirth+/log.txt.
@Suite("LogParser - real AB+ log lines")
struct LogParserTests {
    let p = LogParser()

    @Test("Item pickup, AB+ plain form")
    func itemAdded() {
        #expect(p.parse(line: "[INFO] - Adding collectible 46 (Lucky Foot)")
            == .itemAdded(id: 46, name: "Lucky Foot"))
        #expect(p.parse(line: "[INFO] - Adding collectible 329 (The Ludovico Technique)")
            == .itemAdded(id: 329, name: "The Ludovico Technique"))
    }

    @Test("Repentance's ' to Player N' suffix does not corrupt the name")
    func repentanceSuffixTolerated() {
        #expect(p.parse(line: "[INFO] - Adding collectible 118 (Brimstone) to Player 0 (Isaac)")
            == .itemAdded(id: 118, name: "Brimstone"))
    }

    @Test("Item names containing parentheses survive")
    func nameWithParens() {
        #expect(p.parse(line: "[INFO] - Adding collectible 999 (Item (Special))")
            == .itemAdded(id: 999, name: "Item (Special)"))
    }

    @Test("Removal, seed, character, floor")
    func otherEvents() {
        #expect(p.parse(line: "[INFO] - Removing collectible 46 (Lucky Foot)")
            == .itemRemoved(id: 46))
        #expect(p.parse(line: "[INFO] - RNG Start Seed: ML3H JVH2 (1432161169)")
            == .runStarted(seed: "ML3H JVH2"))
        #expect(p.parse(line: "[INFO] - Initialized player with Variant 0 and Subtype 2")
            == .playerInit(playerType: 2))
        #expect(p.parse(line: "[INFO] - Level::Init m_Stage 1, m_StageType 0 Seed 4273504213")
            == .levelInit(stage: 1, stageType: 0))
        #expect(p.parse(line: "[INFO] - Isaac has shut down") == .shutdown)
    }

    @Test("Room lines carry the RoomType in the first field")
    func roomTypes() {
        #expect(p.parse(line: "[INFO] - Room 4.26( (copy))")
            == .roomEntered(type: .treasure, variant: 26))
        #expect(p.parse(line: "[INFO] - Room 1.2(Start Room)")
            == .roomEntered(type: .normal, variant: 2))
        #expect(p.parse(line: "[INFO] - Room 14.0()")
            == .roomEntered(type: .devil, variant: 0))
        #expect(RoomType.treasure.offersChoice)
        #expect(RoomType.devil.offersChoice)
        #expect(!RoomType.normal.offersChoice)
    }

    @Test("Pedestal spawns give a position but never an item id")
    func pedestal() {
        #expect(p.parse(line: "[INFO] - Spawn Entity with Type(5), Variant(100), Pos(320.00,280.00)")
            == .pedestalSpawned(x: 320, y: 280))
        // Any other entity type is noise.
        #expect(p.parse(line: "[INFO] - Spawn Entity with Type(85), Variant(0), Pos(80.00,160.00)")
            == nil)
    }

    @Test("Version banner and noise")
    func versionAndNoise() {
        #expect(p.parse(line: "[INFO] - Binding of Isaac: Afterbirth+ v1.06.T1")
            == .gameVersion("Afterbirth+ v1.06.T1"))
        #expect(p.parse(line: "[INFO] - Lua mem usage: 9113 KB and 386 bytes") == nil)
        #expect(p.parse(line: "") == nil)
        #expect(p.parse(line: "[ASSERT] - Bad Index!") == nil)
    }
}

@Suite("RunReducer")
struct RunReducerTests {

    @Test("A new seed resets the previous run entirely")
    func twoRunsInOneFile() {
        var r = RunReducer()
        let events = LogParser().parse(lines: """
            [INFO] - RNG Start Seed: AAAA BBBB (1)
            [INFO] - Initialized player with Variant 0 and Subtype 0
            [INFO] - Adding collectible 1 (The Sad Onion)
            [INFO] - RNG Start Seed: CCCC DDDD (2)
            [INFO] - Initialized player with Variant 0 and Subtype 3
            [INFO] - Adding collectible 118 (Brimstone)
            """)
        let s = r.replay(events)
        #expect(s.seed == "CCCC DDDD")
        #expect(s.playerType == 3)
        #expect(s.items.count == 1)
        #expect(s.items.first?.itemID == 118)
    }

    @Test("Manual corrections survive a removal event")
    func manualCorrections() {
        var r = RunReducer()
        var s = RunState()
        r.apply(.itemAdded(id: 46, name: "Lucky Foot"), to: &s)
        r.manualAdd(itemID: 118, name: "Brimstone", to: &s)
        #expect(s.items.count == 2)
        #expect(s.items.last?.manual == true)

        r.manualRemove(uid: s.items.last!.uid, from: &s)
        #expect(s.items.count == 1)
        #expect(s.items.first?.itemID == 46)
    }

    @Test("Removal prefers a log-sourced copy over a manual one")
    func removalPrefersLogSourced() {
        var r = RunReducer()
        var s = RunState()
        r.manualAdd(itemID: 46, name: "Lucky Foot", to: &s)
        r.apply(.itemAdded(id: 46, name: "Lucky Foot"), to: &s)
        r.apply(.itemRemoved(id: 46), to: &s)
        #expect(s.items.count == 1)
        #expect(s.items.first?.manual == true)
    }

    @Test("Room change clears stale pedestals")
    func pedestalsClearOnRoomChange() {
        var r = RunReducer()
        var s = RunState()
        r.apply(.roomEntered(type: .treasure, variant: 26), to: &s)
        r.apply(.pedestalSpawned(x: 320, y: 280), to: &s)
        #expect(s.pedestals.count == 1)
        r.apply(.roomEntered(type: .normal, variant: 2), to: &s)
        #expect(s.pedestals.isEmpty)
        #expect(s.room == .normal)
    }

    @Test("Curses are recorded once")
    func curses() {
        var r = RunReducer()
        var s = RunState()
        r.apply(.curse("Curse of the Labyrinth"), to: &s)
        r.apply(.curse("Curse of the Labyrinth"), to: &s)
        #expect(s.curses == ["Curse of the Labyrinth"])
    }
}
