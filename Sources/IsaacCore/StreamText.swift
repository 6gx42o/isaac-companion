import Foundation

/// Writes the run out as a folder of one-line text files, for OBS.
///
/// OBS has no idea what Isaac is, but every version of it can point a Text source at a
/// file and re-read it when it changes. So the integration is a directory: one file per
/// fact, each holding exactly the string a viewer should see and nothing else -- no
/// JSON, no labels, no trailing newline to show up as a blank second line on stream.
///
/// Deliberately dumb and deliberately opt-in. It writes to a folder the user picked,
/// only while it is switched on, and only when a value actually changed.
public struct StreamText: Sendable {

    /// Everything written, as filename -> contents. Pure, so what lands on disk can be
    /// asserted without touching a filesystem.
    public static func fields(
        run: RunState, stats: ComputedStats?, characterName: String,
        transformations: [(name: String, have: Int, need: Int)] = [],
        decimals: Int = 2
    ) -> [String: String] {
        func num(_ d: Double) -> String { String(format: "%.\(decimals)f", d) }

        var out: [String: String] = [
            "seed": run.seed ?? "",
            "character": characterName,
            "floor": run.stage > 0 ? String(run.stage) : "",
            "items": String(run.items.count),
            // The current floor's curses, which is what a viewer is looking at.
            "curses": run.floorCurses.joined(separator: ", "),
            "bosses": String(run.bossesDefeated.count),
        ]

        if let s = stats {
            out["damage"] = num(s.damage.value)
            out["tears"] = num(s.tears.value)
            out["tearDelay"] = num(s.tearDelay.value)
            out["range"] = num(s.range.value)
            out["shotSpeed"] = num(s.shotSpeed.value)
            out["speed"] = num(s.speed.value)
            out["luck"] = num(s.luck.value)
            out["shots"] = String(s.shots)
        }

        // One file per transformation, named after it, holding "2/3". A streamer wires
        // up only the ones they care about rather than parsing a combined blob.
        for t in transformations {
            out["transform-" + slug(t.name)] = "\(t.have)/\(t.need)"
        }
        // And one combined line for the ones actually in progress, since most layouts
        // have room for a single strip rather than fourteen counters.
        let live = transformations
            .filter { $0.have > 0 && $0.have < $0.need }
            .map { "\($0.name) \($0.have)/\($0.need)" }
        out["transformations"] = live.joined(separator: " · ")

        // Pickup order, newest last -- the same order the stat model composes in.
        out["itemlist"] = run.items.map(\.name).joined(separator: "\n")
        out["lastitem"] = run.items.last?.name ?? ""
        return out
    }

    /// Lowercase, hyphenated, and safe as a filename on every platform we ship to.
    static func slug(_ s: String) -> String {
        // Runs of separators collapse, so "Guppy's Head" is guppy-s-head rather than
        // guppy--s-head, and a trailing punctuation mark leaves no dangling dash.
        var out = ""
        var lastWasDash = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Writes only what changed, and returns the new "what is on disk" map.
    ///
    /// Skipping unchanged files matters more than it looks: OBS reloads a Text source
    /// whenever its file's mtime moves, so rewriting all twenty every second makes the
    /// whole layout flicker.
    @discardableResult
    public static func write(
        _ fields: [String: String], to directory: URL, previous: [String: String]
    ) throws -> [String: String] {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, value) in fields where previous[name] != value {
            let url = directory.appending(path: name + ".txt")
            try value.write(to: url, atomically: true, encoding: .utf8)
        }
        // A field that stopped existing (a transformation from a previous run) would
        // otherwise sit on stream forever showing a stale number.
        for name in previous.keys where fields[name] == nil {
            try? fm.removeItem(at: directory.appending(path: name + ".txt"))
        }
        return fields
    }
}
