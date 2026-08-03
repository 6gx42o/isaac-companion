import Foundation

/// Past runs on disk.
///
/// One JSON file per run rather than one growing file, for a boring but decisive reason:
/// the checkpoint rewrites the in-progress run every minute, and rewriting a single file
/// containing every run you have ever played gets slower forever and loses everything if
/// it is interrupted at the wrong moment.
///
/// The directory is injected rather than reached for, so tests run against a temp dir --
/// the same shape `LogTailerTests` uses.
public struct RunArchive: Sendable {
    public let directory: URL
    /// Keeps the archive from growing without limit. A run is a few KB, so this is
    /// generous; it exists so an unattended machine cannot fill a disk.
    public let limit: Int

    public init(directory: URL, limit: Int = 500) {
        self.directory = directory
        self.limit = limit
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func url(for id: String) -> URL {
        // The id is derived from a timestamp, but sanitise anyway -- an id that escaped
        // into a path separator would write outside the archive.
        let safe = id.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return directory.appending(path: "\(safe).json")
    }

    /// Writes (or replaces) one run.
    ///
    /// Via a temp file and an atomic replace, so a crash mid-write leaves the previous
    /// version rather than a truncated file -- the same discipline `Pipeline.write` uses
    /// for the data bundle, and it matters more here because the checkpoint writes often.
    public func save(_ run: RunSummary) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(run)
        let target = url(for: run.id)
        let temp = directory.appending(path: ".\(UUID().uuidString).tmp")
        try data.write(to: temp)
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
        } catch {
            // replaceItemAt fails when there is nothing to replace.
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temp, to: target)
        }
        try? prune()
    }

    /// Every stored run, newest first.
    ///
    /// A file that will not decode is skipped rather than thrown: one bad record from an
    /// older schema should not make the whole history unreadable.
    public func load() -> [RunSummary] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(RunSummary.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(id: String) throws {
        try FileManager.default.removeItem(at: url(for: id))
    }

    public func deleteAll() throws {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        else { return }
        for f in files where f.pathExtension == "json" {
            try FileManager.default.removeItem(at: f)
        }
    }

    private func prune() throws {
        let all = load()
        guard all.count > limit else { return }
        for run in all.dropFirst(limit) {
            try? delete(id: run.id)
        }
    }

    // MARK: - what the history is for

    /// Totals across the archive. Cheap enough to recompute on every load; the archive is
    /// hundreds of records, not millions.
    public struct Totals: Sendable, Equatable {
        public var runs = 0
        public var wins = 0
        public var deaths = 0
        public var abandoned = 0
        public var deepestStage = 0
        public var totalTime: TimeInterval = 0
        /// Item name to how many runs took it, most-taken first.
        public var favouriteItems: [(name: String, count: Int)] = []
        /// Character name to (runs, wins).
        public var byCharacter: [(name: String, runs: Int, wins: Int)] = []

        public static func == (a: Totals, b: Totals) -> Bool {
            a.runs == b.runs && a.wins == b.wins && a.deaths == b.deaths
                && a.abandoned == b.abandoned && a.deepestStage == b.deepestStage
                && a.totalTime == b.totalTime
                && a.favouriteItems.map(\.name) == b.favouriteItems.map(\.name)
                && a.byCharacter.map(\.name) == b.byCharacter.map(\.name)
        }
    }

    public static func totals(of runs: [RunSummary]) -> Totals {
        var t = Totals()
        var itemCounts: [String: Int] = [:]
        var charRuns: [String: Int] = [:]
        var charWins: [String: Int] = [:]
        for run in runs where run.outcome != .inProgress {
            t.runs += 1
            switch run.outcome {
            case .won: t.wins += 1
            case .died: t.deaths += 1
            case .abandoned: t.abandoned += 1
            case .inProgress: break
            }
            t.deepestStage = max(t.deepestStage, run.finalStage)
            t.totalTime += run.duration ?? 0
            // Per RUN, not per pickup: two copies of the same item in one run is still
            // one run that took it.
            for name in Set(run.items.map(\.name)) {
                itemCounts[name, default: 0] += 1
            }
            charRuns[run.characterName, default: 0] += 1
            if run.outcome == .won { charWins[run.characterName, default: 0] += 1 }
        }
        t.favouriteItems = itemCounts
            .map { (name: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
        t.byCharacter = charRuns
            .map { (name: $0.key, runs: $0.value, wins: charWins[$0.key] ?? 0) }
            .sorted { ($0.runs, $1.name) > ($1.runs, $0.name) }
        return t
    }
}
