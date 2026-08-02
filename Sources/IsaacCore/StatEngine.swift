import Foundation

public struct Stat: Sendable, Equatable {
    public var value: Double
    /// The character's value for this stat with no items at all.
    public var base: Double
    /// True when the result depends on an ordering or interaction the game does not
    /// document. UI shows "~" and explains why rather than pretending to precision.
    public var approx: Bool
    public var reason: String?

    /// What the items actually did to this stat.
    ///
    /// Deliberately `value - base` rather than the sum of the item deltas: damage runs
    /// through a square-root curve and multipliers, so the raw inputs do not add up to
    /// the result. This way `base + fromItems == value` always holds.
    public var fromItems: Double { value - base }

    public init(
        _ value: Double, base: Double? = nil, approx: Bool = false, reason: String? = nil
    ) {
        // A non-finite stat is always a bug, but it must never reach the UI: JSONEncoder
        // rejects non-finite Doubles, which would drop the entire state payload.
        self.value = value.isFinite ? value : 0
        let resolvedBase = base ?? value
        self.base = resolvedBase.isFinite ? resolvedBase : 0
        self.approx = approx || !value.isFinite
        self.reason = value.isFinite ? reason : "value was not finite; clamped to 0"
    }
}

public struct ComputedStats: Sendable, Equatable {
    public var damage: Stat
    public var tears: Stat          // tears per second, as the HUD shows it
    public var tearDelay: Stat      // underlying MaxFireDelay, in frames
    public var range: Stat
    public var shotSpeed: Stat
    public var speed: Stat
    public var luck: Stat
    public var shots: Int
    public var flight: Bool
}

/// The Afterbirth+ stat model.
///
/// Validated against known in-game values before anything was built on it:
///   Isaac base      -> 3.50 damage, delay 10, 2.73 tears/s
///   +Blood of Martyr-> 3.5*sqrt(1*1.2+1)          = 5.19 damage
///   +Cricket's Head -> 3.5*sqrt(0.5*1.2+1)*1.5    = 6.64 damage
///   +Ipecac         -> 3.5*sqrt(40*1.2+1)         = 24.50 damage (exactly 7x)
///   +Sad Onion      -> 16-6*sqrt(0.7*1.3+1)=7.71 -> floor 7 -> 30/8 = 3.75 tears/s
///
/// REP: Repentance removed the tear-delay floor and changed Range from
/// tear-height-derived to tile-based. Neither applies here.
public enum StatEngine {
    public static let baseTearDelay = 16.0
    public static let tearCurveSlope = 6.0
    public static let tearCurveScale = 1.3
    public static let damageCurveScale = 1.2
    /// Tear-ups alone cannot push delay below this; direct modifiers can.
    public static let minDelayFromStats = 5.0
    public static let minDelayAbsolute = 1.0
    public static let maxTearsPerSecond = 15.0

    public static func tearDelay(fromTearUps t: Double) -> Double {
        // The sqrt argument goes negative below t = -1/1.3; clamping at 0 covers
        // every branch in one expression and pins delay at its 16-frame maximum.
        baseTearDelay - tearCurveSlope * (max(0, tearCurveScale * t + 1)).squareRoot()
    }

    public static func tearsPerSecond(delay: Double) -> Double {
        min(maxTearsPerSecond, 30.0 / (delay + 1))
    }

    public static func compute(character: Character, items: [Item]) -> ComputedStats {
        let deltas = items.map(\.delta)

        // --- Damage -------------------------------------------------------
        let damageUps = deltas.compactMap(\.damage).reduce(0, +)
        let multipliers = deltas.compactMap(\.damageMultiplier)
        let damageMult = multipliers.reduce(character.damageMultiplier, *)
        // Clamped exactly like the tear curve: damage-downs (Odd Mushroom (Thin) is
        // -0.4, and stacks) can push the argument below zero, and an unclamped sqrt
        // would yield NaN -- which propagates into the JSON payload and blanks the
        // whole readout rather than being visibly wrong.
        let damageValue =
            character.damage * (max(0, damageCurveScale * damageUps + 1)).squareRoot() * damageMult
        // Whether AB+ stacks two x1.5 damage multipliers or shares one slot is not
        // settled by any source we could verify, so say so instead of guessing.
        // Zero item damage-ups makes the curve term 1, so the base is just the
        // character's damage times their innate multiplier (Judas 1.35, Eve 0.75).
        let damageBase = character.damage * character.damageMultiplier
        let damage = Stat(
            damageValue,
            base: damageBase,
            approx: multipliers.count > 1,
            reason: multipliers.count > 1
                ? "\(multipliers.count) damage multipliers stack here; AB+ may share one slot"
                : nil
        )

        // --- Tears --------------------------------------------------------
        let tearUps = deltas.compactMap(\.tears).reduce(0, +) + character.tears
        var delay = max(minDelayFromStats, tearDelay(fromTearUps: tearUps).rounded(.down))
        delay *= character.fireDelayMultiplier
        // The same curve with no items, so the UI can say what the items were worth.
        let baseDelay = max(
            minDelayAbsolute,
            max(minDelayFromStats, tearDelay(fromTearUps: character.tears).rounded(.down))
                * character.fireDelayMultiplier)

        // Applied in pickup order. The game's ordering among simultaneous direct
        // modifiers is undocumented, so order only matters -- and is only flagged --
        // when more than one is present.
        var directCount = 0
        for d in deltas {
            if let m = d.tearsMultiplier, m > 0 { delay /= m; directCount += 1 }
            if let add = d.tearDelay { delay += add; directCount += 1 }
        }
        delay = max(minDelayAbsolute, delay)

        let orderSensitive = directCount > 1
        let tearDelayStat = Stat(
            delay, base: baseDelay,
            approx: orderSensitive,
            reason: orderSensitive ? "order of simultaneous tear modifiers is undocumented" : nil
        )
        let tears = Stat(
            tearsPerSecond(delay: delay), base: tearsPerSecond(delay: baseDelay),
            approx: orderSensitive, reason: tearDelayStat.reason
        )

        // --- The straightforward ones ------------------------------------
        let range = Stat(
            max(5.0, character.range + deltas.compactMap(\.range).reduce(0, +)),
            base: character.range
        )
        let speed = Stat(
            min(2.0, max(0.1, character.speed + deltas.compactMap(\.speed).reduce(0, +))),
            base: character.speed
        )
        let shotSpeed = Stat(
            max(0.6, character.shotSpeed + deltas.compactMap(\.shotSpeed).reduce(0, +)),
            base: character.shotSpeed
        )
        // Luck is genuinely uncapped; the 0...10 clamp lives inside drop rolls only.
        let luck = Stat(
            character.luck + deltas.compactMap(\.luck).reduce(0, +), base: character.luck)

        return ComputedStats(
            damage: damage, tears: tears, tearDelay: tearDelayStat, range: range,
            shotSpeed: shotSpeed, speed: speed, luck: luck,
            shots: 1 + deltas.compactMap(\.shots).reduce(0, +),
            flight: character.flight || deltas.contains { $0.flight == true }
        )
    }
}
