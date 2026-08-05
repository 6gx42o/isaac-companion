import Testing
import Foundation
@testable import IsaacCore

/// Restoring a saved-and-quit run. `AppModel.resumeItems` owns the policy (when to do
/// it at all); these cover the pieces it is built on -- that `restore` reinstates a
/// record exactly, and that an archived run round-trips without losing the fields the
/// stat model depends on.
@Suite("Resume a continued run")
struct ResumeTests {

    @Test("restore puts a record back untouched, apart from its id")
    func restoreKeepsEverything() {
        var reducer = RunReducer()
        var state = RunState()
        reducer.restore(
            PickupRecord(
                uid: 999, itemID: 14, name: "Speed Up", kind: .pill, consumed: true,
                stage: 4, blind: true, rerolled: true),
            to: &state)

        let r = try? #require(state.items.first)
        #expect(r?.itemID == 14)
        #expect(r?.kind == .pill)
        #expect(r?.consumed == true, "a swallowed pill is what the stat model counts")
        #expect(r?.stage == 4)
        #expect(r?.blind == true)
        #expect(r?.rerolled == true)
        #expect(r?.uid != 999, "uids are per session; the archived one means nothing here")
    }

    /// Unlike `manualAdd`, restore must not enforce slot capacity: the build was already
    /// valid when it was archived, and evicting from it would quietly delete items.
    @Test("restore does not evict, even past a slot limit")
    func restoreDoesNotEvict() {
        var reducer = RunReducer()
        var state = RunState()
        for (i, name) in ["Swallowed Penny", "Petrified Poop", "AAA Battery"].enumerated() {
            reducer.restore(
                PickupRecord(uid: 0, itemID: i + 1, name: name, kind: .trinket), to: &state)
        }
        #expect(state.items.count == 3, "all three come back, capacity notwithstanding")
    }

    @Test("Every restored id is distinct, so the UI can key on it")
    func uidsAreUnique() {
        var reducer = RunReducer()
        var state = RunState()
        for i in 1...5 {
            reducer.restore(PickupRecord(uid: 0, itemID: i, name: "item \(i)"), to: &state)
        }
        #expect(Set(state.items.map(\.uid)).count == 5)
    }

    /// The fields added for resume are optional so that archives written before they
    /// existed still decode. A required field would have made every stored run
    /// unreadable on upgrade.
    @Test("An archive written before these fields existed still decodes")
    func oldArchivesStillDecode() throws {
        let old = """
        {"id":"x","startedAt":0,"seed":"AAAA BBBB","characterName":"Cain",
         "finalStage":1,"finalStageType":0,"curses":[],
         "items":[{"id":1,"name":"The Sad Onion","manual":false}],
         "bosses":[],"outcome":"died","finalStats":[]}
        """
        let summary = try JSONDecoder().decode(RunSummary.self, from: Data(old.utf8))
        let item = try #require(summary.items.first)
        #expect(item.name == "The Sad Onion")
        #expect(item.kind == nil, "absent means unknown, not a wrong guess")
        #expect(item.consumed == nil)
        #expect(item.stage == nil)
    }

    @Test("A run written now round-trips with the new fields intact")
    func newArchiveRoundTrips() throws {
        let summary = RunSummary(
            id: "x", startedAt: Date(timeIntervalSince1970: 0), seed: "AAAA BBBB",
            characterID: 2, characterName: "Cain", finalStage: 3, finalStageType: 0,
            curses: ["Curse of Blind"],
            items: [
                .init(
                    id: 14, name: "Speed Up", manual: false, kind: "pill",
                    consumed: true, stage: 3, blind: true, rerolled: false)
            ],
            bosses: [], death: nil, outcome: .inProgress, finalStats: [])

        let data = try JSONEncoder().encode(summary)
        let back = try JSONDecoder().decode(RunSummary.self, from: data)
        let item = try #require(back.items.first)
        #expect(item.kind == "pill")
        #expect(item.consumed == true)
        #expect(item.stage == 3)
        #expect(item.blind == true)
        #expect(item.rerolled == false)
    }
}
