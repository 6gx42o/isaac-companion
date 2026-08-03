import Testing
import Foundation
@testable import Ingest
@testable import IsaacCore

/// The app must keep working after the user deletes the EID mods — which they have to
/// do, because any enabled mod turns Steam achievements off. That makes the vendored
/// snapshot load-bearing, and it has already silently broken once: adding non-optional
/// `cards`/`pills` fields turned a stale snapshot into a hard decode failure, so the
/// whole mods-deleted path died with "no item description data available".
///
/// These tests pin both halves: the snapshot must be complete, and it must survive a
/// schema that has moved on.
private let vendoredURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // IngestTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // package root
    .appending(path: "Sources/IsaacCompanionApp/VendoredData/eid.abplus.json")

private let snapshot: VendoredEID? = {
    guard let data = try? Data(contentsOf: vendoredURL) else { return nil }
    return try? JSONDecoder().decode(VendoredEID.self, from: data)
}()

@Suite(.enabled(if: snapshot != nil, "no vendored snapshot on disk"))
struct VendoredCompletenessTests {
    let v = snapshot!

    @Test("Snapshot carries everything the live path produces")
    func noGaps() {
        #expect(v.gaps.isEmpty, "vendored snapshot is missing: \(v.gaps)")
        #expect(v.collectibles.count > 500)
        #expect(v.trinkets.count > 120)
        #expect((v.cards ?? []).count == 54)
        #expect((v.pills ?? []).count == 47)
        #expect((v.conditionalDescs ?? [:]).count > 50)
        #expect((v.transformationNames ?? []).count > 10)
    }

    @Test("The weapon-override lattice is vendored, not just the descriptions")
    func latticeVendored() {
        // Its only source is eid_conditionals.lua inside the mod folder, so if it is
        // not frozen here every override and synergy verdict disappears with the mod.
        guard let s = v.synergies else {
            Issue.record("no synergy lattice in the snapshot")
            return
        }
        #expect(s.layers[118] == 666, "Brimstone's rung must survive vendoring")
        #expect(s.layers[168] == 900)
        #expect(s.overrides.count > 100)
        #expect(s.named.count > 10)
        #expect(s.transformations.count >= 13)
    }

    @Test("Round trip through asResult() loses nothing")
    func roundTrip() {
        let r = v.asResult()
        #expect(r.collectibles.count == v.collectibles.count)
        #expect(r.trinkets.count == v.trinkets.count)
        #expect(r.cards.count == (v.cards ?? []).count)
        #expect(r.pills.count == (v.pills ?? []).count)
        #expect(r.conditionalDescs.count == (v.conditionalDescs ?? [:]).count)
        #expect(r.transformationNames.count == (v.transformationNames ?? []).count)
        // Spot-check a known entry survives intact.
        #expect(r.collectibles[118]?.name == "Brimstone")
        #expect(r.cards[1]?.name == "0 - The Fool")
        #expect(r.pills[1]?.name == "Bad Trip")
    }
}

@Suite("Vendored schema tolerance")
struct VendoredToleranceTests {

    @Test("A snapshot from an older build still decodes")
    func oldSnapshotDecodes() throws {
        // Exactly the shape that broke: only the three original fields. Every field
        // added since must be optional, or this throws and the app is left with no
        // data at all the moment the mods come out.
        let legacy = """
            {"collectibles":[{"id":1,"name":"The Sad Onion","text":"x","delta":{}}],
             "trinkets":[{"id":1,"name":"Swallowed Penny","text":"y","delta":{}}],
             "transformations":{"1":["3"]}}
            """
        let decoded = try JSONDecoder().decode(
            VendoredEID.self, from: Data(legacy.utf8))
        #expect(decoded.collectibles.count == 1)
        #expect(decoded.cards == nil)
        #expect(decoded.synergies == nil)

        // It must still produce a usable result rather than crashing…
        let r = decoded.asResult()
        #expect(r.collectibles[1]?.name == "The Sad Onion")
        #expect(r.cards.isEmpty)

        // …and it must say what it cannot supply, so the degradation is visible.
        #expect(decoded.gaps.contains("cards"))
        #expect(decoded.gaps.contains("the weapon-override lattice"))
    }

    @Test("A complete snapshot reports no gaps")
    func completeReportsNoGaps() throws {
        guard let v = snapshot else { return }
        #expect(v.gaps.isEmpty)
    }
}

@Suite("Character bases measured against the game")
struct MeasuredCharacterTests {
    /// Pins the values read off the in-game HUD, so the shipped table cannot drift away
    /// from the only numbers here that were checked against Isaac itself rather than
    /// against a mod's data files.
    @Test("Cain carries the speed and damage the HUD showed")
    func cain() {
        let cain = Characters.resolve(2)
        #expect(cain.name == "Cain")
        #expect(cain.speed == 1.3, "the HUD showed 1.3, not the 1.1 this used to claim")
        #expect(
            cain.damageMultiplier == 1.2,
            "the HUD showed 4.2 damage, which is 3.5 x 1.2 -- the multiplier was missing")
        // Base luck must stay 0: Lucky Foot is his starting item and the log reports it
        // as an ordinary pickup, so a base of 1 would read 2 in game.
        #expect(cain.luck == 0)
        // Range: 17.75, not Isaac's 23.75. Read off the HUD and confirmed against the
        // wiki's own Cain page, which gives 17.75 before Repentance and 4.5 after.
        #expect(cain.range == 17.75, "the HUD showed 17.75")
        // Nothing left unmeasured for Cain, which is what makes him the reference row.
        #expect(cain.unverified.isEmpty, "every one of Cain's stats has now been measured")
    }
}

@Suite("Range is on the Afterbirth+ scale, not Repentance's")
struct RangeScaleTests {
    /// The single easiest way to corrupt this table. Afterbirth+ and Repentance display
    /// the same stat on different scales -- Isaac reads 23.75 here and 6.5 there -- and
    /// every summary table found online quotes the Repentance number while presenting it
    /// as general. A single-digit range in this file means a version mix-up got in.
    @Test("no character carries a Repentance-scale range")
    func noRepentanceScale() {
        for c in Characters.all {
            // Comment is a string literal type, so this cannot be built with `+`.
            #expect(
                c.range >= 10,
                "\(c.name) has range \(c.range), which is the Repentance scale (Isaac 6.5)")
            #expect(c.range <= 40, "\(c.name) has an implausible range \(c.range)")
        }
    }

    /// Isaac is the row the whole stat model was validated against; if it moves, every
    /// number the app shows moves with it.
    @Test("Isaac is still the 23.75 baseline")
    func isaacBaseline() {
        let isaac = Characters.resolve(0)
        #expect(isaac.range == 23.75)
        #expect(isaac.damage == 3.5)
        #expect(isaac.speed == 1.0)
        #expect(isaac.damageMultiplier == 1.0)
    }

    /// Researched, not measured, and the flag has to keep saying so.
    @Test("characters with a researched range still declare it unverified")
    func researchedStaysFlagged() {
        for name in ["Azazel", "Lazarus", "Samson"] {
            guard let c = Characters.all.first(where: { $0.name == name }) else {
                Issue.record("no character named \(name)")
                continue
            }
            #expect(
                c.unverified.contains("range"),
                "\(name)'s range came from a wiki page, not from the game")
        }
    }
}

@Suite("The character roster")
struct RosterTests {
    private func c(_ name: String) -> Character? {
        Characters.all.first { $0.name == name }
    }

    /// Pins every value that differs from Isaac's baseline, read from each character's
    /// own wiki page as raw wikitext. Rendered summaries were transcribed wrongly twice;
    /// the wikitext names each parameter and tags its version, and reproduced all three
    /// of Cain's independently measured values exactly.
    @Test("every non-default stat is the researched value")
    func nonDefaults() throws {
        #expect(c("Magdalene")?.speed == 0.85)
        #expect(c("Judas")?.damageMultiplier == 1.35)
        #expect(c("???")?.damageMultiplier == 1.05)
        #expect(c("???")?.speed == 1.1)
        #expect(c("Eve")?.damageMultiplier == 0.75)
        #expect(c("Eve")?.speed == 1.23)
        #expect(c("Samson")?.tears == -0.1)
        #expect(c("Samson")?.shotSpeed == 1.31)
        #expect(c("Samson")?.speed == 1.1)
        #expect(c("Samson")?.range == 18.75)
        #expect(c("Azazel")?.damageMultiplier == 1.5)
        #expect(c("Azazel")?.fireDelayMultiplier == 0.267)
        #expect(c("Azazel")?.speed == 1.25)
        #expect(c("Lazarus")?.luck == -1)
        #expect(c("Lazarus Risen")?.speed == 1.25)
        #expect(c("Dark Judas")?.damageMultiplier == 2.0)
        #expect(c("Dark Judas")?.speed == 1.1)
        #expect(c("Keeper")?.damageMultiplier == 1.2)
        #expect(c("Keeper")?.tears == -2)
        #expect(c("Keeper")?.speed == 0.85)
        #expect(c("Keeper")?.luck == -2)
        #expect(c("The Forgotten")?.damageMultiplier == 1.5)
        #expect(c("The Forgotten Soul")?.speed == 1.3)
    }

    /// A parameter absent from an infobox means "same as Isaac", so these are answers,
    /// not gaps -- and must not be re-flagged by someone assuming a blank row is unknown.
    @Test("characters who genuinely carry Isaac's numbers say so")
    func isaacLikes() {
        for name in ["The Lost", "Lilith", "Apollyon"] {
            let ch = c(name)
            #expect(ch?.unverified.isEmpty == true, "\(name) should be settled, not flagged")
            #expect(ch?.damage == 3.5)
            #expect(ch?.speed == 1.0)
            #expect(ch?.range == 23.75)
            #expect(ch?.damageMultiplier == 1.0)
        }
    }

    /// Eden is randomised per run and the log never says which roll you got, so this is
    /// the one row that must stay fully unknown rather than claiming Isaac's numbers.
    @Test("Eden stays unknown on every stat")
    func edenIsRandom() {
        let eden = c("Eden")
        for stat in ["damage", "tears", "speed", "range", "shotSpeed", "luck"] {
            #expect(eden?.unverified.contains(stat) == true, "Eden's \(stat)")
        }
    }

    @Test("every PlayerType the log can report resolves")
    func everyIDResolves() {
        for id in 0...17 {
            let ch = Characters.resolve(id)
            #expect(ch.id == id, "PlayerType \(id) fell through to the fallback")
            #expect(!ch.name.isEmpty)
        }
    }
}
