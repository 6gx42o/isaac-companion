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
