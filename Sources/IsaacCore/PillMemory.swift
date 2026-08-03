import Foundation

/// What each pill colour does, for one run.
///
/// The game reshuffles which colour carries which effect at the start of every run, and
/// writes that mapping nowhere the app can reach -- not the log, not a file, not the
/// screen. So there are exactly two ways to learn it, and this holds the result of both:
///
///  1. The player takes a pill and says what it did. One answer covers every future pill
///     of that colour for the rest of the run, which is the point -- the second orange
///     pill of a run should not have to be asked about.
///  2. It is inferred: a colour is identified on screen, the pocket slot is used, and a
///     stat moves in a way exactly one pill explains.
///
/// Deliberately per-run. Carrying a mapping into the next run would be worse than having
/// none, because it would be confidently wrong.
public struct PillMemory: Codable, Equatable, Sendable {

    /// How a colour's effect came to be known. Shown in the UI, because a guess and a
    /// player's own answer should not look the same.
    public enum Source: String, Codable, Sendable {
        /// The player said so.
        case identified
        /// Deduced from a stat that moved when the pill was swallowed.
        case inferred
    }

    public struct Known: Codable, Equatable, Sendable {
        public var effectID: Int
        public var source: Source
        public init(effectID: Int, source: Source) {
            self.effectID = effectID
            self.source = source
        }
    }

    /// Colour index (into the harvested strip) -> what it does.
    public private(set) var byColour: [Int: Known] = [:]
    /// Colours seen this run, in the order first seen, whether or not their effect is
    /// known. Lets the UI list "you have seen three colours; two are still a mystery".
    public private(set) var seen: [Int] = []

    public init() {}

    /// Records that a colour was seen, without claiming to know what it does.
    public mutating func note(colour: Int) {
        guard !seen.contains(colour) else { return }
        seen.append(colour)
    }

    /// Records what a colour does. A player's own answer overrides an inference; an
    /// inference never overrides an answer, because the player watched it happen and the
    /// inference is arithmetic on a noisy signal.
    public mutating func learn(colour: Int, effectID: Int, source: Source) {
        note(colour: colour)
        if let existing = byColour[colour],
           existing.source == .identified, source == .inferred {
            return
        }
        byColour[colour] = Known(effectID: effectID, source: source)
    }

    public func effect(of colour: Int) -> Known? { byColour[colour] }

    /// Colours seen whose effect is still unknown.
    public var unknownColours: [Int] { seen.filter { byColour[$0] == nil } }

    public mutating func forget(colour: Int) { byColour[colour] = nil }

    /// A new run means a new shuffle, so everything here is void.
    public mutating func reset() {
        byColour.removeAll()
        seen.removeAll()
    }
}
