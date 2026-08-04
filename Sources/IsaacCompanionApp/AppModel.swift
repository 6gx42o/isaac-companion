import AppKit
import Foundation
import Ingest
import IsaacCore
import Observation

/// Everything the UI reads. One observable object, because the whole app state is
/// "current run + loaded item data + setup status" and splitting that up would buy
/// nothing.
@MainActor
@Observable
public final class AppModel {
    public enum Phase: Equatable {
        case needsSetup(String?)   // optional error from a failed attempt
        case building(String)
        case ready
    }

    public private(set) var phase: Phase = .needsSetup(nil)
    public private(set) var run = RunState()
    public private(set) var stats: ComputedStats?
    public private(set) var character: Character = Characters.resolve(nil)
    public private(set) var bundle: ItemBundle?
    public private(set) var pools: PoolBundle?
    public private(set) var synergies: SynergyBundle?
    public private(set) var engine: SynergyEngine?
    public private(set) var buildWarnings: [String] = []
    public private(set) var isRebuilding = false

    public let updater = Updater()

    /// Check for updates on launch and daily thereafter. Checking is automatic;
    /// installing never is.
    public var updateAuto: Bool {
        get { UserDefaults.standard.object(forKey: "updateAuto") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "updateAuto") }
    }

    public var updateChannelBeta: Bool {
        get { UserDefaults.standard.bool(forKey: "updateChannelBeta") }
        set { UserDefaults.standard.set(newValue, forKey: "updateChannelBeta") }
    }

    /// The other half of "up to date". The item data is built from the user's own game
    /// install, so a game patch silently invalidates it -- and the symptom is wrong
    /// numbers, which reads as a bug in the stat engine rather than as stale data.
    ///
    /// The game announces its version in the first lines of the log, so the version
    /// current when the data was last built is recorded and compared. Before the first
    /// log has been read there is nothing to compare and nothing is claimed.
    public private(set) var dataIsStale = false

    private var dataGameVersion: String? {
        get { UserDefaults.standard.string(forKey: "dataGameVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "dataGameVersion") }
    }

    /// Called whenever the log tells us which game build is running.
    func noteGameVersion(_ version: String) {
        guard let known = dataGameVersion else {
            // First time we have ever seen one: adopt it rather than cry stale.
            dataGameVersion = version
            return
        }
        dataIsStale = known != version
    }

    public var storageMode: StorageMode {
        get {
            StorageMode(
                rawValue: UserDefaults.standard.string(forKey: "storageMode") ?? "compact")
                ?? .compact
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "storageMode") }
    }

    /// "devil" or "angel". Owned by Swift so the web view and the native panel can
    /// never disagree; the web toggles it through the bridge.
    public var theme: String {
        get { UserDefaults.standard.string(forKey: "theme") ?? "devil" }
        set {
            // Bail on a no-op write. Without this the revision keeps climbing even
            // when nothing changed, which is enough on its own to keep a
            // page <-> Swift feedback loop alive forever.
            guard newValue != UserDefaults.standard.string(forKey: "theme") else { return }
            UserDefaults.standard.set(newValue, forKey: "theme")
            themeRevision &+= 1        // nudges the panel to redraw
        }
    }
    /// Everything else about the floating panel. Held in memory rather than read from
    /// UserDefaults per access, because the SwiftUI body touches a dozen fields on
    /// every redraw.
    public private(set) var panelSettings = PanelSettings.load()
    /// Bumped on every change so the panel's SwiftUI body re-runs.
    public private(set) var panelRevision = 0

    /// Persists a new settings object, re-applies the window-level parts
    /// (click-through, level, snap, shadow) and nudges the view.
    public func applyPanelSettings(_ new: PanelSettings) {
        guard new != panelSettings else { return }
        panelSettings = new
        new.save()
        panelRevision &+= 1
        PanelController.shared.applySettings(new)
    }

    /// Panel background opacity, 0.15...1. The readout itself stays fully opaque —
    /// only the ground behind it fades, so the numbers never get harder to read.
    public var panelOpacity: Double {
        get {
            let v = UserDefaults.standard.double(forKey: "panelOpacity")
            return v == 0 ? 0.92 : min(1, max(0.15, v))
        }
        set {
            let clamped = min(1, max(0.15, newValue))
            guard abs(clamped - panelOpacity) > 0.001 else { return }
            UserDefaults.standard.set(clamped, forKey: "panelOpacity")
            themeRevision &+= 1
        }
    }
    public private(set) var themeRevision: Int = 0

    public var gameRoot: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: "gameRoot") {
                return URL(fileURLWithPath: path)
            }
            return DataPaths.defaultGameRoot
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "gameRoot") }
    }

    private var reducer = RunReducer()
    private var parser = LogParser()
    private var tailer: LogTailer?
    private var itemsByID: [Int: Item] = [:]
    private struct Pair: Hashable { let kind: ItemKind; let id: Int
        init(_ k: ItemKind, _ i: Int) { kind = k; id = i } }
    private var manualByKind: [Pair: Item] = [:]
    private let scanner = RoomScanner()
    private var bestiary = Bestiary([])
    /// Which achievements this player has actually unlocked, from their save.
    public private(set) var unlocked: Set<Int> = []
    public private(set) var saveSource: String?
    /// The achievement the player is currently chasing, if any.
    public var pinnedAchievement: Int? {
        get {
            let v = UserDefaults.standard.integer(forKey: "pinnedAchievement")
            return v > 0 ? v : nil
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: "pinnedAchievement") }
    }

    /// Whether the game process is actually running, asked of the OS rather than
    /// inferred from the log. See GameLauncher for why the log cannot answer it.
    public private(set) var gameProcessRunning = false
    /// Set when a launch attempt fails, so the page can say why.
    public private(set) var launchError: String?
    private var processTimer: Timer?
    private var updateTimer: Timer?
    private var checkpointTimer: Timer?

    // MARK: - run history

    public let archive = RunArchive(
        directory: DataPaths.root.appending(path: "history", directoryHint: .isDirectory))
    public private(set) var history: [RunSummary] = []
    private var runStartedAt: Date?
    /// The tailer replays the whole log on attach, in one batch. Those runs are already
    /// over and we have no idea when they were played, so they are not archived.
    private var didInitialReplay = false

    /// Writes the run in memory to the archive, if there is one worth keeping.
    ///
    /// Called at every point the run is about to be replaced -- a new seed, a log reset,
    /// the app quitting -- because those are the only moments the outgoing run still
    /// exists. There is no "run over" line in the log to hang this on.
    private func archiveCurrentRun(inProgress: Bool = false) {
        guard didInitialReplay, let started = runStartedAt, run.seed != nil else { return }
        // "Has items" cannot distinguish a run from a reset: most characters START with
        // an item the log reports as a pickup (Cain's Lucky Foot filed three two-second
        // "runs" in one minute of reset-scumming for a seed). A run is worth keeping if
        // it went anywhere -- left the first floor, ended in a death, or simply lasted
        // longer than seed-hunting does.
        let lasted = Date().timeIntervalSince(started)
        guard run.stage > 1 || run.death != nil || lasted > 60 else { return }
        let summary = summarise(started: started, inProgress: inProgress)
        do {
            try archive.save(summary)
            history = archive.load()
        } catch {
            // Losing a history entry must never take the live readout down with it.
            print("could not archive run: \(error.localizedDescription)")
        }
    }

    private func summarise(started: Date, inProgress: Bool) -> RunSummary {
        // Recomputed rather than read off `stats`: within one batch of log lines the
        // cached value can still belong to the previous run.
        let owned = run.items.compactMap { resolve($0) }.filter { $0.kind.isAutoTracked }
        let who =
            bundle?.characters.first { $0.id == run.playerType }
            ?? Characters.resolve(run.playerType)
        let computed = StatEngine.compute(character: who, items: owned)
        let bosses = run.bossesDefeated.compactMap { bestiary.boss($0)?.name }
        return RunSummary(
            // Fractional seconds, because the id is the filename: two runs that begin
            // in the same second would otherwise be the same file, and the second would
            // silently replace the first. Unreachable while actually playing, and
            // trivially reachable from a replayed log.
            id: RunSummary.id(for: started),
            startedAt: started,
            endedAt: inProgress ? nil : Date(),
            seed: run.seed,
            characterID: run.playerType,
            characterName: who.name,
            finalStage: run.stage,
            finalStageType: run.stageType,
            curses: run.curses,
            items: run.items.map {
                RunSummary.Item(id: $0.itemID, name: $0.name, manual: $0.manual)
            },
            bosses: bosses,
            death: run.death.map { bestiary.describeDeath($0) },
            outcome: inProgress
                ? .inProgress
                : RunSummary.outcome(bosses: bosses, died: run.death != nil),
            finalStats: [
                ("damage", computed.damage), ("tears", computed.tears),
                ("tearDelay", computed.tearDelay), ("range", computed.range),
                ("shotSpeed", computed.shotSpeed), ("speed", computed.speed),
                ("luck", computed.luck),
            ].map {
                RunSummary.Stat(
                    key: $0.0, value: $0.1.value, base: $0.1.base, approx: $0.1.approx)
            })
    }

    /// Saves the live run every minute so a crash or a power cut costs a minute rather
    /// than the whole run.
    private func startRunCheckpoints() {
        checkpointTimer?.invalidate()
        checkpointTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.archiveCurrentRun(inProgress: true) }
        }
        history = archive.load()
    }

    /// Called when the app is quitting: the run in memory is otherwise simply lost.
    public func finishForQuit() {
        archiveCurrentRun()
    }

    public func deleteRun(id: String) {
        try? archive.delete(id: id)
        history = archive.load()
    }

    public func deleteAllRuns() {
        try? archive.deleteAll()
        history = archive.load()
    }

    public func historyJSON() -> String {
        let totals = RunArchive.totals(of: history)
        let iso = ISO8601DateFormatter()
        let runs: [[String: Any]] = history.map { r in
            var out: [String: Any] = [
                "id": r.id,
                "startedAt": iso.string(from: r.startedAt),
                "character": r.characterName,
                "stage": r.finalStage,
                "outcome": r.outcome.rawValue,
                "items": r.items.map { ["id": $0.id, "name": $0.name, "manual": $0.manual] },
                "curses": r.curses,
                "bosses": r.bosses,
                "stats": r.finalStats.map {
                    ["key": $0.key, "value": $0.value, "base": $0.base, "approx": $0.approx]
                },
            ]
            if let seed = r.seed { out["seed"] = seed }
            if let death = r.death { out["death"] = death }
            if let d = r.duration { out["duration"] = Int(d) }
            return out
        }
        let payload: [String: Any] = [
            "runs": runs,
            "totals": [
                "runs": totals.runs, "wins": totals.wins, "deaths": totals.deaths,
                "abandoned": totals.abandoned, "deepestStage": totals.deepestStage,
                "totalTime": Int(totals.totalTime),
                "favouriteItems": totals.favouriteItems.prefix(12).map {
                    ["name": $0.name, "count": $0.count]
                },
                "byCharacter": totals.byCharacter.map {
                    ["name": $0.name, "runs": $0.runs, "wins": $0.wins]
                },
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload))
            .map { String(decoding: $0, as: UTF8.self) } ?? #"{"runs":[],"totals":{}}"#
    }

    /// Before anything reads UserDefaults: the bundle id changed, and the old settings
    /// live under the old one.
    public init() { LegacyMigration.run() }

    // MARK: - the game itself

    /// Polls for the game process. Two seconds is far below human reaction time for
    /// "I just launched it" and costs nothing -- runningApplications is a cached list.
    private func startWatchingGame() {
        refreshGameProcess()
        processTimer?.invalidate()
        processTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refreshGameProcess() }
        }
    }

    private func refreshGameProcess() {
        let running = GameLauncher.isRunning
        guard running != gameProcessRunning else { return }
        gameProcessRunning = running
        // A launch that succeeded should clear a stale error from an earlier failure.
        if running { launchError = nil }
        // An overlay you have to remember to open is not an overlay. This is the only
        // place that knows the game came or went, so it is where auto-show and
        // auto-hide belong.
        if running, panelSettings.autoShow {
            PanelController.shared.show(model: self)
        } else if !running, panelSettings.autoHide {
            PanelController.shared.hide()
        }
    }

    /// Launches the game, or focuses it if it is already up.
    public func launchGame() {
        launchError = nil
        if gameProcessRunning {
            GameLauncher.focus()
            return
        }
        do {
            try GameLauncher.launch()
        } catch {
            launchError = error.localizedDescription
        }
        // Steam takes a while to get the game up; poll harder for a bit so the badge
        // does not sit on "not running" for two seconds after a successful launch.
        refreshGameProcess()
    }

    // MARK: - startup

    public func start() {
        startWatchingGame()
        if (try? loadBundle()) != nil {
            phase = .ready
            startTailing()
        } else {
            phase = .needsSetup(nil)
        }
        startUpdateChecks()
        // Quitting is the commonest way a run ends, and without this the run in memory
        // is simply lost -- which is the whole problem the archive exists to fix.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishForQuit() }
        }
    }

    /// One check shortly after launch, then daily. Deliberately not on a tight timer:
    /// there is nothing to gain from noticing a release within the hour, and a background
    /// task that wakes constantly is exactly what people mean when they say an app is
    /// heavy.
    private func startUpdateChecks() {
        guard updateAuto else { return }
        Task { @MainActor [weak self] in
            // Let the window come up first; a network stall must never delay first paint.
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.updateAuto else { return }
            await self.updater.check(includePrereleases: self.updateChannelBeta)
        }
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60 * 24, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self, self.updateAuto else { return }
                await self.updater.check(includePrereleases: self.updateChannelBeta)
            }
        }
    }

    private func loadBundle() throws {
        let (items, pools, synergies) = try Pipeline.load()
        apply(items: items, pools: pools, synergies: synergies)
    }

    private func apply(items: ItemBundle, pools: PoolBundle?, synergies: SynergyBundle?) {
        bundle = items
        self.pools = pools
        self.synergies = synergies
        engine = synergies.map(SynergyEngine.init(bundle:))
        bestiary = Bestiary(items.entities)
        refreshProgress()
        itemsByID = Dictionary(
            items.items.filter { $0.kind.isAutoTracked }.map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a })
        // Trinkets, cards and pills reuse collectible ids, so they need their own
        // (kind, id) index rather than sharing itemsByID.
        manualByKind = Dictionary(
            items.items.filter { !$0.kind.isAutoTracked }.map { (Pair($0.kind, $0.id), $0) },
            uniquingKeysWith: { a, _ in a })
        recompute()
    }

    /// Runs the data build. Same code path for first-run setup and for a storage-mode
    /// change, so there is only one thing to get right.
    public func rebuild() async {
        // Two overlapping rebuilds would race the same staging/backup/target paths.
        guard !isRebuilding else { return }
        isRebuilding = true
        defer { isRebuilding = false }
        buildWarnings = []
        let phaseUpdate: @MainActor @Sendable (String) -> Void = { [weak self] in
            self?.phase = .building($0)
        }
        // Item pools and sprites live only inside the packed archives, so the first
        // build runs the game's own extractor. Everything else works without it, and
        // a failure here degrades rather than blocks.
        let extractor = Extractor(gameRoot: gameRoot)
        if !Extractor.isHarvested, extractor.isAvailable {
            let keepRaw = storageMode == .cached
            do {
                try await Task.detached(priority: .userInitiated) { [phaseUpdate] in
                    try extractor.extractAndHarvest(keepRaw: keepRaw) { message in
                        Task { @MainActor in phaseUpdate(message) }
                    }
                }.value
            } catch {
                buildWarnings.append(
                    "Could not extract sprites and item pools: \(error.localizedDescription)")
            }
        }

        phase = .building("Reading game files…")
        let pipeline = Pipeline(gameRoot: gameRoot, mode: storageMode)
        // Explicit subdirectory form: this is the copy the app falls back to once the
        // EID mod is deleted (which is the point -- mods must be off for achievements),
        // so a lookup that silently returns nil would strand the user with no data.
        let vendored = Bundle.module.url(
            forResource: "eid.abplus", withExtension: "json", subdirectory: "VendoredData")
        do {
            let (items, pools, synergies, report) = try await Task.detached(priority: .userInitiated) {
                try pipeline.build(vendoredEIDJSON: vendored)
            }.value
            phase = .building("Writing data…")
            _ = try await Task.detached(priority: .userInitiated) {
                try pipeline.write(items: items, pools: pools, synergies: synergies)
            }.value
            buildWarnings = report.warnings
            apply(items: items, pools: pools, synergies: synergies)
            // The data now matches whatever the game currently is, so the staleness
            // warning is answered rather than merely dismissed.
            dataGameVersion = run.gameVersion
            dataIsStale = false
            phase = .ready
            startTailing()
        } catch {
            phase = .needsSetup(error.localizedDescription)
        }
    }

    /// Applying a storage-mode change rebuilds the data, then relaunches so the app
    /// comes up cleanly against the new layout.
    public func applyStorageMode(_ mode: StorageMode) async {
        storageMode = mode
        if mode == .compact {
            try? FileManager.default.removeItem(at: DataPaths.cacheDir)
        }
        await rebuild()
        guard case .ready = phase else { return }
        relaunch()
    }

    /// Tears the tailer down. Only for teardown paths that genuinely want a reset.
    private func stopTailing() {
        tailer?.stop()
        tailer = nil
    }

    public func relaunch() {
        let bundlePath = Bundle.main.bundleURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundlePath.path]
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    // MARK: - live run

    private func startTailing() {
        // Restarting replays the log from the top, which rebuilds RunState and drops
        // every hand-entered trinket, card and pill. A rebuild must not cost the user
        // their manual entries, so an already-running tailer is left alone.
        guard tailer == nil else { return }
        let tailer = LogTailer(url: DataPaths.logFile) { [weak self] lines in
            Task { @MainActor in self?.ingest(lines) }
        }
        self.tailer = tailer
        tailer.start()
    }

    private func ingest(_ lines: [String]) {
        for line in lines {
            if line == LogTailer.resetMarker {
                // The game relaunched, so whatever was live is over.
                archiveCurrentRun()
                run = RunState()
                reducer = RunReducer()
                runStartedAt = Date()
                // The game reshuffles which colour carries which effect, so carrying the
                // mapping across would be worse than having none.
                pills.reset()
                pillsAwaitingID.removeAll()
                unidentifiedPocketUses = 0
                clearPocket()
                continue
            }
            guard let event = parser.parse(line: line) else { continue }
            if case .gameVersion(let v) = event { noteGameVersion(v) }
            // A new seed replaces the run in memory, so this is the last moment the
            // outgoing one exists at all. Archive before the reducer drops it.
            // Only a DIFFERENT seed: the reducer treats a repeat as the same run, and
            // archiving on it would file the run twice and restart its clock.
            if case .runStarted(let seed) = event, seed != run.seed {
                archiveCurrentRun()
                runStartedAt = Date()
                pills.reset()          // new run, new shuffle
                pillsAwaitingID.removeAll()
                unidentifiedPocketUses = 0
                clearPocket()
            }
            // A pill hit the floor. The player has to walk over and pick it up, so look
            // at the pocket slot a moment later rather than now.
            if case .pillSpawned = event { schedulePocketRead(after: 2.5) }

            // The pocket slot was used. This is the ONLY moment the log admits a
            // consumable was swallowed, and by the time it fires the slot is empty --
            // so the answer is whatever was read from it beforehand.
            if case .pocketItemUsed = event { recordPocketUse() }

            reducer.apply(event, to: &run)
        }
        recompute()
        refreshProgress()
        // The first batch is the whole existing log, replayed. Runs in it finished
        // before the app was watching and their timings are unknown, so they are not
        // archived -- see archiveCurrentRun.
        if !didInitialReplay {
            didInitialReplay = true
            if run.seed != nil {
                // A run already in progress at attach. If this same run was being
                // archived before the app restarted -- an update or a crash mid-run --
                // the newest entry with this seed is IT, and adopting its start time
                // (and therefore its id, which derives from it) makes our saves
                // overwrite that entry instead of filing the run twice. This exact
                // duplicate shipped: an app swap mid-run left one checkpoint entry and
                // one final entry for a single Cain run.
                //
                // Recency-gated so a deliberate same-seed replay next week still gets
                // its own entry.
                if let previous = history.first(where: { $0.seed == run.seed }),
                   Date().timeIntervalSince(previous.startedAt) < 12 * 3600 {
                    runStartedAt = previous.startedAt
                } else {
                    // Its start is genuinely unknown, so the best honest answer is
                    // "when we started watching".
                    runStartedAt = Date()
                }
            }
            startRunCheckpoints()
        }
    }

    public func manualAdd(itemID: Int, kind: ItemKind? = nil) {
        let item = kind.flatMap { manualByKind[Pair($0, itemID)] } ?? itemsByID[itemID]
        guard let item else { return }
        reducer.manualAdd(
            itemID: itemID, name: item.name,
            kind: item.kind.isAutoTracked ? nil : item.kind,
            capacity: capacity(of: item.kind.section), to: &run)
        recompute()
    }

    /// How many of a section the run can hold, given the items picked up so far.
    ///
    /// Base is one slot. Mom's Purse and Belly Button widen trinkets; Starter Deck,
    /// Little Baggy, Deep Pockets and Polydactyly widen the pocket slot. Each states a
    /// capacity of 2 rather than "+1", so the largest stated value wins instead of
    /// summing -- whether AB+ stacks two of them to 3 is not settled by any source
    /// here, and claiming 3 would be a guess.
    public func capacity(of section: ItemSection) -> Int {
        let stated = run.items
            .compactMap { resolve($0)?.slots }
            .filter { $0.section == section }
            .map(\.capacity)
        return max(1, stated.max() ?? 1)
    }

    /// Re-reads the save. The game rewrites it on every unlock, so this runs whenever
    /// the log shows activity rather than only at launch.
    public func refreshProgress() {
        guard let p = SaveFile().readBest() else { return }
        unlocked = p.unlocked
        saveSource = p.source.lastPathComponent
    }

    /// Everything the achievements view needs.
    public func achievementsJSON() -> String {
        struct Row: Encodable {
            var id: Int
            var name: String
            var condition: String
            var known: Bool
            var unlocked: Bool
            var pinned: Bool
            var unlocks: [String]
            var gfx: String?
        }
        guard let bundle else { return "[]" }
        // What each achievement actually gives you — the reason to chase it.
        var grants: [Int: [String]] = [:]
        for item in bundle.items {
            guard let a = item.achievement else { continue }
            grants[a, default: []].append(item.name)
        }
        let pin = pinnedAchievement
        let rows = bundle.achievements.map { a in
            Row(
                id: a.id,
                name: a.steamName ?? Self.tidy(a.announcement) ?? "Achievement \(a.id)",
                condition: a.displayCondition,
                known: a.isKnown,
                unlocked: unlocked.contains(a.id),
                pinned: a.id == pin,
                unlocks: (grants[a.id] ?? []).sorted(),
                gfx: a.gfx?.lowercased())
        }
        // The save-file provenance rides along so the page can say where the
        // unlock state came from -- or that no save was found, which otherwise
        // renders as "everything locked" with no explanation.
        struct Payload: Encodable { var rows: [Row]; var source: String? }
        let data = (try? JSONEncoder().encode(Payload(rows: rows, source: saveSource)))
            ?? Data(#"{"rows":[]}"#.utf8)
        return String(data: data, encoding: .utf8) ?? #"{"rows":[]}"#
    }

    /// `You unlocked "Magdalene"` -> `Magdalene`; `"X" has appeared in the basement` -> `X`.
    private static func tidy(_ text: String?) -> String? {
        guard let text else { return nil }
        if let q = text.range(of: "\""), let q2 = text.range(of: "\"", options: .backwards),
           q.upperBound < q2.lowerBound {
            return String(text[q.upperBound..<q2.lowerBound])
        }
        return text
    }

    /// entities2.xml's monster block. Below 10 are the player's own entities (tears,
    /// bombs, familiars, knife, laser) plus pickups and machines; 1000 is
    /// ENTITY_EFFECT and 9001 is a mod-console artifact.
    ///
    /// Eleven effect rows carry `boss="1"` upstream -- Crack The Sky, Hush Laser,
    /// BlackHoleRay and friends -- with 0 HP and no bossID, because they are boss
    /// *attack visuals*. So `isBoss` alone cannot decide this. HP cannot either: Ultra
    /// Greed Door is a real 0-HP boss entity. The highest genuine AB+ boss is 413
    /// (The Matriarch), so this cutoff excludes nothing fightable.
    ///
    /// Every row is still sent to the page -- the filter is a view, not a deletion --
    /// because these names are the only readable form of the numbers a log line
    /// prints, and `Bestiary` keeps all 763 for `describeDeath`.
    static func isFightable(_ e: EntityInfo) -> Bool { (10..<1000).contains(e.type) }

    public func bestiaryJSON() -> String {
        struct Row: Encodable {
            var name: String; var type: Int; var variant: Int
            var hp: Double; var stageHP: Double
            var isBoss: Bool; var blocksClear: Bool
            var colors: [String]; var art: String?
            var fightable: Bool
        }
        guard let bundle else { return "[]" }
        // One row per named entity; variants of the same name collapse to the first.
        var seen = Set<String>()
        let rows = bundle.entities.compactMap { e -> Row? in
            guard seen.insert("\(e.name)|\(e.type)").inserted else { return nil }
            return Row(
                name: e.name, type: e.type, variant: e.variant, hp: e.baseHP,
                stageHP: e.stageHP, isBoss: e.isBoss, blocksClear: e.blocksClear,
                colors: e.colors, art: e.art, fightable: Self.isFightable(e))
        }.sorted { ($0.isBoss ? 0 : 1, $0.name) < ($1.isBoss ? 0 : 1, $1.name) }
        let data = (try? JSONEncoder().encode(rows)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Resolves a held record back to its catalogue entry, honouring the recorded kind.
    private func resolve(_ record: PickupRecord) -> Item? {
        if let kind = record.kind { return manualByKind[Pair(kind, record.itemID)] }
        return itemsByID[record.itemID]
    }

    public func manualRemove(uid: Int) {
        reducer.manualRemove(uid: uid, from: &run)
        recompute()
    }

    private func recompute() {
        let table =
            bundle?.characters.first { $0.id == run.playerType } ?? Characters.resolve(run.playerType)
        // A reading taken off the game's own HUD beats anything in the table.
        character = table.measured(with: measuredBases.measurement(for: run.playerType))
        let owned = run.items.compactMap { resolve($0) }.filter { $0.kind.isAutoTracked }
        stats = StatEngine.compute(character: character, items: owned)
    }

    // MARK: - view model for the web layer

    public func stateJSON() -> String {
        struct Payload: Encodable {
            struct StatOut: Encodable {
                var value: Double
                var base: Double
                var fromItems: Double
                var approx: Bool
                var reason: String?
            }
            struct Held: Encodable {
                var uid: Int
                var id: Int
                var name: String
                var gfx: String
                var text: String
                var confidence: String
                var manual: Bool
                var section: String
                var kind: String
                /// True when this item is in the build but doing nothing — overridden
                /// or redundant. Computed from the engine here rather than matched by
                /// name in JS, so the UI and the verdicts can never disagree.
                var dead: Bool
                var deadReason: String?
            }
            var ready: Bool
            var gameRunning: Bool
            /// True only once the log has actually reported a seed. Without this the
            /// page cannot tell a real reading from a character's untouched base
            /// stats, and would print the base numbers as if they were measured.
            var hasRun: Bool
            var launchError: String?
            var seed: String?
            var character: String
            var characterUnverified: [String]
            var characterNotes: String
            /// True when the HUD is showing base stats, so they can be recorded.
            var canMeasureBase: Bool
            /// True when this character's stats came from a reading, not the table.
            var baseMeasured: Bool
            var stage: Int
            var room: String
            var roomOffersChoice: Bool
            var pedestals: Int
            var curses: [String]
            var items: [Held]
            var stats: [String: StatOut]
            var shots: Int
            var flight: Bool
            var warnings: [String]
            var sections: [SectionOut]
            /// Plain-English cause of death, once the run has ended in one.
            var death: String?
            var bosses: [String]
            var activeWeapon: String?
            var conflicts: [Conflict]
            var transformations: [Progress]
        }
        struct SectionOut: Encodable {
            var id: String
            var title: String
            var note: String?
            var capacity: Int
            var grantedBy: [String]
        }
        struct Conflict: Encodable {
            var item: String
            var text: String
        }
        struct Progress: Encodable {
            var name: String
            var have: Int
            var need: Int
        }

        func out(_ s: Stat) -> Payload.StatOut {
            // Round base and total independently, then derive the delta from the
            // ROUNDED pair, so what the UI prints always adds up on screen.
            let value = (s.value * 100).rounded() / 100
            let base = (s.base * 100).rounded() / 100
            return .init(
                value: value, base: base, fromItems: (value - base),
                approx: s.approx, reason: s.reason)
        }

        let heldItems = run.items.compactMap { resolve($0) }.filter { $0.kind.isAutoTracked }

        // One pass over the engine for the whole build, so each row can say whether it
        // is live or dead without re-deriving it.
        var deadReasons: [Int: String] = [:]
        if let engine {
            for item in heldItems {
                for verdict in engine.verdicts(for: item, held: heldItems) where verdict.isNegative {
                    switch verdict {
                    case .overridden(let by, let win, let lose):
                        deadReasons[item.id] =
                            "Overridden by \(itemsByID[by]?.name ?? "#\(by)")"
                            + (lose > 0 ? " — \(win) over \(lose)" : "")
                    case .redundant(let effect, let with):
                        deadReasons[item.id] =
                            "\(effect) already from "
                            + with.compactMap { itemsByID[$0]?.name }.joined(separator: ", ")
                    default: break
                    }
                }
            }
        }

        let held = run.items.map { record -> Payload.Held in
            let item = resolve(record)
            let kind = item?.kind ?? record.kind ?? .passive
            let reason = kind.isAutoTracked ? deadReasons[record.itemID] : nil
            return .init(
                uid: record.uid, id: record.itemID,
                name: item?.name ?? record.name,
                gfx: item?.gfx ?? "",
                text: item?.text ?? "",
                confidence: item?.confidence.rawValue ?? "singleSource",
                manual: record.manual,
                section: kind.section.rawValue,
                kind: kind.rawValue,
                dead: reason != nil,
                deadReason: reason)
        }

        var statMap: [String: Payload.StatOut] = [:]
        if let s = stats {
            statMap = [
                "damage": out(s.damage), "tears": out(s.tears), "delay": out(s.tearDelay),
                "range": out(s.range), "shotSpeed": out(s.shotSpeed),
                "speed": out(s.speed), "luck": out(s.luck),
            ]
        }

        // Cross-item problems in the build the user already has: an item whose weapon
        // effect is dead because something else outranks it, or a duplicated tear
        // effect. This is the thing an in-game one-pedestal tooltip cannot tell you.
        var conflicts: [Conflict] = []
        var progress: [Progress] = []
        var activeWeapon: String?
        if let engine {
            activeWeapon = engine.activeWeapon(held: heldItems).flatMap { itemsByID[$0]?.name }
            var seen = Set<Int>()
            for item in heldItems where seen.insert(item.id).inserted {
                for verdict in engine.verdicts(for: item, held: heldItems) where verdict.isNegative {
                    switch verdict {
                    case .overridden(let by, _, _):
                        conflicts.append(
                            Conflict(
                                item: item.name,
                                text: "overridden by \(itemsByID[by]?.name ?? "#\(by)")"))
                    case .redundant(let effect, let with):
                        conflicts.append(
                            Conflict(
                                item: item.name,
                                text: "\(effect.lowercased()) already from "
                                    + with.compactMap { itemsByID[$0]?.name }.joined(separator: ", ")))
                    default: break
                    }
                }
            }
            progress = engine.transformationProgress(held: heldItems)
                .map { Progress(name: $0.0.name, have: $0.1, need: $0.0.threshold) }
        }

        let payload = Payload(
            ready: phase == .ready,
            gameRunning: gameProcessRunning,
            hasRun: run.seed != nil,
            launchError: launchError,
            seed: run.seed,
            character: character.name,
            characterUnverified: character.unverified,
            characterNotes: character.notes,
            canMeasureBase: canMeasureBase,
            baseMeasured: measuredBases.measurement(for: run.playerType) != nil,
            stage: run.stage,
            room: String(describing: run.room),
            roomOffersChoice: run.room.offersChoice,
            pedestals: run.pedestals.count,
            curses: run.curses,
            items: held,
            stats: statMap,
            shots: stats?.shots ?? 1,
            flight: stats?.flight ?? false,
            warnings: buildWarnings,
            sections: ItemSection.allCases.map { section in
                .init(
                    id: section.rawValue, title: section.title, note: section.note,
                    capacity: capacity(of: section),
                    grantedBy: heldItems
                        .filter { $0.slots?.section == section }
                        .map(\.name))
            },
            death: run.death.map { bestiary.describeDeath($0) },
            bosses: run.bossesDefeated.map { bestiary.boss($0)?.name ?? "boss #\($0)" },
            activeWeapon: activeWeapon,
            conflicts: conflicts,
            transformations: progress)
        let data = (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// The searchable catalogue, sent once after load.
    public func catalogueJSON() -> String {
        struct PoolMembership: Encodable {
            var pool: String
            var weight: Double
        }
        struct Row: Encodable {
            var id: Int
            var name: String
            var kind: String
            var gfx: String
            var text: String
            var confidence: String
            var special: Bool
            var pools: [PoolMembership]
            var cache: [String]
            var maxCharges: Int?
            var devilPrice: Int?
            var delta: [String: Double]
            var shots: Int?
            /// How the game says you unlock this, in its own words. nil when the item
            /// is available from the start; "unknown" when it is gated but the game
            /// files never state the requirement.
            var unlock: String?
            var unlockKnown: Bool
            /// Measured from the sprite; tints this item's own effect background.
            var colors: [String]
        }

        // Weight matters for the phase-3 re-roll advice, and it is interesting on its
        // own: it is the only correct AB+ pool data in existence.
        var weights: [Int: [PoolMembership]] = [:]
        for pool in pools?.pools ?? [] {
            for entry in pool.entries {
                weights[entry.id, default: []]
                    .append(PoolMembership(pool: pool.name, weight: entry.weight))
            }
        }

        let byAchievement = Dictionary(
            (bundle?.achievements ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rows = (bundle?.items ?? []).map { item -> Row in
            let gate = item.achievement.flatMap { byAchievement[$0] }
            var delta: [String: Double] = [:]
            let d = item.delta
            if let v = d.damage { delta["Damage"] = v }
            if let v = d.damageMultiplier { delta["Damage x"] = v }
            if let v = d.tears { delta["Tears"] = v }
            if let v = d.tearsMultiplier { delta["Tears x"] = v }
            if let v = d.tearDelay { delta["Tear delay"] = v }
            if let v = d.range { delta["Range"] = v }
            if let v = d.rangeMultiplier { delta["Range x"] = v }
            if let v = d.shotSpeed { delta["Shot speed"] = v }
            if let v = d.speed { delta["Speed"] = v }
            if let v = d.luck { delta["Luck"] = v }
            return Row(
                id: item.id, name: item.name, kind: item.kind.rawValue, gfx: item.gfx,
                text: item.text, confidence: item.confidence.rawValue, special: item.special,
                // Pool membership is keyed by COLLECTIBLE id. Trinkets, cards and pills reuse
                // those ids, so only auto-tracked items may read this table -- otherwise
                // "0 - The Fool" would inherit The Sad Onion's pools.
                pools: item.kind.isAutoTracked ? (weights[item.id] ?? []) : [],
                cache: item.cache, maxCharges: item.maxCharges,
                devilPrice: item.devilPrice, delta: delta, shots: d.shots,
                unlock: gate?.displayCondition, unlockKnown: gate?.isKnown ?? false,
                colors: item.colors)
        }
        let data = (try? JSONEncoder().encode(rows)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Reads the pedestals in the current room off the screen.
    ///
    /// Passive, read-only capture — nothing is injected into the game, so this has no
    /// bearing on achievements. Runs only when asked, never on a timer.
    public func scanRoom() async -> (matches: [(id: Int, confidence: Double)], error: String?) {
        guard let bundle else { return ([], "No item data loaded.") }
        // Prefer positions the log actually reported, but fall back to where pedestals
        // normally sit: the game only emits spawn lines the first time a room is
        // generated, so re-entering a room leaves us with nothing logged.
        var positions = run.pedestals.isEmpty ? run.room.likelyPedestals : run.pedestals
        // Asking for a scan is an explicit instruction, so never refuse on room type:
        // the room may be misread, or the pedestal may be somewhere unusual. Looking at
        // the centre and finding nothing is a better answer than declining to look.
        if positions.isEmpty { positions = [(320, 280)] }
        do {
            let found = try await scanner.scan(pedestals: positions, items: bundle.items)
            return (found.map { ($0.itemID, $0.confidence) }, nil)
        } catch {
            return ([], error.localizedDescription)
        }
    }

    // MARK: - measured character bases

    /// Base stats read off the game's HUD, one character at a time. See MeasuredBases --
    /// this exists because the researched table had three of Cain's six values wrong.
    public private(set) var measuredBases = MeasuredBases.load(
        from: DataPaths.root.appending(path: "measured-bases.json"))

    /// True when the HUD is currently showing this character's BASE stats: a run with no
    /// auto-tracked item picked up yet. Anything else and the numbers on screen include
    /// item effects, so they cannot be recorded as a baseline.
    ///
    /// Deliberately strict. Subtracting known item deltas would allow measuring at any
    /// point, but it would fold the item data's own errors into the one table that is
    /// supposed to be ground truth.
    public var canMeasureBase: Bool {
        run.playerType != nil
            && !run.items.contains { resolve($0)?.kind.isAutoTracked ?? false }
    }

    /// Records what the HUD showed as this character's baseline.
    public func recordMeasuredBase(
        damage: Double?, tearDelay: Double?, range: Double?,
        shotSpeed: Double?, speed: Double?, luck: Double?
    ) -> String? {
        guard let playerType = run.playerType else { return "No run in progress." }
        guard canMeasureBase else {
            return "Items have already been picked up, so the HUD is not showing base "
                + "stats any more. Measure at the start of a run."
        }
        let m = MeasuredBases.Measurement(
            damage: damage, tearDelay: tearDelay, range: range, shotSpeed: shotSpeed,
            speed: speed, luck: luck, takenAt: Date(), gameVersion: run.gameVersion)
        guard !m.isEmpty else { return "Nothing was filled in." }
        measuredBases.record(playerType: playerType, m)
        measuredBases.save(to: DataPaths.root.appending(path: "measured-bases.json"))
        recompute()
        return nil
    }

    public func forgetMeasuredBase() {
        guard let playerType = run.playerType else { return }
        measuredBases.forget(playerType: playerType)
        measuredBases.save(to: DataPaths.root.appending(path: "measured-bases.json"))
        recompute()
    }

    // MARK: - pills

    /// What each pill colour does, this run. Reset with the run, because the game
    /// reshuffles the mapping and a carried-over answer would be confidently wrong.
    public private(set) var pills = PillMemory()

    /// The colour sitting in the pocket slot, from the last read of the screen. This is
    /// what makes "which pill did you just swallow" answerable: the log announces the
    /// swallow AFTER the slot is empty, so the answer has to have been read before.
    public private(set) var heldPill: Int?

    /// The card in the pocket slot, from the same read. Unlike a pill colour this is a
    /// complete answer on sight -- a card's face IS its identity and the game never
    /// reshuffles it, so there is nothing to learn and nothing to ask.
    public private(set) var heldCard: Int?
    /// Every card the sprite could be. Longer than one only where the game ships no art
    /// that separates them (Blank Rune / Black Rune), and the UI says so rather than
    /// picking.
    public private(set) var heldCardAlternatives: [Int] = []
    public private(set) var heldCardConfidence: Double = 0

    /// Colours that were swallowed while their effect was still unknown, in order.
    /// Naming the colour later applies every one of them retroactively -- otherwise the
    /// first pill of each colour would be permanently lost from the run's numbers.
    public private(set) var pillsAwaitingID: [Int] = []

    /// Pocket uses that could not be attributed: a card whose art the game shares with
    /// another, or a use with nothing read from the slot. Counted rather than guessed,
    /// so the run view can admit the gap instead of quietly under-reporting.
    public private(set) var unidentifiedPocketUses = 0

    /// Debounce for the automatic read. A pill spawning is a cue to look at the pocket
    /// slot shortly afterwards, not to look immediately -- the player has to walk over
    /// and pick it up first.
    private var pillReadTask: Task<Void, Never>?

    /// Reads the pill in the pocket slot off the screen.
    ///
    /// Auto-detection has a hard ceiling that is worth being honest about: the log says a
    /// pill spawned and that the pocket slot was used, but never which pill, and the
    /// screen gives the COLOUR and nothing else. What the colour does is reshuffled every
    /// run. So this identifies the colour automatically, and the effect is learned once
    /// per colour and then applied for the rest of the run without asking again.
    func scanPocket() async -> (found: RoomScanner.Pocket?, error: String?) {
        let stripURL = DataPaths.dataDir(.abplus).appending(path: "pills.png")
        guard let data = try? Data(contentsOf: stripURL),
              let image = NSImage(data: data)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return (nil, "No pill sprites — rebuild the data.") }
        do {
            let found = try await scanner.readPocket(
                pillStrip: image, items: bundle?.items ?? [])
            // Exactly one of the two, so the other must be cleared -- otherwise a card
            // picked up after a pill would leave the app believing both are held.
            switch found {
            case .card(let ids, let confidence):
                heldCard = ids.first
                heldCardAlternatives = ids
                heldCardConfidence = confidence
                heldPill = nil
            case .pill(let colour, _):
                pills.note(colour: colour)
                clearPocket()
                heldPill = colour
            case nil:
                clearPocket()
            }
            return (found, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    /// Empties the held-pocket state, everywhere at once. Five call sites were each
    /// clearing their own subset of these four fields and had already drifted apart.
    private func clearPocket() {
        heldPill = nil
        heldCard = nil
        heldCardAlternatives = []
        heldCardConfidence = 0
    }

    /// Attributes a swallowed pill to whatever colour was last seen in the pocket slot.
    ///
    /// If the colour's effect is already known this is fully automatic: the pill enters
    /// the run and its stat change applies, with nothing asked of anyone. If the colour
    /// is known but the effect is not, the use is parked until the colour is named.
    ///
    /// The log cannot distinguish a pill from a card, so a card use with no pill held is
    /// correctly ignored rather than guessed at.
    private func recordPocketUse() {
        if let card = heldCard {
            // Only record it when the sprite named exactly ONE card. Blank Rune and
            // Black Rune share their art, and entering a coin flip into the run is
            // worse than entering nothing.
            //
            // Either way the slot is now empty, so the held state has to be cleared.
            // Leaving it set kept the page saying "in your pocket" about a card that
            // had already been used, with no re-read scheduled to correct it.
            if heldCardAlternatives.count <= 1 {
                manualAdd(itemID: card, kind: .card)
            } else {
                unidentifiedPocketUses += 1
            }
            clearPocket()
            schedulePocketRead(after: 1.5)
            return
        }
        guard let colour = heldPill else { return }
        pills.note(colour: colour)
        if let known = pills.effect(of: colour) {
            manualAdd(itemID: known.effectID, kind: .pill)
        } else {
            pillsAwaitingID.append(colour)
        }
        // The slot is empty now. A second pill needs a fresh look.
        heldPill = nil
        schedulePocketRead(after: 1.5)
    }

    /// Reads the pocket slot shortly from now, replacing any read already pending.
    ///
    /// Event-driven rather than polled: capture is a real screen grab, and the project's
    /// rule is that it happens on a trigger, never continuously.
    private func schedulePocketRead(after seconds: Double) {
        pillReadTask?.cancel()
        pillReadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.gameProcessRunning else { return }
            // Errors are silent on purpose. This is a background convenience; a missing
            // Screen Recording grant must not spew at someone who never asked for it.
            _ = await self.scanPocket()
        }
    }

    /// Records what a colour does, from the player. Applies to every pill of that colour
    /// for the rest of the run -- and backfills the ones already swallowed.
    public func identifyPill(colour: Int, effectID: Int) {
        pills.learn(colour: colour, effectID: effectID, source: .identified)
        // Every pill of this colour taken before it had a name. Without this the first
        // pill of each colour would never reach the run's numbers, which is exactly the
        // pill you most want counted -- it is the one that told you what the colour does.
        let owed = pillsAwaitingID.filter { $0 == colour }.count
        pillsAwaitingID.removeAll { $0 == colour }
        for _ in 0..<owed { manualAdd(itemID: effectID, kind: .pill) }
    }

    public func forgetPill(colour: Int) { pills.forget(colour: colour) }

    /// The colour memory plus the effect names, so the page can render it directly.
    public func pillsJSON() -> String {
        struct Row: Encodable {
            var colour: Int
            var effectID: Int?
            var name: String?
            var text: String?
            var source: String?
            /// How many of this colour were swallowed before it had a name. They land in
            /// the run the moment it gets one.
            var awaiting: Int = 0
            /// Currently in the pocket slot.
            var held: Bool = false
        }
        let byID = Dictionary(
            uniqueKeysWithValues: (bundle?.items ?? [])
                .filter { $0.kind == .pill }.map { ($0.id, $0) })
        let rows = pills.seen.map { colour -> Row in
            let swallowed = pillsAwaitingID.filter { $0 == colour }.count
            guard let known = pills.effect(of: colour) else {
                return Row(colour: colour, awaiting: swallowed, held: heldPill == colour)
            }
            let item = byID[known.effectID]
            return Row(
                colour: colour, effectID: known.effectID, name: item?.name,
                text: item?.text, source: known.source.rawValue,
                awaiting: swallowed, held: heldPill == colour)
        }
        struct CardRow: Encodable {
            var id: Int
            var name: String
            var text: String
            var confidence: Double
            var gfx: String
            /// Non-empty when the sprite cannot separate two cards. Both are named.
            var alternatives: [String]
        }
        struct Out: Encodable {
            var seen: [Row]
            var catalogue: [[String: String]]
            var held: Int?
            /// The card in the pocket slot, named outright -- no learning step.
            /// Pocket uses nothing could be attributed to. Shown rather than swallowed,
            /// so an under-reported run is visible as a gap instead of looking complete.
            var unattributed: Int
            /// The card in the pocket slot, named outright -- no learning step.
            var card: CardRow?
        }
        let byID2 = Dictionary(
            uniqueKeysWithValues: (bundle?.items ?? [])
                .filter { $0.kind == .card }.map { ($0.id, $0) })
        // Every pill effect, for the "what did that do?" picker.
        let catalogue = (bundle?.items ?? [])
            .filter { $0.kind == .pill }
            .sorted { $0.name < $1.name }
            .map { ["id": String($0.id), "name": $0.name] }
        let out = Out(
            seen: rows, catalogue: catalogue, held: heldPill,
            unattributed: unidentifiedPocketUses,
            card: heldCard.flatMap { id in byID2[id].map {
                CardRow(
                    id: id, name: $0.name, text: $0.text,
                    confidence: heldCardConfidence, gfx: $0.gfx,
                    alternatives: heldCardAlternatives.count > 1
                        ? heldCardAlternatives.compactMap { byID2[$0]?.name } : [])
            } })
        return (try? String(data: JSONEncoder().encode(out), encoding: .utf8)) ?? "null"
    }

    /// Verdicts for one candidate item against the current build — the "should I take
    /// this?" answer. Driven by the user picking an item, because the log announces
    /// that a pedestal exists but never which item is on it.
    public func verdictsJSON(forItemID id: Int, kind: ItemKind? = nil) -> String {
        struct Out: Encodable {
            var kind: String
            var text: String
            var negative: Bool
            var itemIDs: [Int]
        }
        // Only collectibles participate in the synergy lattice. A trinket, card or
        // pill shares ids with a collectible, so looking one up by id alone returns a
        // different entity entirely.
        guard let engine else { return "[]" }
        if let kind, !kind.isAutoTracked { return "[]" }
        guard let candidate = itemsByID[id] else { return "[]" }
        let held = run.items.compactMap { resolve($0) }.filter { $0.kind.isAutoTracked }
        func name(_ itemID: Int) -> String { itemsByID[itemID]?.name ?? "#\(itemID)" }

        let out = engine.verdicts(for: candidate, held: held).map { verdict -> Out in
            switch verdict {
            case .overridden(let by, let win, let lose):
                Out(
                    kind: "overridden",
                    text: "Overridden by \(name(by)) — its weapon effect will not fire "
                        + "(precedence \(win) vs \(lose)). You keep its stat changes.",
                    negative: true, itemIDs: [by])
            case .overrides(let losers):
                Out(
                    kind: "overrides",
                    text: "Overrides " + losers.map(name).joined(separator: ", "),
                    negative: false, itemIDs: losers)
            case .named(let with, let text):
                // EID uses {1} as a placeholder for the other item's name.
                Out(
                    kind: "synergy",
                    text: "With \(name(with)): "
                        + text.replacingOccurrences(of: "#", with: " · ")
                        .replacingOccurrences(of: "{1}", with: name(with)),
                    negative: false, itemIDs: [with])
            case .redundant(let effect, let with):
                Out(
                    kind: "redundant",
                    text: "\(effect) tears already come from "
                        + with.map(name).joined(separator: ", ")
                        + " — this adds only its stats.",
                    negative: true, itemIDs: with)
            case .multishot(let extra, let total):
                Out(
                    kind: "multishot",
                    text: "+\(extra) shots (these add, never multiply) — \(total) total",
                    negative: false, itemIDs: [])
            case .transformation(let transformName, let have, let need):
                Out(
                    kind: have >= need ? "transformation-complete" : "transformation",
                    text: have >= need
                        ? "Completes \(transformName) (\(have)/\(need))"
                        : "\(transformName) \(have)/\(need)",
                    negative: false, itemIDs: [])
            }
        }
        let data = (try? JSONEncoder().encode(out)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Re-roll advice for the current room's pool, against the current build.
    ///
    /// Only offered where a re-roll is a real choice (a room that puts items on
    /// pedestals). Uses the weapon-replacer set from the synergy lattice so items a
    /// DPS score cannot represent are excluded rather than mis-ranked.
    public func rerollAdviceJSON(candidateID: Int?) -> String {
        struct OutcomeOut: Encodable {
            var name: String
            var gain: Double        // percent
            var scorable: Bool
        }
        struct Out: Encodable {
            var pool: String
            var expectedGain: Double
            var coverage: Double
            var poolSize: Int
            var candidate: OutcomeOut?
            var rerollLooksBetter: Bool?
            var best: [OutcomeOut]
        }
        guard let bundle, let pools,
            let pool = pools.pools.first(where: { $0.name == run.room.poolName })
        else { return "null" }

        let advisor = PoolAdvisor(
            character: character,
            held: run.items.compactMap { resolve($0) }.filter { $0.kind.isAutoTracked },
            unscorable: Set((synergies?.layers ?? [:]).keys))
        let advice = advisor.advise(
            pool: pool, catalogue: itemsByID,
            candidate: candidateID.flatMap { itemsByID[$0] })

        func pct(_ ratio: Double) -> Double { ((ratio - 1) * 1000).rounded() / 10 }
        func map(_ o: PoolAdvisor.Outcome) -> OutcomeOut {
            OutcomeOut(name: o.name, gain: pct(o.ratio), scorable: o.quantified)
        }
        let out = Out(
            pool: advice.pool,
            expectedGain: pct(advice.expectedRatio),
            coverage: (advice.coverage * 100).rounded(),
            poolSize: advice.poolSize,
            candidate: advice.candidate.map(map),
            rerollLooksBetter: advice.rerollLooksBetter,
            best: advice.best.map(map))
        _ = bundle
        let data = (try? JSONEncoder().encode(out)) ?? Data("null".utf8)
        return String(data: data, encoding: .utf8) ?? "null"
    }

    /// Writes every payload the bridge pushes, as a set of `.js` files.
    ///
    /// This exists so `dev/preview.html` runs on the same bytes the app does. The
    /// alternative -- keeping hand-written sample data next to the real code -- drifted
    /// badly: the copy in the repo still had cards and pills with no sprite and enemies
    /// with no art, so a change to any of those looked broken in the preview and fine
    /// in the app, or the reverse.
    public func dumpWebPayloads(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let globals: [(String, String)] = [
            ("__ATLAS__", atlasJSON()),
            ("__PILLS__", pillStripJSON()),
            ("__CATALOGUE__", catalogueJSON()),
            ("__STATE__", stateJSON()),
            ("__ACH__", achievementsJSON()),
            ("__BEST__", bestiaryJSON()),
            ("__ICONS__", "{\"achievements\":\(iconAtlasJSON("achievements")),"
                + "\"monsters\":\(iconAtlasJSON("monsters"))}"),
        ]
        let body = globals.map { "window.\($0.0)=\($0.1);\n" }.joined()
        try Data(body.utf8).write(to: dir.appending(path: "payloads.js"))
    }

    /// The panel's settings, for the Settings tab to render controls from.
    public func panelSettingsJSON() -> String {
        guard let data = try? JSONEncoder().encode(panelSettings),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    /// Applies one field by name, the way the page sends it.
    ///
    /// Decoding a patch over the current settings rather than taking a whole object
    /// from the page: the page only ever knows about the controls it was built with,
    /// and a full replace would silently reset anything it had not heard of.
    public func setPanelField(_ key: String, _ value: Any) {
        guard let current = try? JSONEncoder().encode(panelSettings),
              var dict = (try? JSONSerialization.jsonObject(with: current)) as? [String: Any],
              dict[key] != nil
        else { return }
        dict[key] = value
        guard let patched = try? JSONSerialization.data(withJSONObject: dict),
              let next = try? JSONDecoder().decode(PanelSettings.self, from: patched)
        else { return }
        applyPanelSettings(next)
    }

    /// Back to factory. The page asks for this; the panel repaints from the defaults.
    public func resetPanelSettings() { applyPanelSettings(PanelSettings()) }

    /// The displays the panel can be pinned to, for the screen picker.
    public func screenListJSON() -> String {
        let names = NSScreen.screens.enumerated().map { i, screen -> [String: Any] in
            ["index": i, "name": screen.localizedName,
             "width": Int(screen.frame.width), "height": Int(screen.frame.height)]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: names),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// The pill-colour strip, as a data URI plus how many colours are on it.
    ///
    /// Every pill shares this one icon, so it is published as a sheet rather than
    /// packed per-item into the atlas. The frame count is measured off the image --
    /// it is a row of square frames -- so the page never has to restate a number the
    /// harvest chose.
    public func pillStripJSON() -> String {
        let url = DataPaths.dataDir(.abplus).appending(path: "pills.png")
        guard let png = try? Data(contentsOf: url),
              let img = NSImage(data: png)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil),
              img.height > 0, img.width % img.height == 0
        else { return "null" }
        return #"{"uri":"data:image/png;base64,\#(png.base64EncodedString())","#
            + #""frames":\#(img.width / img.height)}"#
    }

    /// The game's own stat-HUD icons, so a row in this app can carry the same glyph
    /// Isaac puts next to that number. A 64x64 sheet of 16x16 cells, four per row, in
    /// the order the game's hudstats.anm2 lists them.
    ///
    /// Served from the built data rather than the repository: it is the game's art, and
    /// it comes off the user's own install like every other sprite here.
    public func hudStatsJSON() -> String {
        let url = DataPaths.dataDir(.abplus).appending(path: "hudstats.png")
        guard let png = try? Data(contentsOf: url),
              let img = NSImage(data: png)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil),
              img.width > 0
        else { return "null" }
        return #"{"uri":"data:image/png;base64,\#(png.base64EncodedString())","#
            + #""cell":16,"cols":\#(img.width / 16)}"#
    }

    /// The achievement-badge and enemy atlases, same shape as the item one.
    public func iconAtlasJSON(_ name: String) -> String {
        let dir = DataPaths.dataDir(.abplus)
        guard let png = try? Data(contentsOf: dir.appending(path: "\(name).png")),
              let raw = try? Data(contentsOf: dir.appending(path: "\(name).index.json")),
              let index = try? JSONDecoder().decode(Atlas.Index.self, from: raw)
        else { return "null" }
        struct Payload: Encodable {
            var uri: String; var width: Int; var height: Int; var cell: Int
            var cellW: Int; var cellH: Int; var steps: Int
            var frames: [String: [Int]]
        }
        let p = Payload(
            uri: "data:image/png;base64," + png.base64EncodedString(),
            width: index.width, height: index.height, cell: index.cell,
            cellW: index.cellW ?? index.cell, cellH: index.cellH ?? index.cell,
            steps: max(1, index.steps ?? 1),
            frames: Dictionary(
                index.entries.map { ($0.key.lowercased(), [$0.x, $0.y]) },
                uniquingKeysWith: { a, _ in a }))
        let d = (try? JSONEncoder().encode(p)) ?? Data("null".utf8)
        return String(data: d, encoding: .utf8) ?? "null"
    }

    /// Sprite sheet plus its index.
    ///
    /// Sent as a data URI because index.html is loaded from the app bundle while the
    /// atlas is built into Application Support -- a file:// page cannot read across
    /// those without a custom scheme handler, and one 236 KB inline push at startup
    /// is cheaper than the machinery.
    public func atlasJSON() -> String {
        guard let index = Pipeline.loadAtlasIndex(),
            let png = try? Data(contentsOf: DataPaths.dataDir(.abplus).appending(path: "atlas.png"))
        else { return "null" }

        struct Payload: Encodable {
            var uri: String
            var width: Int
            var height: Int
            var cell: Int
            var frames: [String: [Int]]     // gfx name -> [x, y]
        }
        let payload = Payload(
            uri: "data:image/png;base64," + png.base64EncodedString(),
            width: index.width, height: index.height, cell: index.cell,
            frames: Dictionary(
                index.entries.map { ($0.key.lowercased(), [$0.x, $0.y]) },
                uniquingKeysWith: { a, _ in a }))
        let data = (try? JSONEncoder().encode(payload)) ?? Data("null".utf8)
        return String(data: data, encoding: .utf8) ?? "null"
    }
}

#if canImport(AppKit)
import AppKit
#endif
