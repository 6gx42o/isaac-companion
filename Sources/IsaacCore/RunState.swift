import Foundation

public struct PickupRecord: Sendable, Equatable, Identifiable {
    public var uid: Int
    public var itemID: Int
    public var name: String
    /// True when the user added it by hand. Manual entries survive a log replay,
    /// which is what makes D4/D100 rerolls correctable -- the log does not record
    /// enough to reconstruct those on its own.
    public var manual: Bool
    /// nil means "a collectible, announced by the log" -- resolve it by id against the
    /// item bundle. Set explicitly for hand-entered trinkets, cards and pills, whose
    /// ids collide with collectible ids (card 1, pill 1 and collectible 1 all exist).
    public var kind: ItemKind?
    public var id: Int { uid }

    public init(
        uid: Int, itemID: Int, name: String, manual: Bool = false, kind: ItemKind? = nil
    ) {
        self.uid = uid; self.itemID = itemID; self.name = name; self.manual = manual
        self.kind = kind
    }
}

/// One death, as the log recorded it.
public struct DeathRecord: Sendable, Equatable {
    public var killedBy: EntityRef
    public var spawnedBy: EntityRef?
    public var stage: Int
    public init(killedBy: EntityRef, spawnedBy: EntityRef?, stage: Int) {
        self.killedBy = killedBy; self.spawnedBy = spawnedBy; self.stage = stage
    }
}

public struct RunState: Sendable, Equatable {
    public var seed: String?
    public var playerType: Int?
    public var stage: Int = 1
    public var stageType: Int = 0
    public var curses: [String] = []
    public var items: [PickupRecord] = []
    /// bossIDs beaten this run, in order. The log reports these for every boss.
    public var bossesDefeated: [Int] = []
    /// Set when the run ends in death. Cleared on a new seed like everything else.
    public var death: DeathRecord?
    public var room: RoomType = .null
    public var roomVariant: Int = 0
    /// Pedestal positions logged for the current room. Cleared on room change.
    public var pedestals: [(x: Double, y: Double)] = []
    public var gameRunning = false
    public var gameVersion: String?

    public init() {}

    public static func == (a: RunState, b: RunState) -> Bool {
        a.seed == b.seed && a.playerType == b.playerType && a.stage == b.stage
            && a.stageType == b.stageType && a.curses == b.curses && a.items == b.items
            && a.room == b.room && a.roomVariant == b.roomVariant
            && a.pedestals.count == b.pedestals.count
            && a.gameRunning == b.gameRunning && a.gameVersion == b.gameVersion
    }
}

/// Folds log events into the current run.
///
/// Deliberately tolerant: the log is a diagnostic stream, not an API. Anything it
/// cannot express (rerolls, most removals) is handled by manual corrections rather
/// than by guessing.
public struct RunReducer: Sendable {
    private var nextUID = 1
    private var manualLog: [(itemID: Int, name: String, removed: Bool)] = []

    public init() {}

    public mutating func apply(_ event: RunEvent, to state: inout RunState) {
        switch event {
        case .gameVersion(let v):
            state.gameVersion = v
            state.gameRunning = true

        case .runStarted(let seed):
            // A DIFFERENT seed means a new run: drop everything, including manual edits.
            //
            // The same seed repeated does not. This used to reset unconditionally, which
            // the Rust port has always guarded against -- the two implementations of the
            // same reducer disagreed, and this one was the riskier of the two: a repeated
            // seed line would silently wipe the build and every number after it would be
            // wrong. It also now decides when a run is archived, so an unconditional
            // reset would file the same run twice and lose the second half.
            let isSameRun = state.seed == seed
            guard !isSameRun else {
                state.gameRunning = true
                return
            }
            state = RunState()
            state.seed = seed
            state.gameRunning = true
            manualLog.removeAll()

        case .playerInit(let t):
            state.playerType = t

        case .levelInit(let stage, let type):
            state.stage = stage
            state.stageType = type
            state.pedestals.removeAll()

        case .roomEntered(let type, let variant):
            state.room = type
            state.roomVariant = variant
            state.pedestals.removeAll()

        case .pedestalSpawned(let x, let y):
            state.pedestals.append((x, y))

        case .itemAdded(let id, let name):
            state.items.append(PickupRecord(uid: nextUID, itemID: id, name: name))
            nextUID += 1

        case .itemRemoved(let id):
            // Remove the most recent matching pickup, log-sourced ones first so a
            // manual correction is not silently undone by a later replay.
            if let i = state.items.lastIndex(where: { $0.itemID == id && !$0.manual })
                ?? state.items.lastIndex(where: { $0.itemID == id }) {
                state.items.remove(at: i)
            }

        case .curse(let c):
            if !state.curses.contains(c) { state.curses.append(c) }

        case .died(let killedBy, let spawnedBy):
            state.death = DeathRecord(
                killedBy: killedBy, spawnedBy: spawnedBy, stage: state.stage)
        case .bossDefeated(let bossID):
            // The same boss can be re-logged if a room is re-entered; only new ones count.
            if !state.bossesDefeated.contains(bossID) { state.bossesDefeated.append(bossID) }
        case .shutdown:
            state.gameRunning = false
        }
    }

    /// `capacity` is how many of this section the run can hold right now -- 1 by
    /// default, 2 with Mom's Purse or Belly Button for trinkets, or one of the pocket
    /// items for cards/pills. The caller supplies it because RunState deliberately
    /// knows nothing about the item catalogue.
    public mutating func manualAdd(
        itemID: Int, name: String, kind: ItemKind? = nil, capacity: Int = 1,
        to state: inout RunState
    ) {
        // Slotted kinds do not stack indefinitely: once the slots are full the OLDEST
        // is dropped, matching what happens in game when you walk over a new trinket.
        if let kind, !kind.isAutoTracked {
            var sameSection = state.items.filter { $0.kind?.section == kind.section }
            while sameSection.count >= max(1, capacity) {
                let oldest = sameSection.removeFirst()
                state.items.removeAll { $0.uid == oldest.uid }
            }
        }
        state.items.append(
            PickupRecord(uid: nextUID, itemID: itemID, name: name, manual: true, kind: kind))
        nextUID += 1
    }

    public mutating func manualRemove(uid: Int, from state: inout RunState) {
        state.items.removeAll { $0.uid == uid }
    }

    /// Replays a whole log from scratch. Used on attach so launching mid-run still
    /// reconstructs the current inventory.
    public mutating func replay(_ events: [RunEvent]) -> RunState {
        var state = RunState()
        for e in events { apply(e, to: &state) }
        return state
    }
}
