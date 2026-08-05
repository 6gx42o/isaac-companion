import Foundation

/// A finished run, kept after the game has closed.
///
/// Everything about a run used to live in memory and die with the process: start a second
/// run and the first was simply overwritten, quit and it was gone. This is the record that
/// survives.
///
/// Deliberately a flat snapshot rather than a reference to a `RunState`: the point is to
/// still be readable in a year, after the item ids, the stat model and `RunState` itself
/// have all moved on. Names are resolved at write time for the same reason.
public struct RunSummary: Codable, Sendable, Equatable, Identifiable {
    /// Stable across writes: derived from the start time, which is when the run began
    /// rather than when it was archived.
    public var id: String
    public var startedAt: Date
    public var endedAt: Date?

    public var seed: String?
    public var characterID: Int?
    public var characterName: String
    public var finalStage: Int
    public var finalStageType: Int
    public var curses: [String]

    /// Pickup order, which is the order the stat model composes in.
    public var items: [Item]
    public var bosses: [String]
    /// Already turned into prose ("Killed by Monstro"); the entity ids behind it are a
    /// detail of the bestiary, not of the run.
    public var death: String?
    public var outcome: Outcome

    /// The seven stats as they stood at the end. Stored as text so a future change to
    /// the stat model cannot retroactively rewrite what a past run said.
    public var finalStats: [Stat]

    public struct Item: Codable, Sendable, Equatable {
        public var id: Int
        public var name: String
        public var manual: Bool
        /// Everything below is optional so archives written before these existed still
        /// decode. nil means "this record predates the field", not "false".
        ///
        /// `kind` and `consumed` are load-bearing rather than decorative: ids collide
        /// across kinds (card 1, pill 1 and collectible 1 are three different things),
        /// and a swallowed pill is what the stat model counts. Restoring a run without
        /// them would rebuild it wrong.
        public var kind: String?
        public var consumed: Bool?
        public var stage: Int?
        public var blind: Bool?
        public var rerolled: Bool?
        public init(
            id: Int, name: String, manual: Bool, kind: String? = nil,
            consumed: Bool? = nil, stage: Int? = nil, blind: Bool? = nil,
            rerolled: Bool? = nil
        ) {
            self.id = id; self.name = name; self.manual = manual
            self.kind = kind; self.consumed = consumed
            self.stage = stage; self.blind = blind; self.rerolled = rerolled
        }
    }

    public struct Stat: Codable, Sendable, Equatable {
        public var key: String
        public var value: Double
        public var base: Double
        public var approx: Bool
        public init(key: String, value: Double, base: Double, approx: Bool) {
            self.key = key; self.value = value; self.base = base; self.approx = approx
        }
    }

    public enum Outcome: String, Codable, Sendable {
        /// Still going. Written by the periodic checkpoint so a crash loses a minute
        /// rather than the whole run.
        case inProgress
        case died
        /// Isaac, Satan or Mega Satan went down.
        case won
        /// The game closed, or a new run started, without either.
        case abandoned
    }

    public var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }

    public init(
        id: String, startedAt: Date, endedAt: Date? = nil, seed: String?,
        characterID: Int?, characterName: String, finalStage: Int, finalStageType: Int,
        curses: [String], items: [Item], bosses: [String], death: String?,
        outcome: Outcome, finalStats: [Stat]
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.seed = seed
        self.characterID = characterID
        self.characterName = characterName
        self.finalStage = finalStage
        self.finalStageType = finalStageType
        self.curses = curses
        self.items = items
        self.bosses = bosses
        self.death = death
        self.outcome = outcome
        self.finalStats = finalStats
    }

    /// Filename-safe, sortable, and precise enough that two runs cannot collide.
    public static func id(for date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// Bosses whose defeat ends the game rather than a floor.
    ///
    /// Named rather than by id because the ids are a bestiary detail and this has to keep
    /// meaning the same thing after a data rebuild.
    public static let finalBosses: Set<String> = [
        "Isaac", "Satan", "The Lamb", "Mega Satan", "Blue Baby", "???",
    ]

    /// What to call a run that has stopped.
    ///
    /// The log has no "run over" line, so this is inferred, and the order matters: a run
    /// where you beat Isaac and then died on the way out still counts as a win.
    public static func outcome(bosses: [String], died: Bool) -> Outcome {
        if bosses.contains(where: { finalBosses.contains($0) }) { return .won }
        return died ? .died : .abandoned
    }
}
