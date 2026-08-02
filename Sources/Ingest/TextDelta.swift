import Foundation
import IsaacCore

/// Pulls numbers out of EID's English description text.
///
/// Two jobs:
///  1. Fill gaps. `item_data.lua` covers ~376 entries; a few items state a real,
///     permanent stat change in prose only (Cancer's "-2 Tear delay" is the clearest
///     case). Without this they would silently show no stat effect.
///  2. Cross-check. Where both sources have a number, agreement upgrades the item's
///     confidence to `verified`; disagreement is reported rather than papered over.
///
/// Crucially it refuses to extract from *conditional* text. "+2 Damage for the room",
/// "+0.5 Damage for each enemy killed" and "x2 Damage if Isaac has no damaged heart
/// containers" are not permanent deltas, and treating them as such would overstate
/// every stat the app shows.
public enum TextDelta {

    /// Markers that mean "this number does not always apply". Conservative on
    /// purpose: a missed extraction shows as a known gap, whereas a wrong
    /// extraction quietly corrupts the numbers.
    static let conditionalMarkers = [
        // timed / triggered
        "{{timer}}", "for the room", "upon ", "taking damage", "duration of the room",
        "per floor", "every room", "every 3 seconds",
        // scaled by a quantity
        "for each", "for every", "scales with", "up to", "caps at", "depending on",
        // gated on a state
        "while ", "when on", "while at", "if isaac", "holding a", "chance", "at least",
        // applies to only one eye, so it is not a whole-character stat change
        "left eye", "right eye",
        // randomised or rewritten
        "random", "rerolls", "balances", "on pickup",
        // weapon replacement rather than a stat delta
        "chargeable", "charged", "instead of", "replaced by", "counts as", "sets your",
    ]

    public static func isConditional(_ text: String) -> Bool {
        let lower = text.lowercased()
        return conditionalMarkers.contains { lower.contains($0) }
    }

    private struct Rule: @unchecked Sendable {
        // NSRegularExpression is documented as thread-safe for matching, and the
        // closures are pure -- so this table is safe to share.
        let pattern: NSRegularExpression
        let apply: @Sendable (inout ItemDelta, Double) -> Void
        init(_ p: String, _ apply: @escaping @Sendable (inout ItemDelta, Double) -> Void) {
            pattern = try! NSRegularExpression(pattern: p)
            self.apply = apply
        }
    }

    // Order matters: multiplier forms are matched before the plain "+N Stat" forms
    // so "x1.5 Damage multiplier" is never read as a flat damage up.
    private static let rules: [Rule] = [
        Rule(#"x([\d.]+) Damage multiplier"#) { $0.damageMultiplier = $1 },
        Rule(#"x([\d.]+) Tears multiplier"#) { $0.tearsMultiplier = $1 },
        Rule(#"x([\d.]+) Range multiplier"#) { d, v in d.range = nil; d.rangeMultiplier = v },
        Rule(#"x([\d.]+) Shot ?speed multiplier"#) { $0.shotSpeed = $1 - 1 },
        Rule(#"([+-][\d.]+) Tear delay"#) { $0.tearDelay = $1 },
        Rule(#"([+-][\d.]+) Damage\b"#) { $0.damage = $1 },
        Rule(#"([+-][\d.]+) Tears\b"#) { $0.tears = $1 },
        Rule(#"([+-][\d.]+) Range\b"#) { $0.range = $1 },
        Rule(#"([+-][\d.]+) Speed\b"#) { $0.speed = $1 },
        Rule(#"([+-][\d.]+) Shot ?speed"#) { $0.shotSpeed = $1 },
        Rule(#"([+-][\d.]+) Luck\b"#) { $0.luck = $1 },
    ]

    /// Returns nil when the text describes a conditional or temporary effect.
    public static func parse(_ text: String) -> ItemDelta? {
        guard !text.isEmpty, !isConditional(text) else { return nil }
        var delta = ItemDelta()
        let range = NSRange(text.startIndex..., in: text)
        for rule in rules {
            guard let m = rule.pattern.firstMatch(in: text, range: range),
                  let r = Range(m.range(at: 1), in: text),
                  let value = Double(text[r]) else { continue }
            rule.apply(&delta, value)
        }
        delta.shots = EIDIngest.extraShots(fromText: text)
        return delta.isEmpty ? nil : delta
    }

    /// Fields where the two sources disagree by more than rounding.
    public static func disagreements(_ a: ItemDelta, _ b: ItemDelta) -> [String] {
        var out: [String] = []
        func cmp(_ name: String, _ x: Double?, _ y: Double?) {
            guard let x, let y else { return }
            if abs(x - y) > 0.001 { out.append("\(name): \(x) vs \(y)") }
        }
        cmp("damage", a.damage, b.damage)
        cmp("damageMultiplier", a.damageMultiplier, b.damageMultiplier)
        cmp("tears", a.tears, b.tears)
        cmp("tearsMultiplier", a.tearsMultiplier, b.tearsMultiplier)
        cmp("tearDelay", a.tearDelay, b.tearDelay)
        cmp("range", a.range, b.range)
        cmp("speed", a.speed, b.speed)
        cmp("shotSpeed", a.shotSpeed, b.shotSpeed)
        cmp("luck", a.luck, b.luck)
        return out
    }
}
