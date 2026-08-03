import Foundation
import IsaacCore

/// Base stats for the Afterbirth+ roster.
///
/// These are hardcoded in the game binary. `players.xml` carries only health,
/// starting pickups and starting items -- no stats -- so there is no machine-
/// readable source for any of this, in the game files or anywhere online.
///
/// So: Isaac's row is confirmed (3.5 damage, delay 10, 2.73 tears/s -- the values
/// the whole stat model was validated against). Every other row lists the fields
/// we have NOT confirmed in `unverified`, and the UI flags them rather than
/// presenting a guess as fact. They get filled in by comparing against the
/// in-game FoundHUD (`FoundHUD=1` in options.ini), one character at a time.
///
/// Cain is the first row filled in that way, and it cost three of six values being
/// wrong -- speed, damage and range. Two of the three were not even flagged as
/// doubtful, which is the part worth remembering: confidence here has been a poor
/// guide to correctness, so nothing goes in unflagged without a measurement.
///
/// SOURCE for the researched rows: each character's own wiki page, read as raw wikitext
/// (`?action=raw`) rather than as a rendered page. That matters more than it sounds --
/// the rendered summaries were transcribed wrongly twice, while the wikitext states each
/// parameter by name and tags its version explicitly, e.g. Cain's
/// `range = {{dlcalt|17.75|r=4.5}}`. Reading it that way reproduced all three of Cain's
/// independently measured values exactly, which is why it is trusted for the rest.
///
/// A parameter absent from an infobox means "same as Isaac", which is how the rows with
/// no `unverified` entries below are settled: The Lost, Lilith and Apollyon genuinely
/// carry Isaac's numbers, and saying so is an answer rather than a gap.
///
/// Where a value here came from research rather than a measurement it is still listed
/// in `unverified`, even when it is almost certainly better than the default. Azazel at
/// 17.75 is a researched number and Isaac's 23.75 would definitely be wrong for him, but
/// "less wrong" is not "confirmed" and the UI should keep saying so.
///
/// Research rule learned the hard way: use each character's OWN page, never a summary
/// comparison table. Every such table found quoted Repentance values throughout while
/// being presented as general, and one of them had Azazel's fire-delay multiplier
/// sitting on Lazarus's row.
///
/// A note on RANGE, since it is the field most easily got wrong. Afterbirth+ and
/// Repentance use different scales for the same stat: Isaac reads 23.75 here and 6.5
/// in Repentance. Every casual source and most wiki summary tables quote the
/// Repentance number, so a value in the single digits in this file is a version
/// mix-up, not a short-ranged character.
public enum Characters {
    public static let all: [Character] = [
        Character(id: 0, name: "Isaac"),
        Character(
            id: 1, name: "Magdalene", speed: 0.85,
            notes: "Slower; larger health pool. Every other stat is Isaac's."),
        // MEASURED against the in-game HUD, 2026-08-03, seed GNXQ 9WM1, Cain carrying
        // only Lucky Foot and Scorpio -- and Scorpio changes no numeric stat (it is
        // tearflag/poison only), so the HUD was showing his base stats plus the +1 luck
        // his starting item grants.
        //
        // Three of six were WRONG, and only one was flagged uncertain:
        //   speed  was 1.1,   the HUD says 1.3
        //   damage was 3.5,   the HUD says 4.2 -- that is 3.5 x 1.2, a missing multiplier
        //   range  was 23.75, the HUD says 17.75
        Character(
            id: 2, name: "Cain", speed: 1.3, range: 17.75, damageMultiplier: 1.2,
            notes: "Starts with Lucky Foot (+1 luck). Every stat here was read off "
                + "the in-game HUD."),
        Character(
            id: 3, name: "Judas", damageMultiplier: 1.35,
            unverified: ["damageMultiplier"], notes: "Higher damage, 1 red heart."),
        Character(
            id: 4, name: "???", speed: 1.1, damageMultiplier: 1.05,
            unverified: ["damageMultiplier", "speed"],
            notes: "No red hearts; health ups become soul hearts."),
        Character(
            id: 5, name: "Eve", speed: 1.23, damageMultiplier: 0.75,
            unverified: ["damageMultiplier", "speed"],
            notes: "Whore of Babylon at low health, where the multiplier becomes x1.00."),
        Character(
            id: 6, name: "Samson", tears: -0.1, speed: 1.1, range: 18.75, shotSpeed: 1.31,
            unverified: ["tears", "range", "shotSpeed", "speed"],
            notes: "Bloody Lust. Tear penalty is -0.1, not -0.05 -- a long-standing "
                + "wiki error corrected in 2022."),
        Character(
            id: 7, name: "Azazel", tears: 0.5, speed: 1.25, range: 17.75,
            damageMultiplier: 1.5, fireDelayMultiplier: 0.267, flight: true,
            unverified: ["damageMultiplier", "fireDelayMultiplier", "tears", "range", "speed"],
            notes: "Short-range Brimstone. The x1/3 figure often quoted is Tainted "
                + "Azazel, a Repentance character that does not exist here."),
        Character(
            id: 8, name: "Lazarus", range: 17.75, luck: -1,
            unverified: ["range", "luck"]),
        Character(
            id: 9, name: "Eden",
            unverified: ["damage", "tears", "speed", "range", "shotSpeed", "luck"],
            notes: "Randomised per run around Isaac's values -- damage +/-1.0, tears "
                + "+/-0.75, shot speed +/-0.25, range +/-5.00, speed +/-0.15, luck +/-1. "
                + "The log never reports which roll you got, so measure it if you care."),
        Character(
            id: 10, name: "The Lost", flight: true,
            notes: "Flight, spectral tears, no health. Every stat is Isaac's."),
        // The 28.75 range often quoted for him is 23.75 + Anemic's +5 -- and Anemic
        // (#214) is his starting item, so it arrives through the log as a pickup.
        // Base range is the standard 23.75; the dispute was a double-count.
        Character(
            id: 11, name: "Lazarus Risen", speed: 1.25, damageMultiplier: 1.2,
            unverified: ["damageMultiplier", "speed"],
            notes: "Starts with Anemic (+5 range)."),
        Character(
            id: 12, name: "Dark Judas", speed: 1.1, damageMultiplier: 2.0,
            unverified: ["damageMultiplier", "speed"],
            notes: "Counts as Judas for completion marks."),
        Character(
            id: 13, name: "Lilith",
            notes: "Cannot shoot; Incubus attacks for her, so tear stats do not apply "
                + "to Lilith directly. Every stat is Isaac's."),
        Character(
            id: 14, name: "Keeper", tears: -2, speed: 0.85, luck: -2, damageMultiplier: 1.2,
            unverified: ["damageMultiplier", "tears", "speed", "luck"],
            notes: "Coin hearts; triple shot. Four stats differ from Isaac's, which is "
                + "more than any other character."),
        Character(id: 15, name: "Apollyon", notes: "Every stat is Isaac's."),
        Character(
            id: 16, name: "The Forgotten", damageMultiplier: 1.5, fireDelayMultiplier: 0.5,
            unverified: ["damageMultiplier", "fireDelayMultiplier"],
            notes: "Melee bone club; tear stats map differently."),
        Character(
            id: 17, name: "The Forgotten Soul", speed: 1.3, flight: true,
            unverified: ["speed"], notes: "Flight and spectral tears."),
    ]

    public static func byID(_ id: Int) -> Character? { all.first { $0.id == id } }

    /// Unknown PlayerType falls back to Isaac's baseline rather than failing --
    /// but says so, so the UI never silently shows Isaac's numbers for someone else.
    public static func resolve(_ id: Int?) -> Character {
        guard let id, let c = byID(id) else {
            var fallback = Character(id: id ?? -1, name: "Unknown")
            fallback.unverified = ["damage", "tears", "speed", "range", "shotSpeed", "luck"]
            fallback.notes = "Unrecognised PlayerType; showing Isaac's baseline."
            return fallback
        }
        return c
    }
}
