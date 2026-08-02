import Foundation
import IsaacCore

/// Reads `achievements.xml` — the game's own unlock conditions.
///
/// The condition text is not an attribute. It lives in an XML *comment* immediately
/// above each `<achievement>` tag, written by the developers for themselves:
///
///     <!-- Destroy 100 tinted rocks -->
///     <achievement id="12" text='You unlocked "The Halo"' gfx="..."/>
///
/// So the parse is comment-aware rather than a plain XMLParser walk. The `text`
/// attribute is useless as a condition — it only ever says an item "has appeared in
/// the basement", which is the announcement, not the requirement.
///
/// Roughly 30% of gated items resolve to an achievement with no comment (the
/// Afterbirth-era additions systematically lack them). Those get `condition == nil`
/// and must be shown as "condition unknown" rather than given an invented one.
public struct AchievementsXML: Sendable {
    public init() {}

    private static let entry = try! NSRegularExpression(
        pattern: #"(?:<!--\s*(.*?)\s*-->\s*)?<achievement\b([^>]*)/>"#,
        options: [.dotMatchesLineSeparators])
    /// The closing quote is a backreference to the opening one. achievements.xml mixes
    /// styles -- `text='You unlocked "Magdalene"'` is single-quoted and contains double
    /// quotes -- so a `["']` on both ends silently truncates the value.
    private static let attr = try! NSRegularExpression(
        pattern: #"(\w+)\s*=\s*(["'])(.*?)\2"#)

    public func parse(contentsOf url: URL) throws -> [Achievement] {
        let xml = try String(contentsOf: url, encoding: .utf8)
        let ns = xml as NSString
        var out: [Achievement] = []
        for m in Self.entry.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let body = ns.substring(with: m.range(at: 2))
            let bn = body as NSString
            var attrs: [String: String] = [:]
            for a in Self.attr.matches(in: body, range: NSRange(location: 0, length: bn.length)) {
                attrs[bn.substring(with: a.range(at: 1))] =
                    XML.unescape(bn.substring(with: a.range(at: 3)))
            }
            guard let id = attrs["id"].flatMap(Int.init) else { continue }
            let comment = m.range(at: 1).location == NSNotFound
                ? nil : ns.substring(with: m.range(at: 1))
            out.append(
                Achievement(
                    id: id,
                    condition: comment.map(XML.unescape)?
                        .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                    announcement: attrs["text"],
                    steamName: attrs["steam_name"],
                    gfx: attrs["gfx"]))
        }
        return out.sorted { $0.id < $1.id }
    }
}

/// Consumables are gated separately from collectibles, in their own file, and each
/// kind uses its own element name.
public struct PocketItemsXML: Sendable {
    public init() {}

    private static let entry = try! NSRegularExpression(
        pattern: #"<(card|rune|pilleffect)\b([^>]*)/>"#)
    /// The closing quote is a backreference to the opening one. achievements.xml mixes
    /// styles -- `text='You unlocked "Magdalene"'` is single-quoted and contains double
    /// quotes -- so a `["']` on both ends silently truncates the value.
    private static let attr = try! NSRegularExpression(
        pattern: #"(\w+)\s*=\s*(["'])(.*?)\2"#)

    /// (kind, id) -> achievement id. Kind matters because card and pill ids collide,
    /// exactly as they do everywhere else in this game's data.
    public func parse(contentsOf url: URL) throws -> [(kind: ItemKind, id: Int, achievement: Int)] {
        let xml = try String(contentsOf: url, encoding: .utf8)
        let ns = xml as NSString
        var out: [(ItemKind, Int, Int)] = []
        for m in Self.entry.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2))
            let bn = body as NSString
            var attrs: [String: String] = [:]
            for a in Self.attr.matches(in: body, range: NSRange(location: 0, length: bn.length)) {
                attrs[bn.substring(with: a.range(at: 1))] = bn.substring(with: a.range(at: 3))
            }
            guard let id = attrs["id"].flatMap(Int.init),
                  let ach = attrs["achievement"].flatMap(Int.init) else { continue }
            // Runes share the card pocket slot and the card id space.
            out.append((tag == "pilleffect" ? .pill : .card, id, ach))
        }
        return out
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// XML entity decoding.
///
/// The regexes read raw attribute text, so `Loki&apos;s Horns` reached the UI with
/// the entity intact. Only the five predefined entities plus numeric references can
/// appear in these files; `&amp;` is unescaped last so `&amp;apos;` does not turn
/// into an apostrophe.
enum XML {
    static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        // Numeric references, replaced back-to-front so earlier ranges stay valid.
        if out.contains("&#"), let re = try? NSRegularExpression(
            pattern: #"&#(x?)([0-9A-Fa-f]+);"#) {
            let ns = out as NSString
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                let hex = ns.substring(with: m.range(at: 1)) == "x"
                let digits = ns.substring(with: m.range(at: 2))
                guard let code = UInt32(digits, radix: hex ? 16 : 10),
                      let scalar = Unicode.Scalar(code) else { continue }
                out = (out as NSString).replacingCharacters(
                    in: m.range, with: String(scalar))
            }
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}
