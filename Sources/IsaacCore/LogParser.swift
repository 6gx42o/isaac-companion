import Foundation

/// RoomType values from the game's own `resources/scripts/enums.lua`.
public enum RoomType: Int, Codable, Sendable {
    case null = 0, normal = 1, shop = 2, error = 3, treasure = 4, boss = 5
    case miniboss = 6, secret = 7, superSecret = 8, arcade = 9, curse = 10
    case challenge = 11, library = 12, sacrifice = 13, devil = 14, angel = 15
    case dungeon = 16, bossRush = 17, isaacs = 18, barren = 19, chest = 20
    case dice = 21, blackMarket = 22, greedExit = 23

    /// Rooms where the advisor has something useful to say about a pedestal.
    public var offersChoice: Bool {
        switch self {
        case .treasure, .devil, .angel, .shop, .secret, .library, .bossRush, .chest: true
        default: false
        }
    }

    /// Which item pool this room draws from, matching itempools.xml names.
    /// nil where a re-roll is not a meaningful choice.
    public var poolName: String? {
        switch self {
        case .treasure: "treasure"
        case .devil: "devil"
        case .angel: "angel"
        case .shop: "shop"
        case .secret: "secret"
        case .library: "library"
        case .bossRush: "bossrush"
        case .curse: "curse"
        default: nil
        }
    }

    /// Where pedestals usually sit, in room coordinates.
    ///
    /// Needed because the game only logs entity spawns the FIRST time a room is
    /// generated — walk out and back in and nothing is re-emitted, so a scan that
    /// depended on logged positions would work exactly once per room.
    /// (320, 280) is the centre of a 1x1 room, confirmed by the real log.
    /// Measured from 77 collectible and 56 shop-item spawns in a real log, not guessed.
    /// Collectible pedestals sit at y=280; SHOP ITEMS SIT AT y=320. The earlier y=280
    /// guess for shops and devil rooms was a full tile out, and RoomScanner only crops
    /// about +/-30 units, so it was matching against empty floor.
    public var likelyPedestals: [(x: Double, y: Double)] {
        switch self {
        case .treasure, .secret, .library, .bossRush, .isaacs, .barren:
            [(320, 280)]                                  // 67/77 land exactly here
        case .devil, .angel:
            [(240, 320), (320, 320), (400, 320)]          // 1-, 2- and 3-slot layouts
        case .shop:
            // Slot count changes the x positions: 2-slot uses 280/360, 3-slot 240/320/400.
            [(240, 320), (280, 320), (320, 320), (360, 320), (400, 320)]
        default:
            []
        }
    }
}

/// A (type, variant) pair as the log writes it, e.g. `(20.0)` is Monstro.
public struct EntityRef: Equatable, Sendable, Codable {
    public var type: Int
    public var variant: Int
    public init(type: Int, variant: Int) { self.type = type; self.variant = variant }
    /// Type 0 variant 0 is the game's null entity — it means "no attributable source",
    /// which is what a self-inflicted or environmental death records.
    public var isNull: Bool { type == 0 && variant == 0 }
}

public enum RunEvent: Equatable, Sendable {
    case gameVersion(String)
    case runStarted(seed: String)
    case playerInit(playerType: Int)
    case levelInit(stage: Int, stageType: Int)
    case roomEntered(type: RoomType, variant: Int)
    case pedestalSpawned(x: Double, y: Double)
    /// A pill dropped on the floor. The line carries no subtype, so this says a pill is
    /// there and where it is -- never which colour, and never which effect.
    case pillSpawned(x: Double, y: Double)
    /// A tarot card or rune dropped. Same caveat: position, never which card.
    case cardSpawned(x: Double, y: Double)
    /// `Action PillCard Triggered` -- the pocket slot was used. The game does not say
    /// whether it was a pill or a card, nor which one; it is the only moment the log
    /// admits a consumable was swallowed at all.
    case pocketItemUsed
    case itemAdded(id: Int, name: String)
    case itemRemoved(id: Int)
    case curse(String)
    /// `Game Over. Killed by (T.V) spawned by (T.V)`. Both are (type, variant) pairs
    /// that `entities2.xml` resolves to names.
    case died(killedBy: EntityRef, spawnedBy: EntityRef?)
    /// `Boss N added to SaveState`. N is a bossID, not an entity type. This fires for
    /// 100% of bosses beaten, where the spawn lines only cover about 60%.
    case bossDefeated(bossID: Int)
    case shutdown
}

/// Pure line -> event. No I/O, so the whole thing is testable from fixtures.
public struct LogParser: Sendable {
    public init() {}

    private static func re(_ p: String) -> NSRegularExpression {
        // Patterns are literals owned by this file; a failure here is a build bug.
        try! NSRegularExpression(pattern: p)
    }

    // `Adding collectible 46 (Lucky Foot)` on AB+.
    // Repentance appends ` to Player 0 (Isaac)` -- tolerated so a future Repentance
    // swap does not silently mangle every item name.
    private static let itemAdded = re(#"^Adding collectible (\d+) \((.+?)\)(?: to Player \d+.*)?$"#)
    private static let itemRemoved = re(#"^Removing collectible (\d+)"#)
    private static let seed = re(#"^RNG Start Seed: ([A-Z0-9 ]+) \(\d+\)"#)
    private static let playerInit = re(#"^Initialized player with Variant \d+ and Subtype (\d+)"#)
    private static let levelInit = re(#"^Level::Init m_Stage (\d+), m_StageType (\d+)"#)
    private static let room = re(#"^Room (\d+)\.(\d+)\("#)
    private static let version = re(#"^Binding of Isaac: (.+)$"#)
    // The "!" is optional: the real AB+ log writes "Curse of Blind" with no
    // punctuation for most curses, and only some carry the exclamation mark.
    private static let curse = re(#"^(Curse of [A-Za-z' ]+)!?$"#)
    // Type 5 / Variant 100 is a collectible pedestal. The id is NOT logged --
    // only the position -- which is why identifying it needs the screen.
    // Variant 100 is a collectible pedestal; Variant 150 is a SHOP ITEM slot, which is
    // also something you stand in front of and decide about. The slot may resolve to a
    // consumable rather than a collectible, so this is "purchasable slot", not
    // "collectible for sale" -- the scanner has to tolerate a no-match.
    // `Game Over. Killed by (284.0) spawned by (0.0) damage flags (0)`
    private static let died = re(
        #"^Game Over\. Killed by \((\d+)\.(\d+)\) spawned by \((\d+)\.(\d+)\)"#)
    private static let bossKill = re(#"^Boss (\d+) added to SaveState"#)
    private static let pedestal =
        re(#"^Spawn Entity with Type\(5\), Variant\((?:100|150)\), Pos\(([-\d.]+),([-\d.]+)\)"#)
    /// PickupVariant 70 is PICKUP_PILL. Same shape as the pedestal line and, like it,
    /// carries no subtype -- so the colour has to come off the screen.
    private static let pill =
        re(#"^Spawn Entity with Type\(5\), Variant\(70\), Pos\(([-\d.]+),([-\d.]+)\)"#)
    /// PickupVariant 300 is PICKUP_TAROTCARD -- cards and runes both.
    private static let card =
        re(#"^Spawn Entity with Type\(5\), Variant\(300\), Pos\(([-\d.]+),([-\d.]+)\)"#)

    public func parse(line rawLine: String) -> RunEvent? {
        // `.whitespacesAndNewlines` also strips a stray trailing "\r", so a CRLF log
        // does not leave carriage returns glued to item names.
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["[INFO] - ", "[ASSERT] - ", "[WARN] - "] where line.hasPrefix(prefix) {
            line = String(line.dropFirst(prefix.count))
        }
        guard !line.isEmpty else { return nil }

        let range = NSRange(line.startIndex..., in: line)
        func group(_ re: NSRegularExpression, _ n: Int) -> String? {
            guard let m = re.firstMatch(in: line, range: range),
                  let r = Range(m.range(at: n), in: line) else { return nil }
            return String(line[r])
        }

        if let idText = group(Self.itemAdded, 1), let id = Int(idText),
           let name = group(Self.itemAdded, 2) {
            return .itemAdded(id: id, name: name)
        }
        if let idText = group(Self.itemRemoved, 1), let id = Int(idText) {
            return .itemRemoved(id: id)
        }
        if let s = group(Self.seed, 1) { return .runStarted(seed: s) }
        if let t = group(Self.playerInit, 1), let v = Int(t) { return .playerInit(playerType: v) }
        if let a = group(Self.levelInit, 1), let b = group(Self.levelInit, 2),
           let stage = Int(a), let type = Int(b) {
            return .levelInit(stage: stage, stageType: type)
        }
        if let a = group(Self.room, 1), let b = group(Self.room, 2),
           let raw = Int(a), let variant = Int(b) {
            return .roomEntered(type: RoomType(rawValue: raw) ?? .null, variant: variant)
        }
        if let x = group(Self.pedestal, 1), let y = group(Self.pedestal, 2),
           let dx = Double(x), let dy = Double(y) {
            return .pedestalSpawned(x: dx, y: dy)
        }
        if let x = group(Self.pill, 1), let y = group(Self.pill, 2),
           let dx = Double(x), let dy = Double(y) {
            return .pillSpawned(x: dx, y: dy)
        }
        if let x = group(Self.card, 1), let y = group(Self.card, 2),
           let dx = Double(x), let dy = Double(y) {
            return .cardSpawned(x: dx, y: dy)
        }
        if line == "Action PillCard Triggered" { return .pocketItemUsed }
        if let a = group(Self.died, 1), let b = group(Self.died, 2),
           let c = group(Self.died, 3), let d = group(Self.died, 4),
           let t = Int(a), let v = Int(b), let st = Int(c), let sv = Int(d) {
            let source = EntityRef(type: st, variant: sv)
            return .died(killedBy: EntityRef(type: t, variant: v),
                         spawnedBy: source.isNull ? nil : source)
        }
        if let b = group(Self.bossKill, 1), let id = Int(b) { return .bossDefeated(bossID: id) }
        if let v = group(Self.version, 1) { return .gameVersion(v) }
        if let c = group(Self.curse, 1) { return .curse(c) }
        if line == "Isaac has shut down" { return .shutdown }
        return nil
    }

    public func parse(lines: String) -> [RunEvent] {
        // Split on any newline rather than the literal "\n": Swift reads "\r\n" as one
        // Character that does not equal "\n", so a CRLF source would come back as a
        // single line.
        lines.split(whereSeparator: \.isNewline)
            .compactMap { parse(line: String($0)) }
    }
}
