import Testing
import Foundation
@testable import Ingest
@testable import IsaacCore

/// These run against the EID files actually installed on this machine. If the mod
/// is gone the suite skips rather than fails -- the shipping app uses the vendored
/// JSON, so a missing mod is not a build break.
private let eidDir: URL? = {
    let url = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: "Library/Application Support/Binding of Isaac Afterbirth+ Mods")
        .appending(path: "external item descriptions_836319872/descriptions/ab+")
    return FileManager.default.fileExists(atPath: url.appending(path: "item_data.lua").path)
        ? url : nil
}()

@Suite(.enabled(if: eidDir != nil, "EID mod not installed"))
struct EIDIngestTests {
    let result: EIDIngest.Result = try! EIDIngest().load(descriptionsDirectory: eidDir!)

    @Test("Parses the whole AB+ collectible set")
    func collectibleCount() {
        // AB+ tops out at id 552. Anything past that means Repentance data crept in.
        #expect(result.collectibles.count > 500)
        #expect(result.collectibles.keys.max()! <= 552)
        #expect(result.trinkets.count > 100)
    }

    @Test("Numeric deltas match the values the app's stat model was validated on")
    func knownDeltas() {
        #expect(result.collectibles[1]?.delta.tears == 0.7)          // Sad Onion
        #expect(result.collectibles[7]?.delta.damage == 1)           // Blood of the Martyr
        #expect(result.collectibles[4]?.delta.damage == 0.5)         // Cricket's Head
        #expect(result.collectibles[4]?.delta.damageMultiplier == 1.5)
        #expect(result.collectibles[149]?.delta.damage == 40)        // Ipecac
        #expect(result.collectibles[169]?.delta.damageMultiplier == 2)  // Polyphemus
        #expect(result.collectibles[330]?.delta.tearsMultiplier == 4)   // Soy Milk
        #expect(result.collectibles[330]?.delta.tearDelay == -2)
    }

    @Test("Names and descriptions come through with markup intact")
    func namesAndText() {
        #expect(result.collectibles[1]?.name == "The Sad Onion")
        #expect(result.collectibles[118]?.name == "Brimstone")
        #expect(result.collectibles[1]?.text.contains("+0.7 Tears") == true)
    }

    @Test("Multishot is lifted out of prose as EXTRA shots")
    func multishot() {
        #expect(result.collectibles[2]?.delta.shots == 2)    // Inner Eye: 3 tears -> +2
        #expect(result.collectibles[153]?.delta.shots == 3)  // Mutant Spider: 4 -> +3
        #expect(result.collectibles[245]?.delta.shots == 1)  // 20/20: 2 -> +1
        #expect(result.collectibles[1]?.delta.shots == nil)  // Sad Onion has none
    }

    @Test("Transformations map items to their sets")
    func transformations() {
        // Guppy is transformation 3 in AB+; Halo of Flies (10) belongs to it.
        #expect(result.transformations[10]?.contains("3") == true)
        #expect(result.transformations.count > 50)
    }

    @Test("Inner Eye is the AB+ x0.48 form, not Repentance's x0.51")
    func noRepentanceContamination() {
        #expect(result.collectibles[2]?.delta.tearsMultiplier == 0.48)
        #expect(result.collectibles[2]?.delta.tearDelay == 3)
    }

    @Test("Isaac with the real Sad Onion entry reproduces 3.75 tears/s end to end")
    func endToEndAgainstRealData() {
        let onion = result.collectibles[1]!
        let item = Item(id: 1, name: onion.name, kind: .passive, gfx: "", delta: onion.delta)
        let s = StatEngine.compute(character: Character(id: 0, name: "Isaac"), items: [item])
        #expect(abs(s.tears.value - 3.75) < 0.01)
    }
}
