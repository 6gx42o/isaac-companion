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
    /// A pocket item that has been USED, rather than one being carried.
    ///
    /// The distinction is the difference between an inventory and a history, and only
    /// the history is what the numbers are made of. A pill in your pocket does nothing;
    /// swallowed, it changes a stat permanently and can never be dropped for another.
    /// So a consumed record never occupies a pocket slot and is never evicted to make
    /// room -- and it is the one that counts toward stats and transformations.
    public var consumed: Bool
    /// The floor this was picked up on, or nil for a hand-entered item whose floor
    /// nobody recorded. Stamped at pickup because the run moves on and the answer
    /// stops being recoverable the moment the next `Level::Init` arrives.
    public var stage: Int?
    public var stageType: Int?
    /// Picked up while the floor carried Curse of the Blind -- so it was taken without
    /// knowing what it was. Per FLOOR, not per run: the curse is rolled fresh each
    /// level, and a run-level flag would libel every later pickup.
    public var blind: Bool
    /// Arrived as part of a D4/D100-style reroll rather than off a pedestal. Inferred,
    /// never logged -- see `RunReducer.removalBurst`.
    public var rerolled: Bool
    public var id: Int { uid }

    public init(
        uid: Int, itemID: Int, name: String, manual: Bool = false, kind: ItemKind? = nil,
        consumed: Bool = false, stage: Int? = nil, stageType: Int? = nil,
        blind: Bool = false, rerolled: Bool = false
    ) {
        self.uid = uid; self.itemID = itemID; self.name = name; self.manual = manual
        self.kind = kind; self.consumed = consumed
        self.stage = stage; self.stageType = stageType
        self.blind = blind; self.rerolled = rerolled
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
    /// Every curse seen this run, in order. Kept for the run history, where "this run
    /// was cursed" is the interesting fact.
    public var curses: [String] = []
    /// Curses on the CURRENT floor only, cleared on each `Level::Init`. Isaac rolls
    /// curses per floor, so this -- not `curses` -- is what a live readout should show
    /// and what decides whether a pickup was taken blind.
    public var floorCurses: [String] = []
    /// True while this floor hides pedestal art.
    public var blindNow: Bool { floorCurses.contains { $0.localizedCaseInsensitiveContains("blind") } }
    public var items: [PickupRecord] = []
    /// bossIDs beaten this run, in order. The log reports these for every boss.
    public var bossesDefeated: [Int] = []
    /// Set when the run ends in death. Cleared on a new seed like everything else.
    public var death: DeathRecord?
    public var room: RoomType = .null
    public var roomVariant: Int = 0
    /// Pedestal positions logged for the current room. Cleared on room change.
    public var pedestals: [(x: Double, y: Double)] = []
    /// Pills lying on the floor of the current room. The log gives position but no
    /// subtype, so this is "a pill is there", not "which pill".
    public var pillsOnFloor: [(x: Double, y: Double)] = []
    /// How many times the pocket slot has been used this run. The log cannot say what
    /// was used, so this is the cue to go and look at the screen, not an answer.
    public var pocketUses: Int = 0
    public var gameRunning = false
    public var gameVersion: String?

    public init() {}

    public static func == (a: RunState, b: RunState) -> Bool {
        a.seed == b.seed && a.playerType == b.playerType && a.stage == b.stage
            && a.stageType == b.stageType && a.curses == b.curses
            && a.floorCurses == b.floorCurses && a.items == b.items
            && a.room == b.room && a.roomVariant == b.roomVariant
            && a.pedestals.count == b.pedestals.count
            && a.pillsOnFloor.count == b.pillsOnFloor.count && a.pocketUses == b.pocketUses
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

    /// How many collectibles were removed back-to-back, with no other event between.
    ///
    /// The log never says "you used a D4". What it does is emit every item's removal
    /// and then every replacement's addition, so a run of removals immediately followed
    /// by additions is the shape a reroll leaves behind. Two is the threshold because
    /// one removal followed by one addition is ambiguous -- plenty of things remove a
    /// single item -- and a missed mark is a smaller lie than a false one.
    ///
    /// Bounded by room and floor changes so a stale count can never reach across a
    /// pedestal pickup much later.
    private var removalBurst = 0
    /// Replacements still owed by the burst above, so every item of a five-item reroll
    /// gets marked and not just the first four.
    private var rerollCredits = 0

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
            removalBurst = 0; rerollCredits = 0

        case .playerInit(let t):
            state.playerType = t

        case .levelInit(let stage, let type):
            state.stage = stage
            state.stageType = type
            state.pedestals.removeAll()
            state.pillsOnFloor.removeAll()
            // Curses are rolled per floor. The log announces the new floor's curse
            // just after this line, so clearing here is what makes the next one mean
            // "on this floor" instead of "at some point this run".
            state.floorCurses.removeAll()
            removalBurst = 0; rerollCredits = 0

        case .roomEntered(let type, let variant):
            state.room = type
            state.roomVariant = variant
            state.pedestals.removeAll()
            state.pillsOnFloor.removeAll()
            removalBurst = 0; rerollCredits = 0

        case .pedestalSpawned(let x, let y):
            state.pedestals.append((x, y))

        case .pillSpawned(let x, let y):
            state.pillsOnFloor.append((x, y))

        // Tracked for the same reason pills are: the position says where to look. No
        // separate list yet because nothing reads one -- the event's job today is to
        // prompt a pocket read after the pickup.
        case .cardSpawned:
            break

        case .pocketItemUsed:
            state.pocketUses += 1

        case .itemAdded(let id, let name):
            // Latch the whole burst on the first replacement, rather than counting it
            // down directly: decrementing the burst itself drops below the threshold
            // partway through and leaves the last item of a five-item reroll unmarked.
            if removalBurst >= 2 {
                rerollCredits = removalBurst
                removalBurst = 0
            }
            let fromReroll = rerollCredits > 0
            if fromReroll { rerollCredits -= 1 }
            state.items.append(
                PickupRecord(
                    uid: nextUID, itemID: id, name: name,
                    stage: state.stage, stageType: state.stageType,
                    blind: state.blindNow, rerolled: fromReroll))
            nextUID += 1

        case .itemRemoved(let id):
            removalBurst += 1
            // Remove the most recent matching pickup, log-sourced ones first so a
            // manual correction is not silently undone by a later replay.
            if let i = state.items.lastIndex(where: { $0.itemID == id && !$0.manual })
                ?? state.items.lastIndex(where: { $0.itemID == id }) {
                state.items.remove(at: i)
            }

        case .curse(let c):
            if !state.curses.contains(c) { state.curses.append(c) }
            if !state.floorCurses.contains(c) { state.floorCurses.append(c) }

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

    /// Puts a previously-recorded pickup back, exactly as it was.
    ///
    /// Distinct from `manualAdd`: that one enforces slot capacity, because a person
    /// adding a second trinket by hand has probably made a mistake. This is replaying
    /// a build that was already valid when it was archived, so nothing is evicted and
    /// nothing is second-guessed. The uid is reassigned -- ids are per-session and the
    /// archived one means nothing here.
    public mutating func restore(_ record: PickupRecord, to state: inout RunState) {
        var r = record
        r.uid = nextUID
        nextUID += 1
        state.items.append(r)
    }

    /// `capacity` is how many of this section the run can hold right now -- 1 by
    /// default, 2 with Mom's Purse or Belly Button for trinkets, or one of the pocket
    /// items for cards/pills. The caller supplies it because RunState deliberately
    /// knows nothing about the item catalogue.
    public mutating func manualAdd(
        itemID: Int, name: String, kind: ItemKind? = nil, capacity: Int = 1,
        consumed: Bool = false, to state: inout RunState
    ) {
        // Slotted kinds do not stack indefinitely: once the slots are full the OLDEST
        // is dropped, matching what happens in game when you walk over a new trinket.
        //
        // CONSUMED items are exempt, in both directions: they hold no slot, and they are
        // never evicted to free one. Eating three pills used to leave the run holding
        // only the third, because each swallow displaced the last -- so two permanent
        // stat changes vanished from the numbers.
        if let kind, !kind.isAutoTracked, !consumed {
            var sameSection = state.items.filter {
                $0.kind?.section == kind.section && !$0.consumed
            }
            while sameSection.count >= max(1, capacity) {
                let oldest = sameSection.removeFirst()
                state.items.removeAll { $0.uid == oldest.uid }
            }
        }
        state.items.append(
            PickupRecord(
                uid: nextUID, itemID: itemID, name: name, manual: true, kind: kind,
                consumed: consumed))
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
