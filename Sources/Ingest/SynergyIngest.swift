import Foundation
import IsaacCore

/// Extracts the Afterbirth+ weapon-override lattice and named interactions from
/// EID's `eid_conditionals.lua`.
///
/// That file is function *calls*, not a table literal, so it gets its own line-based
/// reader rather than the Lua literal parser. Two things matter for correctness:
///
///  1. Blocks guarded by `if EID.isRepentance then` describe a different game and
///     must be skipped. Blocks guarded by `if not EID.isRepentance then` are AB+
///     exclusives and must be kept.
///  2. In `AddSynergyConditional(A, B, textA, textB, opts)`, A is the item being
///     looked at and B is the one you already own -- so when textA is "Overridden",
///     **B wins**. Getting that backwards would invert every override in the app.
public struct SynergyIngest: Sendable {
    public init() {}

    /// Splits a Lua argument list at top level, respecting braces and quotes.
    static func topLevelArgs(_ text: String) -> [String] {
        var args: [String] = []
        var current = ""
        var depth = 0
        // `Swift.Character` qualified: IsaacCore's `Character` (a playable character)
        // shadows it in this module.
        var quote: Swift.Character?
        for c in text {
            if let q = quote {
                current.append(c)
                if c == q { quote = nil }
                continue
            }
            switch c {
            case "\"", "'":
                quote = c
                current.append(c)
            case "{", "(", "[":
                depth += 1
                current.append(c)
            case "}", ")", "]":
                depth -= 1
                current.append(c)
            case "," where depth == 0:
                args.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default:
                current.append(c)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { args.append(last) }
        return args
    }

    /// Numeric collectible ids from `123` or `{1, 2, 3}`. Entries like "5.350.26"
    /// are trinkets and are skipped -- this lattice is about collectibles.
    static func ids(_ arg: String) -> [Int] {
        let inner = arg.hasPrefix("{") ? String(arg.dropFirst().dropLast()) : arg
        return inner.split(separator: ",").compactMap { piece -> Int? in
            let t = piece.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("\""), !t.hasPrefix("'") else { return nil }
            return Int(t)
        }
    }

    static func quoted(_ arg: String) -> String? {
        let t = arg.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") else { return nil }
        return String(t.dropFirst().dropLast())
    }

    static func layer(_ arg: String?) -> Int? {
        guard let arg, let range = arg.range(of: "layer") else { return nil }
        let tail = arg[range.upperBound...].drop { $0 == " " || $0 == "=" }
        return Int(tail.prefix { $0.isNumber })
    }

    /// A call, once the leading `EID:Name(` and trailing `)` have been stripped.
    private struct Call {
        var name: String
        var args: [String]
    }

    private static func call(in line: String) -> Call? {
        guard let colon = line.range(of: "EID:"),
              let open = line[colon.upperBound...].firstIndex(of: "(")
        else { return nil }
        let name = String(line[colon.upperBound..<open])
        // Trim any trailing `-- comment` before finding the closing paren.
        var body = String(line[line.index(after: open)...])
        if let comment = body.range(of: "--") { body = String(body[..<comment.lowerBound]) }
        guard let close = body.lastIndex(of: ")") else { return nil }
        return Call(name: name, args: topLevelArgs(String(body[..<close])))
    }

    public func load(
        conditionals url: URL, descriptions: [String: String],
        transformationAssignments: [Int: [String]], transformationNames: [String]
    ) throws -> SynergyBundle {
        let source = try String(contentsOf: url, encoding: .utf8)

        var overrides: [WeaponOverride] = []
        var layers: [Int: Int] = [:]
        var named: [NamedSynergy] = []

        // Guard tracking. These blocks contain flat statements only, so one flag plus
        // an `end` match is enough -- but the flag is asserted on below.
        enum Guard { case none, repentanceOnly, abPlusOnly }
        var current: Guard = .none
        var sawRepentanceBlock = false

        // `split(whereSeparator: \.isNewline)`, NOT `split(separator: "\n")`: this file
        // is CRLF, and Swift treats "\r\n" as a single Character that does not equal
        // "\n" -- so splitting on "\n" returns the entire file as one line.
        for rawLine in source.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("if not EID.isRepentance then") {
                current = .abPlusOnly
                continue
            }
            if line.hasPrefix("if EID.isRepentance then") {
                sawRepentanceBlock = true
                // A single-line guard closes itself: `if EID.isRepentance then X end`.
                // Treating it as opening a block left the flag stuck on and silently
                // discarded every AB+ rule that followed.
                if !line.hasSuffix(" end") { current = .repentanceOnly }
                continue
            }
            if line.hasPrefix("if not EID.isRepentance then"), line.hasSuffix(" end") {
                continue   // single-line AB+ guard; body handled below is not reached
            }
            if line == "end" || line.hasPrefix("else") {
                // `else` on an isRepentance guard flips to the AB+ branch.
                current = line.hasPrefix("else") && current == .repentanceOnly ? .abPlusOnly : .none
                continue
            }
            guard current != .repentanceOnly, line.hasPrefix("EID:") else { continue }
            guard let parsed = Self.call(in: line) else { continue }

            switch parsed.name {
            case "AddSynergyConditional":
                guard parsed.args.count >= 3 else { continue }
                let lookedAt = Self.ids(parsed.args[0])
                let owned = Self.ids(parsed.args[1])
                let text = Self.quoted(parsed.args[2])
                let layerValue = Self.layer(parsed.args.count > 4 ? parsed.args[4] : nil)

                if text == "Overridden" {
                    // args[1] is the item you already own, and it is the winner.
                    guard let winner = owned.first, let layerValue else { continue }
                    layers[winner] = max(layers[winner] ?? 0, layerValue)
                    for loser in lookedAt where loser != winner {
                        overrides.append(
                            WeaponOverride(winner: winner, loser: loser, layer: layerValue))
                    }
                } else if let key = text, let body = descriptions[key] {
                    for a in lookedAt {
                        for b in owned {
                            named.append(NamedSynergy(a: a, b: b, key: key, text: body))
                        }
                    }
                }

            case "AddOneSidedSynergyConditional":
                guard parsed.args.count >= 3,
                      let a = Self.ids(parsed.args[0]).first,
                      let b = Self.ids(parsed.args[1]).first,
                      let key = Self.quoted(parsed.args[2]) else { continue }
                if let body = descriptions[key] {
                    named.append(NamedSynergy(a: a, b: b, key: key, text: body))
                }
                if let layerValue = Self.layer(parsed.args.count > 3 ? parsed.args[3] : nil) {
                    layers[a] = max(layers[a] ?? 0, layerValue)
                }

            default:
                continue
            }
        }

        // If the guard tracking silently broke we would ingest Repentance rules, which
        // is the one failure this whole file exists to prevent.
        guard sawRepentanceBlock else {
            throw NSError(
                domain: "IsaacCompanion", code: 10,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "eid_conditionals.lua had no `if EID.isRepentance` guard -- the "
                        + "format changed and Repentance rules may have been ingested."
                ])
        }

        // Losers that are themselves replacers get a layer, so precedence comparisons
        // work in both directions.
        for override in overrides where layers[override.loser] == nil {
            if overrides.contains(where: { $0.winner == override.loser }) { continue }
        }

        var transformations: [TransformationDef] = []
        var members: [String: [Int]] = [:]
        for (itemID, list) in transformationAssignments {
            for transformID in list { members[transformID, default: []].append(itemID) }
        }
        for (transformID, itemIDs) in members {
            guard let index = Int(transformID), index > 0, index < transformationNames.count
            else { continue }
            transformations.append(
                TransformationDef(
                    id: transformID, name: transformationNames[index],
                    itemIDs: itemIDs.sorted()))
        }
        transformations.sort { $0.name < $1.name }

        return SynergyBundle(
            layers: layers,
            overrides: Array(Set(overrides.map { [$0.winner, $0.loser, $0.layer] }))
                .map { WeaponOverride(winner: $0[0], loser: $0[1], layer: $0[2]) }
                .sorted { ($0.layer, $0.winner, $0.loser) > ($1.layer, $1.winner, $1.loser) },
            named: {
                var seen = Set<String>()
                return named.filter { n in
                    let a = min(n.a, n.b), b = max(n.a, n.b)
                    return seen.insert("\(a)-\(b)-\(n.key)").inserted
                }
            }(),
            transformations: transformations)
    }
}
