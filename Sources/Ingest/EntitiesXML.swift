import Foundation
import IsaacCore

/// Reads `entities2.xml` — every enemy, boss and prop in the game.
///
/// This is the only table that can decode two log lines the app otherwise sees as
/// bare numbers:
///
///     Game Over. Killed by (9.0) spawned by (20.0)   -> a Projectile, from Monstro
///     Boss 17 added to SaveState                     -> Gemini
///
/// Elements are NOT self-closing — each `<entity>` wraps a `<gibs/>` child — and the
/// attributes are in alphabetical order, so both the element match and the attribute
/// read have to be order-independent.
public struct EntitiesXML: Sendable {
    public init() {}

    private static let element = try! NSRegularExpression(pattern: #"<entity\b([^>]*)>"#)
    private static let attr = try! NSRegularExpression(pattern: #"(\w+)\s*=\s*(["'])(.*?)\2"#)

    public func parse(contentsOf url: URL) throws -> [EntityInfo] {
        let xml = try String(contentsOf: url, encoding: .utf8)
        let ns = xml as NSString
        var out: [EntityInfo] = []
        for m in Self.element.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let body = ns.substring(with: m.range(at: 1))
            let bn = body as NSString
            var a: [String: String] = [:]
            for x in Self.attr.matches(in: body, range: NSRange(location: 0, length: bn.length)) {
                a[bn.substring(with: x.range(at: 1))] = bn.substring(with: x.range(at: 3))
            }
            guard let type = a["id"].flatMap(Int.init),
                  let variant = a["variant"].flatMap(Int.init),
                  let name = a["name"], !name.isEmpty else { continue }
            out.append(
                EntityInfo(
                    type: type, variant: variant, name: name,
                    baseHP: a["baseHP"].flatMap(Double.init) ?? 0,
                    stageHP: a["stageHP"].flatMap(Double.init) ?? 0,
                    isBoss: a["boss"] == "1",
                    bossID: a["bossID"].flatMap(Int.init),
                    // The DEFAULT is to lock the doors. `shutdoors="false"` marks props
                    // that do NOT block a room clear -- fireplaces, shopkeepers, grimaces.
                    // Fire Place alone is the most-spawned entity in a real log, so
                    // treating absent-as-false would break any "enemies remaining" count.
                    blocksClear: a["shutdoors"] != "false"))
        }
        return out
    }
}
