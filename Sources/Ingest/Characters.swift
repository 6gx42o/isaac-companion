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
            unverified: ["range", "tears"], notes: "Slower; larger health pool."),
        // Luck stays 0: Cain's `items="46"` in players.xml means Lucky Foot is a
        // STARTING ITEM, and the log reports it as a normal pickup. Giving him base
        // luck 1 as well double-counts it. Same rule for every character below --
        // base stats here must exclude anything a starting item grants.
        // MEASURED against the in-game HUD, 2026-08-03, seed GNXQ 9WM1, Cain carrying
        // only Lucky Foot and Scorpio -- and Scorpio changes no numeric stat (it is
        // tearflag/poison only), so the HUD was showing his base stats plus the +1 luck
        // his starting item grants.
        //
        // Two of these were WRONG, and neither was flagged uncertain:
        //   speed  was 1.1, the HUD says 1.3
        //   damage was 3.5, the HUD says 4.2 -- which is 3.5 x 1.2, so he carries a
        //          damage multiplier, modelled the same way Judas's 1.35 is.
        Character(
            id: 2, name: "Cain", speed: 1.3, range: 17.75, damageMultiplier: 1.2,
            notes: "Starts with Lucky Foot (+1 luck). Every stat here was read off "
                + "the in-game HUD."),
        Character(
            id: 3, name: "Judas", damageMultiplier: 1.35,
            unverified: ["damageMultiplier", "speed"], notes: "Higher damage, 1 red heart."),
        Character(
            id: 4, name: "???", unverified: ["speed", "range", "tears"],
            notes: "No red hearts; health ups become soul hearts."),
        Character(
            id: 5, name: "Eve", damageMultiplier: 0.75,
            unverified: ["damageMultiplier", "speed"],
            notes: "Whore of Babylon at low health."),
        Character(
            id: 6, name: "Samson", tears: -0.1, range: 18.75,
            unverified: ["tears", "damage", "range"],
            notes: "Bloody Lust. Tear penalty is -0.1, not -0.05 -- a long-standing "
                + "wiki error corrected in 2022."),
        Character(
            id: 7, name: "Azazel", range: 17.75, fireDelayMultiplier: 0.267, flight: true,
            unverified: ["fireDelayMultiplier", "range"],
            notes: "Short-range Brimstone. The x1/3 figure often quoted is Tainted "
                + "Azazel, a Repentance character that does not exist here."),
        Character(
            id: 8, name: "Lazarus", range: 17.75,
            unverified: ["speed", "tears", "range"]),
        Character(
            id: 9, name: "Eden", unverified: ["damage", "tears", "speed", "range", "shotSpeed", "luck"],
            notes: "Stats are randomised per run; the log cannot tell us them."),
        Character(
            id: 10, name: "The Lost", flight: true,
            unverified: ["damage", "speed"], notes: "Flight, spectral tears, no health."),
        // The 28.75 range often quoted for him is 23.75 + Anemic's +5 -- and Anemic
        // (#214) is his starting item, so it arrives through the log as a pickup.
        // Base range is the standard 23.75; the dispute was a double-count.
        Character(
            id: 11, name: "Lazarus Risen", damageMultiplier: 1.2,
            unverified: ["damageMultiplier"],
            notes: "Starts with Anemic (+5 range)."),
        Character(
            id: 12, name: "Dark Judas", damageMultiplier: 2.0,
            unverified: ["damageMultiplier"], notes: "Counts as Judas for completion marks."),
        Character(
            id: 13, name: "Lilith", unverified: ["damage", "tears", "speed"],
            notes: "Cannot shoot; Incubus attacks for her, so tear stats do not apply "
                + "to Lilith directly."),
        Character(
            id: 14, name: "Keeper", unverified: ["damage", "tears", "speed"],
            notes: "Coin hearts; triple shot."),
        Character(id: 15, name: "Apollyon", unverified: ["speed", "tears"]),
        Character(
            id: 16, name: "The Forgotten", unverified: ["damage", "tears", "range"],
            notes: "Melee bone club; tear stats map differently."),
        Character(
            id: 17, name: "The Forgotten Soul", flight: true,
            unverified: ["damage", "tears", "speed"], notes: "Flight and spectral tears."),
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
