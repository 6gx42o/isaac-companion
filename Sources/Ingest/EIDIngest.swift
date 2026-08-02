import Foundation
import IsaacCore

/// Reads EID's Afterbirth+ data set.
///
/// EID is the only source that publishes typed numeric deltas for AB+ specifically
/// (`descriptions/ab+/` is a permanent sibling of `descriptions/rep/`, not a stale
/// branch). We read it as data at build time; nothing about the running app depends
/// on the mod being installed or enabled -- which matters, because enabling any mod
/// turns Steam achievements off.
public struct EIDIngest: Sendable {
    public struct Entry: Sendable {
        public var id: Int
        public var name: String
        public var text: String
        public var delta: ItemDelta
    }

    public struct Result: Sendable {
        public var collectibles: [Int: Entry] = [:]
        public var trinkets: [Int: Entry] = [:]
        /// Cards/runes and pills. Same {id, name, text} shape as collectibles.
        public var cards: [Int: Entry] = [:]
        public var pills: [Int: Entry] = [:]
        /// item id -> transformation ids it contributes to
        public var transformations: [Int: [String]] = [:]
        /// Display names, indexed by transformation id (0 = none).
        public var transformationNames: [String] = []
        /// Named interaction key -> description, e.g. "Brimstone Ipecac".
        public var conditionalDescs: [String: String] = [:]
    }

    public static let collectiblePrefix = "5.100."
    public static let trinketPrefix = "5.350."

    public init() {}

    /// EID's field names -> our `ItemDelta`. Anything not listed here is either a
    /// pickup/chance effect or a non-stat effect and is intentionally dropped.
    static func delta(from table: LuaTable) -> ItemDelta {
        func n(_ key: String) -> Double? { table[key]?.numberValue }
        var d = ItemDelta(
            damage: n("Damage"),
            damageMultiplier: n("DamageMultiplier"),
            tears: n("Tears"),
            tearsMultiplier: n("TearsMultiplier"),
            tearDelay: n("TearDelay"),
            range: n("Range"),
            shotSpeed: n("ShotSpeed"),
            speed: n("Speed"),
            luck: n("Luck")
        )
        if table["Flight"]?.boolValue == true { d.flight = true }
        d.tearEffect = table["TearEffect"]?.stringValue
        return d
    }

    /// EID states multishot in prose only ("Isaac shoots 3 tears at once"), so it
    /// gets lifted out here. Stored as EXTRA shots, because these add: Inner Eye's
    /// 3 and Mutant Spider's 4 make 7 tears, not 12.
    private static let shotsRE = try! NSRegularExpression(
        pattern: #"shoots (\d+) (?:more )?tears?"#, options: .caseInsensitive)

    static func extraShots(fromText text: String) -> Int? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = Self.shotsRE.firstMatch(in: text, range: range),
              let r = Range(m.range(at: 1), in: text), let total = Int(text[r]), total > 1
        else { return nil }
        // "shoots N tears at once" is a total; "shoots N more tears" is already extra.
        return text.lowercased().contains("more tear") ? total : total - 1
    }

    private static func id(_ key: String, prefix: String) -> Int? {
        guard key.hasPrefix(prefix) else { return nil }
        return Int(key.dropFirst(prefix.count))
    }

    public func load(descriptionsDirectory dir: URL) throws -> Result {
        let itemData = try String(contentsOf: dir.appending(path: "item_data.lua"), encoding: .utf8)
        let english = try String(contentsOf: dir.appending(path: "en_us.lua"), encoding: .utf8)

        var dataParser = LuaLiteralParser(itemData)
        let data = try dataParser.table(assignedTo: "EID.ItemData")

        var out = Result()
        func absorb(_ target: String, prefix: String, into dict: inout [Int: Entry]) throws {
            var p = LuaLiteralParser(english)
            let rows = try p.table(assignedTo: target)
            for row in rows.array {
                guard let cols = row.tableValue, cols.array.count >= 3,
                      let idText = cols.array[0].stringValue, let id = Int(idText)
                else { continue }
                let name = cols.array[1].stringValue ?? ""
                let text = cols.array[2].stringValue ?? ""
                // Later duplicate ids in the file belong to other entity kinds
                // (cards, pills); the first row for an id is the right one.
                guard dict[id] == nil else { continue }
                var delta = data["\(prefix)\(id)"]?.tableValue.map(Self.delta) ?? ItemDelta()
                // Only permanent, unconditional multishot. Without this gate the regex
                // also caught burst effects from actives and familiars ("shoots 10
                // tears" on use), which inflated the shot count for the whole run.
                delta.shots = TextDelta.isConditional(text)
                    ? nil : Self.extraShots(fromText: text)
                dict[id] = Entry(id: id, name: name, text: text, delta: delta)
            }
        }
        try absorb(
            "EID.descriptions[languageCode].collectibles",
            prefix: Self.collectiblePrefix, into: &out.collectibles)
        try absorb(
            "EID.descriptions[languageCode].trinkets",
            prefix: Self.trinketPrefix, into: &out.trinkets)
        // Cards and pills carry no stat deltas, so the prefixes here match nothing in
        // ItemData -- that is fine, they are wanted for their names and descriptions.
        try? absorb(
            "EID.descriptions[languageCode].cards", prefix: "5.300.", into: &out.cards)
        try? absorb(
            "EID.descriptions[languageCode].pills", prefix: "5.70.", into: &out.pills)

        // Named interaction text ("Brimstone Ipecac" -> the actual description).
        // Some entries are a single string, others a one-element table.
        var descParser = LuaLiteralParser(english)
        if let table = try? descParser.table(
            assignedTo: "EID.descriptions[languageCode].ConditionalDescs") {
            for (key, value) in table.dict {
                if let s = value.stringValue {
                    out.conditionalDescs[key] = s
                } else if let first = value.tableValue?.array.first?.stringValue {
                    out.conditionalDescs[key] = first
                }
            }
        }

        var nameParser = LuaLiteralParser(english)
        if let table = try? nameParser.table(
            assignedTo: "EID.descriptions[languageCode].transformations") {
            out.transformationNames = table.array.map { $0.stringValue ?? "" }
        }

        let transformsURL = dir.appending(path: "transformations.lua")
        if let src = try? String(contentsOf: transformsURL, encoding: .utf8) {
            var p = LuaLiteralParser(src)
            if let table = try? p.table(assignedTo: "EID.EntityTransformations") {
                for (key, value) in table.dict {
                    guard let id = Self.id(key, prefix: Self.collectiblePrefix),
                          let list = value.stringValue else { continue }
                    out.transformations[id] = list.split(separator: ",").map(String.init)
                }
            }
        }
        return out
    }
}
