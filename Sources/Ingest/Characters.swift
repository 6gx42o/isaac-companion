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
        Character(
            id: 2, name: "Cain", speed: 1.1,
            unverified: ["range", "shotSpeed"], notes: "Starts with Lucky Foot (+1 luck)."),
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
            id: 6, name: "Samson", tears: -0.1,
            unverified: ["tears", "damage"],
            notes: "Bloody Lust. Tear penalty is -0.1, not -0.05 -- a long-standing "
                + "wiki error corrected in 2022."),
        Character(
            id: 7, name: "Azazel", fireDelayMultiplier: 0.267, flight: true,
            unverified: ["fireDelayMultiplier", "range"],
            notes: "Short-range Brimstone. The x1/3 figure often quoted is Tainted "
                + "Azazel, a Repentance character that does not exist here."),
        Character(id: 8, name: "Lazarus", unverified: ["speed", "tears"]),
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
