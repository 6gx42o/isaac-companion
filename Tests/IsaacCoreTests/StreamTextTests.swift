import Testing
import Foundation
@testable import IsaacCore

/// The OBS text folder. Tested against a temp directory rather than mocked, because the
/// whole feature IS the filesystem behaviour -- what lands, what is left alone, and what
/// gets cleaned up.
@Suite("Stream text files")
struct StreamTextTests {

    private func sampleRun() -> RunState {
        var run = RunState()
        run.seed = "AAAA BBBB"
        run.stage = 3
        run.floorCurses = ["Curse of Blind"]
        run.items = [
            PickupRecord(uid: 1, itemID: 1, name: "The Sad Onion"),
            PickupRecord(uid: 2, itemID: 2, name: "The Inner Eye"),
        ]
        return run
    }

    @Test("Each fact is its own file, with no decoration")
    func fieldsAreBare() {
        let f = StreamText.fields(run: sampleRun(), stats: nil, characterName: "Cain")
        #expect(f["seed"] == "AAAA BBBB")
        #expect(f["character"] == "Cain")
        #expect(f["floor"] == "3")
        #expect(f["items"] == "2")
        #expect(f["curses"] == "Curse of Blind")
        #expect(f["lastitem"] == "The Inner Eye", "newest last, matching pickup order")
        // No labels, no punctuation a viewer would have to read past.
        #expect(f["floor"]?.contains("Floor") == false)
    }

    @Test("Transformation names become safe filenames")
    func slugs() {
        #expect(StreamText.slug("Guppy") == "guppy")
        #expect(StreamText.slug("Guppy's Head") == "guppy-s-head")
        #expect(StreamText.slug("Yes Mother?") == "yes-mother", "no trailing dash")
        #expect(StreamText.slug("Bob!!") == "bob")
    }

    @Test("Only in-progress transformations reach the combined line")
    func combinedLineIsProgressOnly() {
        let f = StreamText.fields(
            run: sampleRun(), stats: nil, characterName: "Cain",
            transformations: [
                (name: "Guppy", have: 2, need: 3),
                (name: "Bob", have: 0, need: 3),        // not started
                (name: "Spun", have: 3, need: 3),       // already done
            ])
        #expect(f["transformations"] == "Guppy 2/3")
        // The per-transformation files still carry every one of them.
        #expect(f["transform-guppy"] == "2/3")
        #expect(f["transform-bob"] == "0/3")
        #expect(f["transform-spun"] == "3/3")
    }

    @Test("Files land on disk, one per field")
    func writesFiles() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "streamtext-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fields = ["seed": "AAAA BBBB", "floor": "3"]
        _ = try StreamText.write(fields, to: dir, previous: [:])

        let seed = try String(contentsOf: dir.appending(path: "seed.txt"), encoding: .utf8)
        #expect(seed == "AAAA BBBB", "exactly the value, no trailing newline")
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "floor.txt").path))
    }

    /// OBS reloads a Text source whenever the file's mtime moves, so rewriting an
    /// unchanged value makes the whole layout flicker on every recompute.
    @Test("An unchanged value is not rewritten")
    func unchangedFilesAreLeftAlone() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "streamtext-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = ["seed": "AAAA BBBB", "floor": "3"]
        let state = try StreamText.write(first, to: dir, previous: [:])

        let seedURL = dir.appending(path: "seed.txt")
        let floorURL = dir.appending(path: "floor.txt")
        func mtime(_ u: URL) throws -> Date {
            try #require(
                FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate]
                    as? Date)
        }
        let seedBefore = try mtime(seedURL)
        let floorBefore = try mtime(floorURL)

        // Long enough that a rewrite would be visible in the timestamp.
        Thread.sleep(forTimeInterval: 1.1)
        _ = try StreamText.write(["seed": "AAAA BBBB", "floor": "4"], to: dir, previous: state)

        #expect(try mtime(seedURL) == seedBefore, "seed did not change, so it was not touched")
        #expect(try mtime(floorURL) > floorBefore, "floor did change, so it was rewritten")
        let floor = try String(contentsOf: floorURL, encoding: .utf8)
        #expect(floor == "4")
    }

    /// A transformation from the previous run would otherwise sit on stream forever.
    @Test("A field that disappears takes its file with it")
    func staleFilesAreRemoved() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "streamtext-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let state = try StreamText.write(
            ["seed": "AAAA BBBB", "transform-guppy": "2/3"], to: dir, previous: [:])
        let guppy = dir.appending(path: "transform-guppy.txt")
        #expect(FileManager.default.fileExists(atPath: guppy.path))

        _ = try StreamText.write(["seed": "CCCC DDDD"], to: dir, previous: state)
        #expect(
            !FileManager.default.fileExists(atPath: guppy.path),
            "the new run has no Guppy progress, so the file must go")
    }
}
