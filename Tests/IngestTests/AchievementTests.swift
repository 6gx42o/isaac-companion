import Testing
import Foundation
@testable import Ingest
@testable import IsaacCore

private let loaded: ItemBundle? = try? Pipeline.load().0

@Suite(.enabled(if: (loaded?.achievements.count ?? 0) > 0, "no achievements built"))
struct AchievementTests {
    let bundle = loaded!

    @Test("All 403 Afterbirth+ achievements are parsed")
    func count() {
        #expect(bundle.achievements.count == 403)
        #expect(Set(bundle.achievements.map(\.id)).count == 403, "ids must be unique")
        #expect(bundle.achievements.map(\.id).max() == 403)
    }

    @Test("The condition comes from the XML comment, not the text attribute")
    func conditionSource() {
        // `text` is the in-game announcement ("X has appeared in the basement"), which
        // is never the requirement. Only the developer comment states one.
        let magdalene = bundle.achievements.first { $0.id == 1 }
        #expect(magdalene?.condition == "have 7 or more max red hearts at one time")
        #expect(magdalene?.announcement?.contains("Magdalene") == true)
        #expect(magdalene?.isKnown == true)

        // No condition may be silently borrowed from the announcement.
        for a in bundle.achievements {
            #expect(
                a.condition?.contains("has appeared in the basement") != true,
                "achievement \(a.id) took the announcement as its condition")
        }
    }

    @Test("Roughly a third have no stated condition, and say so")
    func honestGaps() {
        let known = bundle.achievements.filter(\.isKnown).count
        #expect(known == 282, "expected 282 commented achievements, got \(known)")
        let unknown = bundle.achievements.filter { !$0.isKnown }
        #expect(unknown.count == 121)
        // The fallback must never invent a requirement.
        for a in unknown.prefix(40) {
            #expect(!a.displayCondition.isEmpty)
            #expect(a.displayCondition.contains("not recorded") || a.displayCondition.contains("achievement"))
        }
    }

    @Test("Gated items join to a real achievement")
    func joins() {
        let ids = Set(bundle.achievements.map(\.id))
        let gated = bundle.items.filter { $0.achievement != nil }
        #expect(gated.count == 262, "expected 262 gated entries, got \(gated.count)")
        for item in gated {
            #expect(ids.contains(item.achievement!), "\(item.name) points at a missing achievement")
        }
        // items.xml's 230 gated entries are 180 collectibles + 50 TRINKETS — trinkets
        // live in the same file. Consumables are gated separately in pocketitems.xml.
        #expect(gated.filter { $0.kind.isAutoTracked }.count == 180)
        #expect(gated.filter { $0.kind == .trinket }.count == 50)
        #expect(gated.filter { $0.kind == .card || $0.kind == .pill }.count == 32)
    }

    @Test("A known unlock resolves end to end")
    func endToEnd() {
        // Dr. Fetus is gated behind beating Mom's Heart 9 times.
        guard let fetus = bundle.items.first(where: { $0.id == 52 && $0.kind.isAutoTracked }),
              let gate = fetus.achievement,
              let ach = bundle.achievements.first(where: { $0.id == gate })
        else {
            Issue.record("Dr. Fetus has no achievement gate")
            return
        }
        #expect(ach.condition?.lowercased().contains("mom's heart") == true,
                "got: \(ach.condition ?? "nil")")
    }

    @Test("Ungated items stay ungated")
    func ungated() {
        // The Sad Onion is available from the very first run.
        let onion = bundle.items.first { $0.id == 1 && $0.kind.isAutoTracked }
        #expect(onion?.achievement == nil)
        let ungatedCount = bundle.items.filter { $0.achievement == nil }.count
        #expect(ungatedCount > 400, "most items are not gated")
    }
}
