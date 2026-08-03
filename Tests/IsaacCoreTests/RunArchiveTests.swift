import Foundation
import Testing

@testable import IsaacCore

@Suite("RunSummary")
struct RunSummaryTests {
    @Test("A run that beat a final boss is a win even if it then ended in death")
    func winBeatsDeath() {
        // You can kill Isaac and die on the way out of the room. The order matters, and
        // "died" is the more recent fact, so a naive check would call this a loss.
        #expect(RunSummary.outcome(bosses: ["Monstro", "Isaac"], died: true) == .won)
        #expect(RunSummary.outcome(bosses: ["Mega Satan"], died: false) == .won)
    }

    @Test("Otherwise a death is a death and everything else was abandoned")
    func otherOutcomes() {
        #expect(RunSummary.outcome(bosses: ["Monstro"], died: true) == .died)
        // Quit to the menu, closed the game: no death, no final boss.
        #expect(RunSummary.outcome(bosses: ["Monstro"], died: false) == .abandoned)
        #expect(RunSummary.outcome(bosses: [], died: false) == .abandoned)
    }
}

@Suite("RunArchive", .serialized)
struct RunArchiveTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "isaac-archive-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func run(
        _ id: String, started: Date, outcome: RunSummary.Outcome = .died,
        character: String = "Isaac", items: [String] = [], stage: Int = 3
    ) -> RunSummary {
        RunSummary(
            id: id, startedAt: started, endedAt: started.addingTimeInterval(600),
            seed: "ABCD 1234", characterID: 0, characterName: character,
            finalStage: stage, finalStageType: 0, curses: [],
            items: items.enumerated().map {
                RunSummary.Item(id: $0.offset, name: $0.element, manual: false)
            },
            bosses: outcome == .won ? ["Isaac"] : ["Monstro"],
            death: outcome == .died ? "Killed by Monstro" : nil,
            outcome: outcome,
            finalStats: [RunSummary.Stat(key: "damage", value: 5.2, base: 3.5, approx: false)])
    }

    @Test("A saved run reads back exactly")
    func roundTrip() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RunArchive(directory: dir)
        let original = run("a", started: Date(timeIntervalSince1970: 1_000_000),
            items: ["Sad Onion", "Ipecac"])
        try archive.save(original)
        let loaded = archive.load()
        #expect(loaded.count == 1)
        #expect(loaded.first == original)
    }

    @Test("Two runs in one session are both kept")
    func twoRuns() throws {
        // The thing that was impossible before: starting a second run overwrote the
        // first, in memory, with nothing written down.
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RunArchive(directory: dir)
        try archive.save(run("first", started: Date(timeIntervalSince1970: 1_000)))
        try archive.save(run("second", started: Date(timeIntervalSince1970: 2_000)))
        let loaded = archive.load()
        #expect(loaded.count == 2)
        // Newest first.
        #expect(loaded.map(\.id) == ["second", "first"])
    }

    @Test("Re-saving the same run replaces it rather than duplicating it")
    func checkpointReplaces() throws {
        // This is the checkpoint's path: the same run is written repeatedly while it is
        // being played, and must not accumulate.
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RunArchive(directory: dir)
        let start = Date(timeIntervalSince1970: 5_000)
        try archive.save(run("live", started: start, outcome: .inProgress, items: ["Sad Onion"]))
        try archive.save(run("live", started: start, outcome: .inProgress,
            items: ["Sad Onion", "Ipecac"]))
        try archive.save(run("live", started: start, outcome: .died,
            items: ["Sad Onion", "Ipecac"]))
        let loaded = archive.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.outcome == .died)
        #expect(loaded.first?.items.count == 2)
    }

    @Test("An unreadable file does not take the rest of the history with it")
    func toleratesJunk() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RunArchive(directory: dir)
        try archive.save(run("good", started: Date(timeIntervalSince1970: 1_000)))
        try Data("this is not json".utf8).write(to: dir.appending(path: "broken.json"))
        // One record from an older schema must not make the whole archive unreadable.
        #expect(archive.load().map(\.id) == ["good"])
    }

    @Test("An empty or missing directory is empty, not an error")
    func emptyArchive() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "isaac-archive-does-not-exist-\(UUID().uuidString)")
        #expect(RunArchive(directory: missing).load().isEmpty)
    }

    @Test("Deleting removes one run and leaves the others")
    func delete() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RunArchive(directory: dir)
        try archive.save(run("a", started: Date(timeIntervalSince1970: 1_000)))
        try archive.save(run("b", started: Date(timeIntervalSince1970: 2_000)))
        try archive.delete(id: "a")
        #expect(archive.load().map(\.id) == ["b"])
        try archive.deleteAll()
        #expect(archive.load().isEmpty)
    }

    @Test("The oldest runs are pruned once the limit is passed")
    func prunes() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RunArchive(directory: dir, limit: 3)
        for i in 1...5 {
            try archive.save(run("r\(i)", started: Date(timeIntervalSince1970: Double(i * 1000))))
        }
        let loaded = archive.load()
        #expect(loaded.count == 3)
        #expect(loaded.map(\.id) == ["r5", "r4", "r3"])
    }

    @Test("An id cannot write outside the archive directory")
    func idIsSanitised() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RunArchive(directory: dir)
        try archive.save(run("../escape", started: Date(timeIntervalSince1970: 1_000)))
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents.count == 1)
        #expect(!FileManager.default.fileExists(
            atPath: dir.deletingLastPathComponent().appending(path: "escape.json").path))
    }

    @Test("Two runs starting in the same second get different ids")
    func idsDoNotCollide() throws {
        // The id is the filename. With second precision two runs begun in the same
        // second were the same file, and the second silently replaced the first --
        // unreachable while actually playing, immediately reachable from a replayed log.
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RunArchive(directory: dir)
        let t1 = Date(timeIntervalSince1970: 1_000.100)
        let t2 = Date(timeIntervalSince1970: 1_000.900)
        #expect(RunSummary.id(for: t1) != RunSummary.id(for: t2))
        try archive.save(run(RunSummary.id(for: t1), started: t1, character: "Isaac"))
        try archive.save(run(RunSummary.id(for: t2), started: t2, character: "Cain"))
        #expect(archive.load().count == 2)
    }

    @Test("Totals count runs, not pickups, and ignore one still in progress")
    func totals() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RunArchive(directory: dir)
        try archive.save(run("a", started: Date(timeIntervalSince1970: 1_000),
            outcome: .won, character: "Isaac", items: ["Sad Onion", "Ipecac"], stage: 11))
        try archive.save(run("b", started: Date(timeIntervalSince1970: 2_000),
            outcome: .died, character: "Isaac", items: ["Sad Onion"], stage: 4))
        try archive.save(run("c", started: Date(timeIntervalSince1970: 3_000),
            outcome: .abandoned, character: "Cain", items: ["Sad Onion"], stage: 2))
        // Still being played: it has no outcome yet and must not skew the numbers.
        try archive.save(run("d", started: Date(timeIntervalSince1970: 4_000),
            outcome: .inProgress, character: "Cain", items: ["Brimstone"], stage: 1))

        let t = RunArchive.totals(of: archive.load())
        #expect(t.runs == 3)
        #expect(t.wins == 1)
        #expect(t.deaths == 1)
        #expect(t.abandoned == 1)
        #expect(t.deepestStage == 11)
        #expect(t.favouriteItems.first?.name == "Sad Onion")
        #expect(t.favouriteItems.first?.count == 3)
        // Brimstone belongs to the in-progress run, so it should not appear at all.
        #expect(!t.favouriteItems.contains { $0.name == "Brimstone" })
        #expect(t.byCharacter.first?.name == "Isaac")
        #expect(t.byCharacter.first?.runs == 2)
        #expect(t.byCharacter.first?.wins == 1)
    }
}
