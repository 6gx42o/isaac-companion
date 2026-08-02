import Foundation
import IsaacCore

/// Reads the game's own `items.xml`.
///
/// We read the *Japanese* resource folder because it is the only one shipped
/// unpacked, and every attribute we need from it -- id, gfx, cache, maxcharges,
/// devilprice, special -- is language-independent. Names and descriptions come
/// from EID instead, so nothing here depends on running the 600 MB extractor.
public struct ItemsXML {
    public struct Row: Sendable {
        public var id: Int
        public var kind: ItemKind
        public var gfx: String
        public var cache: [String]
        public var special: Bool
        public var maxCharges: Int?
        public var devilPrice: Int?
        /// Achievement id this item is locked behind, if any.
        public var achievement: Int?
    }

    /// `cache="all"` means every stat, and the game uses it 16 times.
    public static let allStatFlags = ["damage", "firedelay", "range", "speed", "shotspeed", "luck"]

    public init() {}

    public func parse(contentsOf url: URL) throws -> [Row] {
        let data = try Data(contentsOf: url)
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }
        return delegate.rows
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var rows: [Row] = []

        func parser(
            _ parser: XMLParser, didStartElement element: String,
            namespaceURI: String?, qualifiedName: String?,
            attributes attrs: [String: String]
        ) {
            let kind: ItemKind
            switch element {
            case "passive": kind = .passive
            case "active": kind = .active
            case "familiar": kind = .familiar
            case "trinket": kind = .trinket
            default: return
            }
            guard let idText = attrs["id"], let id = Int(idText) else { return }

            var cache = (attrs["cache"] ?? "")
                .split(separator: " ").map(String.init)
            if cache.contains("all") {
                cache.removeAll { $0 == "all" }
                cache.append(contentsOf: ItemsXML.allStatFlags)
            }

            rows.append(
                Row(
                    id: id, kind: kind, gfx: attrs["gfx"] ?? "",
                    cache: Array(Set(cache)).sorted(),
                    special: attrs["special"] == "true",
                    maxCharges: attrs["maxcharges"].flatMap(Int.init),
                    devilPrice: attrs["devilprice"].flatMap(Int.init),
                    achievement: attrs["achievement"].flatMap(Int.init)))
        }
    }
}

/// Reads `itempools.xml`. Only available after running ResourceExtractor -- it is
/// not in any unpacked folder, and no correct AB+ pool data is published anywhere
/// online, so this file is the single source of truth for pools.
public struct ItemPoolsXML {
    public init() {}

    public func parse(contentsOf url: URL) throws -> [Pool] {
        let data = try Data(contentsOf: url)
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }
        delegate.flush()
        return delegate.pools
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var pools: [Pool] = []
        private var name: String?
        private var entries: [Pool.Entry] = []

        func flush() {
            if let name { pools.append(Pool(name: name, entries: entries)) }
            name = nil
            entries = []
        }

        func parser(
            _ parser: XMLParser, didStartElement element: String,
            namespaceURI: String?, qualifiedName: String?,
            attributes attrs: [String: String]
        ) {
            switch element {
            case "Pool":
                flush()
                name = attrs["Name"]
            case "Item":
                guard let idText = attrs["Id"], let id = Int(idText) else { return }
                entries.append(
                    Pool.Entry(
                        id: id,
                        weight: Double(attrs["Weight"] ?? "1") ?? 1,
                        decreaseBy: Double(attrs["DecreaseBy"] ?? "1") ?? 1,
                        removeOn: Double(attrs["RemoveOn"] ?? "0.1") ?? 0.1))
            default: break
            }
        }
    }
}
