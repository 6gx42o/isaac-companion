import Foundation

/// Character base stats measured from the game's own HUD.
///
/// The hardcoded table in `Ingest.Characters` is the best available guess; this is what
/// the game actually showed. Cain is why this exists: three of his six values were wrong,
/// two of them not even flagged as doubtful, and the only thing that found it was reading
/// the numbers off the screen and comparing.
///
/// So rather than researching eighteen characters and hoping, the app records what it is
/// shown. Play a character, read the HUD, and that row is settled permanently -- for this
/// install, from this build of the game, with no source to be wrong about.
///
/// Keyed by PlayerType, which is what the log reports.
public struct MeasuredBases: Codable, Equatable, Sendable {

    public struct Measurement: Codable, Equatable, Sendable {
        public var damage: Double?
        public var tearDelay: Double?
        public var range: Double?
        public var shotSpeed: Double?
        public var speed: Double?
        public var luck: Double?
        /// When it was taken, so a stale reading can be spotted after a game patch.
        public var takenAt: Date
        /// The game build that was running. A patch can change these, and a measurement
        /// from a different build is a lead rather than an answer.
        public var gameVersion: String?

        public init(
            damage: Double? = nil, tearDelay: Double? = nil, range: Double? = nil,
            shotSpeed: Double? = nil, speed: Double? = nil, luck: Double? = nil,
            takenAt: Date, gameVersion: String? = nil
        ) {
            self.damage = damage
            self.tearDelay = tearDelay
            self.range = range
            self.shotSpeed = shotSpeed
            self.speed = speed
            self.luck = luck
            self.takenAt = takenAt
            self.gameVersion = gameVersion
        }

        /// Which stats this actually pins down. A partial measurement is still worth
        /// keeping -- one confirmed range beats a guessed one.
        public var fields: [String] {
            var out: [String] = []
            if damage != nil { out.append("damage") }
            if tearDelay != nil { out.append("tears") }
            if range != nil { out.append("range") }
            if shotSpeed != nil { out.append("shotSpeed") }
            if speed != nil { out.append("speed") }
            if luck != nil { out.append("luck") }
            return out
        }

        public var isEmpty: Bool { fields.isEmpty }
    }

    public private(set) var byPlayerType: [Int: Measurement] = [:]

    public init() {}

    public func measurement(for playerType: Int?) -> Measurement? {
        guard let playerType else { return nil }
        return byPlayerType[playerType]
    }

    /// Stores a reading, merging field by field so a later partial measurement tops up an
    /// earlier one rather than blanking what it did not cover.
    public mutating func record(playerType: Int, _ new: Measurement) {
        guard !new.isEmpty else { return }
        guard var existing = byPlayerType[playerType] else {
            byPlayerType[playerType] = new
            return
        }
        existing.damage = new.damage ?? existing.damage
        existing.tearDelay = new.tearDelay ?? existing.tearDelay
        existing.range = new.range ?? existing.range
        existing.shotSpeed = new.shotSpeed ?? existing.shotSpeed
        existing.speed = new.speed ?? existing.speed
        existing.luck = new.luck ?? existing.luck
        existing.takenAt = new.takenAt
        existing.gameVersion = new.gameVersion ?? existing.gameVersion
        byPlayerType[playerType] = existing
    }

    public mutating func forget(playerType: Int) { byPlayerType[playerType] = nil }

    // MARK: - disk

    /// Small enough that plain JSON beats the gzip the bundles use, and being readable
    /// matters: this is the file someone would send when a number looks wrong.
    public static func load(from url: URL) -> MeasuredBases {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(MeasuredBases.self, from: data)
        else { return MeasuredBases() }
        return decoded
    }

    public func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

extension Character {
    /// Applies a measurement over the researched defaults, and clears the `unverified`
    /// flags it covers -- those flags mean "nobody has checked", and now somebody has.
    public func measured(with m: MeasuredBases.Measurement?) -> Character {
        guard let m, !m.isEmpty else { return self }
        var out = self
        if let v = m.damage { out.damage = v; out.damageMultiplier = 1 }
        if let v = m.range { out.range = v }
        if let v = m.shotSpeed { out.shotSpeed = v }
        if let v = m.speed { out.speed = v }
        if let v = m.luck { out.luck = v }
        // Tear delay is what the Afterbirth+ HUD shows; the engine works in tear-ups.
        // Invert the curve rather than subtracting, because it is a square root:
        //   delay = 16 - 6*sqrt(1.3*t + 1)   =>   t = (((16-delay)/6)^2 - 1) / 1.3
        // Delay 10 gives t = 0, which is the zero point the whole model is built on.
        if let delay = m.tearDelay {
            let root = (StatEngine.baseTearDelay - delay) / StatEngine.tearCurveSlope
            out.tears = (root * root - 1) / StatEngine.tearCurveScale
        }
        let covered = Set(m.fields)
        out.unverified.removeAll { covered.contains($0) }
        return out
    }
}
