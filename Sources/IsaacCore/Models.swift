import Foundation

/// Everything here is Afterbirth+ (v1.06.T1). Repentance changes several of these
/// semantics; see StatEngine for the specific spots marked `REP:`.
/// Which release of Isaac we are reading.
///
/// These are not cosmetic labels — each one changes the item set, the item pools, the
/// stat formulas and where the log lives. Getting it wrong produces numbers that look
/// plausible and are quietly wrong, which is the failure this whole project is built
/// to avoid.
public enum GameVersion: String, Codable, Sendable, CaseIterable {
    case rebirth, afterbirth, abplus, repentance, repentancePlus

    public var dataDirectory: String { rawValue }

    public var displayName: String {
        switch self {
        case .rebirth: "Rebirth"
        case .afterbirth: "Afterbirth"
        case .abplus: "Afterbirth+"
        case .repentance: "Repentance"
        case .repentancePlus: "Repentance+"
        }
    }

    /// The Steam DLC app id that proves this release is owned. Rebirth is the base
    /// game and so has none.
    public var dlcAppID: String? {
        switch self {
        case .rebirth: nil
        case .afterbirth: "401920"
        case .abplus: "570660"
        case .repentance: "1426300"
        case .repentancePlus: "2721360"
        }
    }

    /// Each release keeps its own Application Support folder, and the log lives there.
    public var supportFolder: String {
        switch self {
        case .rebirth: "Binding of Isaac Rebirth"
        case .afterbirth: "Binding of Isaac Afterbirth"
        case .abplus: "Binding of Isaac Afterbirth+"
        case .repentance, .repentancePlus: "Binding of Isaac Repentance"
        }
    }

    /// EID ships a separate description set per era; picking the wrong one is exactly
    /// how Repentance numbers leak into an Afterbirth+ readout.
    public var eidFolder: String {
        switch self {
        case .rebirth, .afterbirth, .abplus: "ab+"
        case .repentance: "rep"
        case .repentancePlus: "rep+"
        }
    }

    /// Highest collectible id. The build asserts against this.
    public var maxCollectibleID: Int {
        switch self {
        case .rebirth: 340
        case .afterbirth: 510
        case .abplus: 552
        case .repentance: 732
        case .repentancePlus: 732
        }
    }

    public var expectedPoolCount: Int {
        switch self {
        case .rebirth, .afterbirth: 25
        case .abplus: 26
        case .repentance, .repentancePlus: 31
        }
    }

    /// Afterbirth+ and earlier floor tear delay; Repentance removed that.
    public var floorsTearDelay: Bool {
        switch self {
        case .rebirth, .afterbirth, .abplus: true
        case .repentance, .repentancePlus: false
        }
    }

    /// Only Repentance has item quality. Showing one for AB+ would be importing a
    /// concept the game does not have.
    public var hasItemQuality: Bool {
        switch self {
        case .repentance, .repentancePlus: true
        default: false
        }
    }
}

/// Numeric stat deltas for one item.
///
/// Field meanings follow EID's `ab+/item_data.lua`, which is the only consistent
/// typed source for AB+. Two of them are easy to misread:
///  - `damage` is a damage-*up*, not a flat add. It feeds the sqrt curve.
///    (Ipecac's `damage: 40` -> 3.5*sqrt(40*1.2+1) = exactly 24.5, a 7x multiple.
///     That clean number is the evidence the curve is right.)
///  - `tearsMultiplier` multiplies the tears *rate*, so it DIVIDES tear delay.
///    (Inner Eye 0.48 == the wiki's "tear delay x2.1"; 1/0.48 = 2.083.)
public struct ItemDelta: Codable, Sendable, Equatable {
    public var damage: Double?
    public var damageMultiplier: Double?
    public var tears: Double?
    public var tearsMultiplier: Double?
    public var tearDelay: Double?
    public var range: Double?
    /// Tape Worm is the only AB+ item that multiplies range rather than adding to it.
    public var rangeMultiplier: Double?
    public var shotSpeed: Double?
    public var speed: Double?
    public var luck: Double?
    /// Additive extra tears per shot (Inner Eye +3, Mutant Spider +4, 20/20 +2).
    /// Additive, never multiplied -- 3 and 4 together is 7 shots, not 12.
    public var shots: Int?
    public var flight: Bool?
    /// "Homing", "Piercing", "Spectral", "Poison". Two sources of the same effect do
    /// not stack, so the second one only contributes its stats.
    public var tearEffect: String?

    public init(
        damage: Double? = nil, damageMultiplier: Double? = nil,
        tears: Double? = nil, tearsMultiplier: Double? = nil, tearDelay: Double? = nil,
        range: Double? = nil, rangeMultiplier: Double? = nil, shotSpeed: Double? = nil,
        speed: Double? = nil, luck: Double? = nil, shots: Int? = nil, flight: Bool? = nil,
        tearEffect: String? = nil
    ) {
        self.tearEffect = tearEffect
        self.damage = damage; self.damageMultiplier = damageMultiplier
        self.tears = tears; self.tearsMultiplier = tearsMultiplier; self.tearDelay = tearDelay
        self.range = range; self.rangeMultiplier = rangeMultiplier
        self.shotSpeed = shotSpeed; self.speed = speed
        self.luck = luck; self.shots = shots; self.flight = flight
    }

    public var isEmpty: Bool { self == ItemDelta() }
}

/// How well-sourced an item's numbers are. Surfaced in the UI so a single-source
/// number never masquerades as a verified one.
public enum Confidence: String, Codable, Sendable {
    case verified        // EID's typed data and its description text agree
    case crossChecked    // present in both sources, only one carries numbers
    case singleSource
    /// Has a real effect on a stat, but only sometimes -- timed, on-trigger,
    /// conditional, random, or a weapon replacement. Explains why the game's own
    /// `cache` flag fires while there is no permanent number to add. Not a gap.
    case conditional
    case nonNumeric      // item genuinely changes no stat; not a gap either

    public var isTrustworthy: Bool { self == .verified || self == .crossChecked }
}

public enum ItemKind: String, Codable, Sendable {
    case passive, active, familiar, trinket, card, pill

    /// Collectibles are the only things the log reports. Trinkets, cards and pills
    /// are never announced on pickup, so they can only ever be entered by hand.
    public var isAutoTracked: Bool {
        switch self {
        case .passive, .active, .familiar: true
        case .trinket, .card, .pill: false
        }
    }

    /// How the run view groups things.
    public var section: ItemSection {
        switch self {
        case .passive: .passives
        case .active: .actives
        case .familiar: .familiars
        case .trinket: .trinkets
        case .card, .pill: .consumables
        }
    }
}

public enum ItemSection: String, Codable, Sendable, CaseIterable {
    case passives, actives, familiars, trinkets, consumables

    public var title: String {
        switch self {
        case .passives: "Passive items"
        case .actives: "Active item"
        case .familiars: "Familiars"
        case .trinkets: "Trinket"
        case .consumables: "Cards & pills"
        }
    }

    /// Shown once under the heading, so the manual-only sections explain themselves
    /// rather than just looking broken.
    public var note: String? {
        switch self {
        case .passives, .actives, .familiars: nil
        case .trinkets: "The log never reports trinkets — add yours by hand."
        case .consumables: "The log never reports cards or pills — add them by hand."
        }
    }
}

/// An item that widens a slot, e.g. Mom's Purse taking trinkets from 1 to 2.
public struct SlotGrant: Codable, Sendable, Equatable {
    public var section: ItemSection
    public var capacity: Int
    public init(section: ItemSection, capacity: Int) {
        self.section = section; self.capacity = capacity
    }
}

/// One row of `entities2.xml`. Keyed by (type, variant), which is exactly how the log
/// refers to entities.
public struct EntityInfo: Codable, Sendable, Equatable {
    public var type: Int
    public var variant: Int
    public var name: String
    public var baseHP: Double
    /// Added per floor for scaling enemies, so `baseHP` alone is not effective HP.
    public var stageHP: Double
    public var isBoss: Bool
    /// The id used by the log's "Boss N added to SaveState" line.
    public var bossID: Int?
    /// False for props that do not hold the doors shut (fireplaces, shopkeepers).
    public var blocksClear: Bool
    /// Dominant colours measured from the sprite, so an enemy can be searched for by
    /// description rather than by name.
    public var colors: [String] = []
    /// Sheet file name, the key into the monster atlas. Every sheet holds the same
    /// number of idle frames (Extractor.monsterFrames), so the count is not per-entity.
    public var art: String?

    public init(
        type: Int, variant: Int, name: String, baseHP: Double = 0, stageHP: Double = 0,
        isBoss: Bool = false, bossID: Int? = nil, blocksClear: Bool = true,
        colors: [String] = [], art: String? = nil
    ) {
        self.colors = colors; self.art = art
        self.type = type; self.variant = variant; self.name = name
        self.baseHP = baseHP; self.stageHP = stageHP
        self.isBoss = isBoss; self.bossID = bossID; self.blocksClear = blocksClear
    }
}

/// An unlock gate, in the game's own words.
public struct Achievement: Codable, Sendable, Identifiable, Equatable {
    public var id: Int
    /// The developer comment above the tag — the real requirement. nil for roughly a
    /// third of them, mostly Afterbirth-era additions, and that must stay visible as
    /// "unknown" rather than being papered over.
    public var condition: String?
    /// The in-game announcement ("... has appeared in the basement"). Never a
    /// requirement, so it is kept separate from `condition` on purpose.
    public var announcement: String?
    public var steamName: String?
    public var gfx: String?

    public init(
        id: Int, condition: String? = nil, announcement: String? = nil,
        steamName: String? = nil, gfx: String? = nil
    ) {
        self.id = id; self.condition = condition; self.announcement = announcement
        self.steamName = steamName; self.gfx = gfx
    }

    /// What to show a player. Falls back to the Steam name only as a hint, and
    /// otherwise admits it does not know.
    public var displayCondition: String {
        condition ?? steamName.map { "Unlocked by the \"\($0)\" achievement" }
            ?? "Unlock condition not recorded in the game files"
    }
    public var isKnown: Bool { condition != nil }
}

public struct Item: Codable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var kind: ItemKind
    public var gfx: String
    /// Raw `cache` attribute from items.xml -- the game's own statement of which
    /// stats this item touches. Used to detect gaps in the numeric data.
    public var cache: [String]
    public var special: Bool
    public var maxCharges: Int?
    public var devilPrice: Int?
    public var pools: [String]
    public var delta: ItemDelta
    public var text: String
    public var confidence: Confidence
    /// Set when the item widens the trinket or pocket slot.
    public var slots: SlotGrant?
    /// Achievement id gating this item, if it is locked behind one. 230 collectibles
    /// and 32 consumables are; the other 414 are available from the start.
    public var achievement: Int?
    /// Dominant colours measured from the item's sprite. Nothing in the game files
    /// says what an item looks like, so this is what lets the UI tint an item's own
    /// effect background and lets people search by description.
    public var colors: [String] = []

    public init(
        id: Int, name: String, kind: ItemKind, gfx: String, cache: [String] = [],
        special: Bool = false, maxCharges: Int? = nil, devilPrice: Int? = nil,
        pools: [String] = [], delta: ItemDelta = ItemDelta(), text: String = "",
        confidence: Confidence = .singleSource, slots: SlotGrant? = nil,
        achievement: Int? = nil
    ) {
        self.slots = slots
        self.achievement = achievement
        self.id = id; self.name = name; self.kind = kind; self.gfx = gfx
        self.cache = cache; self.special = special; self.maxCharges = maxCharges
        self.devilPrice = devilPrice; self.pools = pools; self.delta = delta
        self.text = text; self.confidence = confidence
    }

    /// Stat cache flags that imply this item must carry numbers.
    public static let statCacheFlags: Set<String> =
        ["damage", "firedelay", "range", "speed", "shotspeed", "luck"]

    public var claimsStatChange: Bool {
        !cache.filter(Item.statCacheFlags.contains).isEmpty
    }
}

/// Base stats for a playable character.
///
/// AB+ hardcodes these in the binary -- `players.xml` carries only hp/pickups/items,
/// so there is no machine-readable source. Anything not confirmed against the
/// in-game FoundHUD is listed in `unverified` and flagged in the UI.
public struct Character: Codable, Sendable, Identifiable {
    public var id: Int              // PlayerType / log "Subtype"
    public var name: String
    public var damage: Double
    public var tears: Double        // tear-up stat, feeds the delay curve
    public var speed: Double
    public var range: Double
    public var shotSpeed: Double
    public var luck: Double
    public var damageMultiplier: Double
    public var fireDelayMultiplier: Double
    public var flight: Bool
    public var unverified: [String]
    public var notes: String

    public init(
        id: Int, name: String, damage: Double = 3.5, tears: Double = 0,
        speed: Double = 1.0, range: Double = 23.75, shotSpeed: Double = 1.0,
        luck: Double = 0, damageMultiplier: Double = 1.0,
        fireDelayMultiplier: Double = 1.0, flight: Bool = false,
        unverified: [String] = [], notes: String = ""
    ) {
        self.id = id; self.name = name; self.damage = damage; self.tears = tears
        self.speed = speed; self.range = range; self.shotSpeed = shotSpeed
        self.luck = luck; self.damageMultiplier = damageMultiplier
        self.fireDelayMultiplier = fireDelayMultiplier; self.flight = flight
        self.unverified = unverified; self.notes = notes
    }
}

public struct ItemBundle: Codable, Sendable {
    /// Unlock conditions, keyed by achievement id.
    public var achievements: [Achievement] = []
    /// Enemies and bosses, for decoding the log's entity references.
    public var entities: [EntityInfo] = []
    public var schema: Int
    public var gameVersion: GameVersion
    public var binaryVersion: String
    public var sources: [String: String]
    public var items: [Item]
    public var characters: [Character]

    public init(
        achievements: [Achievement] = [], entities: [EntityInfo] = [],
        schema: Int = 1, gameVersion: GameVersion = .abplus,
        binaryVersion: String = "v1.06.T1", sources: [String: String] = [:],
        items: [Item] = [], characters: [Character] = []
    ) {
        self.achievements = achievements; self.entities = entities
        self.schema = schema; self.gameVersion = gameVersion
        self.binaryVersion = binaryVersion; self.sources = sources
        self.items = items; self.characters = characters
    }
}

public struct Pool: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var id: Int
        public var weight: Double
        public var decreaseBy: Double
        public var removeOn: Double
        public init(id: Int, weight: Double, decreaseBy: Double, removeOn: Double) {
            self.id = id; self.weight = weight
            self.decreaseBy = decreaseBy; self.removeOn = removeOn
        }
    }
    public var name: String
    public var entries: [Entry]
    public init(name: String, entries: [Entry]) { self.name = name; self.entries = entries }
}

public struct PoolBundle: Codable, Sendable {
    public var schema: Int
    public var gameVersion: GameVersion
    public var pools: [Pool]
    public init(schema: Int = 1, gameVersion: GameVersion = .abplus, pools: [Pool] = []) {
        self.schema = schema; self.gameVersion = gameVersion; self.pools = pools
    }
}

/// Resolves the log's bare entity numbers to names.
public struct Bestiary: Sendable {
    private let byRef: [String: EntityInfo]
    private let byBossID: [Int: EntityInfo]

    public init(_ entities: [EntityInfo]) {
        // 1000.107 appears twice (BlackHole, then BlackHoleRay); prefer the row the
        // XML marks as the boss so the shadowed copy never wins the name lookup.
        byRef = Dictionary(
            entities.map { ("\($0.type).\($0.variant)", $0) },
            uniquingKeysWith: { a, b in b.isBoss && !a.isBoss ? b : a })
        // 16 bossIDs map to several rows (bossID 18 is Fistula / Fistula Medium /
        // Fistula Small). The `boss="1"` parent is the one with the name a player uses.
        var bosses: [Int: EntityInfo] = [:]
        for e in entities {
            guard let id = e.bossID else { continue }
            if bosses[id] == nil || (e.isBoss && !(bosses[id]?.isBoss ?? false)) {
                bosses[id] = e
            }
        }
        byBossID = bosses
    }

    public func name(_ ref: EntityRef) -> String? {
        // Variants fall back to the base entity: the log records a specific variant,
        // but "Wall Creep" is more useful than nothing when only variant 0 is named.
        byRef["\(ref.type).\(ref.variant)"]?.name ?? byRef["\(ref.type).0"]?.name
    }
    public func boss(_ id: Int) -> EntityInfo? { byBossID[id] }

    /// A plain-English cause of death, e.g. "a Projectile, from Monstro".
    public func describeDeath(_ death: DeathRecord) -> String {
        // A null killer is not missing data — it is the game recording that nothing
        // attributable killed you: spikes, a sacrifice room, self-damage, a curse.
        if death.killedBy.isNull { return "no attributable source (spikes, self-damage or a curse)" }
        let killer = name(death.killedBy) ?? "an unrecognised entity (\(death.killedBy.type).\(death.killedBy.variant))"
        guard let source = death.spawnedBy, let from = name(source), from != killer else {
            return killer
        }
        return "\(killer), from \(from)"
    }
}
