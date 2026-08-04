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

@Suite("RunReducer - repeated seeds")
struct RepeatedSeedTests {
    @Test("The same seed announced twice does not wipe the build")
    func sameSeedKeepsTheRun() {
        // The Swift and Rust reducers disagreed here: Rust guarded on the seed being
        // different, Swift reset unconditionally. Swift's version was the riskier one --
        // a repeated seed line silently emptied the build and every stat after it was
        // wrong. It also decides when a run is archived, so resetting on a repeat filed
        // the same run twice.
        var state = RunState()
        var reducer = RunReducer()
        for event in LogParser().parse(lines: """
            RNG Start Seed: ML3H JVH2 (12345)
            Initialized player with Variant 0 and Subtype 2
            Adding collectible 1 (The Sad Onion)
            Adding collectible 149 (Ipecac)
            RNG Start Seed: ML3H JVH2 (12345)
            """) {
            reducer.apply(event, to: &state)
        }
        #expect(state.seed == "ML3H JVH2")
        #expect(state.items.map(\.name) == ["The Sad Onion", "Ipecac"])
        #expect(state.playerType == 2)
    }

    @Test("A different seed still starts a clean run")
    func differentSeedResets() {
        var state = RunState()
        var reducer = RunReducer()
        for event in LogParser().parse(lines: """
            RNG Start Seed: ML3H JVH2 (12345)
            Adding collectible 1 (The Sad Onion)
            RNG Start Seed: 8LV7 AYCP (999)
            """) {
            reducer.apply(event, to: &state)
        }
        #expect(state.seed == "8LV7 AYCP")
        #expect(state.items.isEmpty)
    }
}

@Suite("LogParser - pills")
struct PillLogTests {
    /// Everything the log will ever tell us about a pill, which is less than you would
    /// hope: that one exists, where it is, and that the pocket slot was used. Never
    /// which colour, and never which effect -- the spawn line carries no subtype.
    @Test("a pill on the floor is a pickup of variant 70")
    func pillSpawn() {
        let p = LogParser()
        #expect(
            p.parse(line: "[INFO] - Spawn Entity with Type(5), Variant(70), Pos(320.00,280.00)")
                == .pillSpawned(x: 320, y: 280))
        // Variant 100 is a collectible pedestal and must not be read as a pill.
        #expect(
            p.parse(line: "Spawn Entity with Type(5), Variant(100), Pos(320.00,280.00)")
                == .pedestalSpawned(x: 320, y: 280))
        // Nor may a heart (10), a coin (20) or a chest (60).
        for v in [10, 20, 60] {
            #expect(
                p.parse(line: "Spawn Entity with Type(5), Variant(\(v)), Pos(80.00,160.00)") == nil,
                "variant \(v) is not a pill")
        }
    }

    @Test("a card on the floor is a pickup of variant 300")
    func cardSpawn() {
        let p = LogParser()
        #expect(
            p.parse(line: "[INFO] - Spawn Entity with Type(5), Variant(300), Pos(320.00,280.00)")
                == .cardSpawned(x: 320, y: 280))
        // Trinkets (350) are floor loot, not pocket consumables -- not a card.
        #expect(
            p.parse(line: "Spawn Entity with Type(5), Variant(350), Pos(320.00,280.00)") == nil)
    }

    @Test("using the pocket slot is announced, without saying what was used")
    func pocketUse() {
        let p = LogParser()
        #expect(p.parse(line: "[INFO] - Action PillCard Triggered") == .pocketItemUsed)
        #expect(p.parse(line: "Action PillCard Triggered") == .pocketItemUsed)
        #expect(p.parse(line: "Action Something Else") == nil)
    }
}
