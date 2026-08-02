import Testing
import Foundation
@testable import IsaacCore

/// The tailer's two real hazards are (a) attaching while a run is already in
/// progress and (b) the game rewriting log.txt from scratch on relaunch. Both are
/// exercised here against a real file on disk.
@Suite(.serialized)
struct LogTailerTests {

    private func tempLog() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "isaac-tailer-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "log.txt")
    }

    /// Collects lines until `count` have arrived or the deadline passes.
    private func collect(
        url: URL, expecting count: Int, timeout: TimeInterval = 3,
        while body: @escaping () -> Void
    ) async -> [String] {
        let box = Box()
        let tailer = LogTailer(url: url) { lines in box.append(lines) }
        tailer.start()
        // Give the tailer a moment to attach before mutating the file.
        try? await Task.sleep(for: .milliseconds(150))
        body()
        let deadline = Date().addingTimeInterval(timeout)
        while box.count < count, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        tailer.stop()
        return box.lines
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ lines: [String]) {
            lock.lock(); defer { lock.unlock() }
            storage.append(contentsOf: lines)
        }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
        var count: Int { lock.lock(); defer { lock.unlock() }; return storage.count }
    }

    @Test("Replays an existing log so attaching mid-run rebuilds the inventory")
    func replaysExistingContent() async throws {
        let url = tempLog()
        try """
            [INFO] - RNG Start Seed: AAAA BBBB (1)
            [INFO] - Initialized player with Variant 0 and Subtype 0
            [INFO] - Adding collectible 1 (The Sad Onion)

            """.write(to: url, atomically: true, encoding: .utf8)

        let lines = await collect(url: url, expecting: 3) {}
        var reducer = RunReducer()
        let state = reducer.replay(LogParser().parse(lines: lines.joined(separator: "\n")))
        #expect(state.seed == "AAAA BBBB")
        #expect(state.items.map(\.itemID) == [1])
    }

    @Test("Picks up appended lines")
    func followsAppends() async throws {
        let url = tempLog()
        try "[INFO] - RNG Start Seed: AAAA BBBB (1)\n".write(
            to: url, atomically: true, encoding: .utf8)

        let lines = await collect(url: url, expecting: 2) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data("[INFO] - Adding collectible 118 (Brimstone)\n".utf8))
                try? handle.close()
            }
        }
        #expect(lines.contains { $0.contains("Brimstone") })
    }

    @Test("Truncation emits a reset so the previous run is not carried forward")
    func detectsTruncation() async throws {
        let url = tempLog()
        try """
            [INFO] - RNG Start Seed: AAAA BBBB (1)
            [INFO] - Adding collectible 1 (The Sad Onion)
            [INFO] - Adding collectible 2 (The Inner Eye)

            """.write(to: url, atomically: true, encoding: .utf8)

        let lines = await collect(url: url, expecting: 5, timeout: 5) {
            // The game rewrites log.txt on every launch, which shows up as the file
            // getting shorter.
            try? "[INFO] - RNG Start Seed: CCCC DDDD (2)\n".write(
                to: url, atomically: false, encoding: .utf8)
        }
        #expect(lines.contains(LogTailer.resetMarker))
        #expect(lines.contains { $0.contains("CCCC DDDD") })
    }

    @Test("A partial trailing line is held back until it is complete")
    func holdsPartialLines() async throws {
        let url = tempLog()
        try "".write(to: url, atomically: true, encoding: .utf8)

        let lines = await collect(url: url, expecting: 1, timeout: 3) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.write(Data("[INFO] - Adding collectible 118 (Brim".utf8))
            try? handle.synchronize()
            Thread.sleep(forTimeInterval: 0.3)
            handle.write(Data("stone)\n".utf8))
            try? handle.close()
        }
        // The name must never be split across two callbacks.
        #expect(lines.contains("[INFO] - Adding collectible 118 (Brimstone)"))
        #expect(!lines.contains { $0.hasSuffix("(Brim") })
    }
}
