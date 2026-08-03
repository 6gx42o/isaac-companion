import AppKit
import Ingest
import IsaacCore
import SwiftUI

@main
struct IsaacCompanionApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Isaac Companion") {
            RootView(model: model)
                .frame(minWidth: 720, minHeight: 480)
                .task {
                    model.start()
                    // Dev hook: write the bridge's payloads and quit, so dev/preview.html
                    // can be regenerated from the real code rather than hand-maintained.
                    if let dir = ProcessInfo.processInfo.environment["ISAAC_WEBDUMP"] {
                        do { try model.dumpWebPayloads(to: URL(filePath: dir)) }
                        catch { FileHandle.standardError.write(Data("\(error)\n".utf8)) }
                        exit(model.phase == .ready ? 0 : 1)
                    }
                    // Dev hook: render the floating panel and quit. Same reason as the
                    // scan hook below -- the panel only does its job underneath a
                    // fullscreen game, which is the one situation you cannot look at
                    // it in. Items are added by hand so the readout has real numbers
                    // and a real last-pickup delta rather than "waiting for a run".
                    if let path = ProcessInfo.processInfo.environment["ISAAC_PANELSHOT"] {
                        // Optional settings patch, applied through the same
                        // setPanelField the page uses -- so a snapshot exercises the
                        // real path from a control change to a repainted panel, not
                        // some parallel one that only the hook can reach.
                        if let opts = ProcessInfo.processInfo.environment["ISAAC_PANELOPTS"],
                           let data = opts.data(using: .utf8),
                           let dict = (try? JSONSerialization.jsonObject(with: data))
                            as? [String: Any] {
                            for (k, v) in dict { model.setPanelField(k, v) }
                        }
                        PanelController.shared.show(model: model)
                        // Transcendence in the middle so the flight tag is exercised,
                        // and Ipecac last so the deltas are the big obvious ones.
                        for id in [1, 20, 149] {       // Sad Onion, Transcendence, Ipecac
                            try? await Task.sleep(for: .milliseconds(350))
                            model.manualAdd(itemID: id, kind: nil)
                        }
                        // Long enough for SwiftUI to apply the change and redraw.
                        try? await Task.sleep(for: .milliseconds(600))
                        FileHandle.standardError.write(Data(
                            (PanelController.shared.diagnostics + "\n").utf8))
                        // The Overlay tab's preview draws entirely from this, so a
                        // wrong number here is a panel drawn in the wrong place.
                        FileHandle.standardError.write(Data(
                            ("geometry " + PanelController.shared.geometryJSON() + "\n").utf8))
                        if let png = PanelController.shared.snapshot() {
                            try? png.write(to: URL(filePath: path))
                        } else {
                            FileHandle.standardError.write(Data("no panel to snapshot\n".utf8))
                        }
                        exit(0)
                    }
                    // Dev hook: run the updater against the real Releases feed and print
                    // what happened, without installing anything. Both paths, because a
                    // refusal that has never been observed is not a guarantee.
                    if ProcessInfo.processInfo.environment["ISAAC_UPDATE_TEST"] == "1" {
                        let u = model.updater
                        func line(_ s: String) {
                            FileHandle.standardError.write(Data((s + "\n").utf8))
                        }
                        line("current version: \(u.currentVersionString)")
                        await u.check(includePrereleases: true)
                        guard case .available(let release) = u.state else {
                            line("RESULT check: \(u.stateJSON())")
                            exit(1)
                        }
                        line("RESULT check: offers \(release.tag)")

                        u.forceHashMismatch = true
                        await u.download(release)
                        if case .failed(let why) = u.state {
                            line("RESULT tampered: refused -- \(why)")
                        } else {
                            line("RESULT tampered: INSTALLED A BAD DOWNLOAD -- \(u.stateJSON())")
                            exit(1)
                        }

                        u.forceHashMismatch = false
                        await u.download(release)
                        guard case .ready(let r) = u.state, let staged = u.staged else {
                            line("RESULT genuine: \(u.stateJSON())")
                            exit(1)
                        }
                        line("RESULT genuine: verified and staged \(r.tag)")

                        // The signature half. Re-sign a copy of that same verified build
                        // with a different identity and check it is refused -- the hash
                        // test above cannot exercise this path, because a build that
                        // fails the hash never reaches the signature check.
                        let resigned = URL.temporaryDirectory.appending(
                            path: "IsaacCompanion-resigned.app", directoryHint: .isDirectory)
                        try? FileManager.default.removeItem(at: resigned)
                        try? FileManager.default.copyItem(at: staged, to: resigned)
                        let sign = Process()
                        sign.executableURL = URL(filePath: "/usr/bin/codesign")
                        sign.arguments = ["--force", "--sign", "-", resigned.path]
                        sign.standardError = FileHandle.nullDevice
                        try? sign.run()
                        sign.waitUntilExit()
                        do {
                            try u.verifySignature(of: resigned)
                            line("RESULT resigned: ACCEPTED A DIFFERENT SIGNER")
                            exit(1)
                        } catch {
                            line("RESULT resigned: refused -- \(error.localizedDescription)")
                        }
                        exit(0)
                    }
                    // Debug hook: lets a scan be triggered and inspected without
                    // reaching the window, which is awkward while Isaac owns a
                    // fullscreen Space.
                    if ProcessInfo.processInfo.environment["ISAAC_SCAN_ON_LAUNCH"] == "1" {
                        // Long enough for the tailer to replay the whole log; the room
                        // is only known once that finishes.
                        try? await Task.sleep(for: .seconds(6))
                        RoomScanner.log(
                            "state: room=\(model.run.room) pedestals=\(model.run.pedestals.count) "
                                + "items=\(model.run.items.count) seed=\(model.run.seed ?? "-")")
                        let result = await model.scanRoom()
                        if let error = result.error {
                            RoomScanner.log("RESULT error: \(error)")
                        } else if result.matches.isEmpty {
                            RoomScanner.log("RESULT no confident match")
                        } else {
                            for match in result.matches {
                                let name = model.bundle?.items.first {
                                    $0.id == match.id && $0.kind != .trinket
                                }?.name ?? "#\(match.id)"
                                RoomScanner.log(
                                    "RESULT match \(name) (#\(match.id)) "
                                        + String(format: "%.3f", match.confidence))
                            }
                        }
                        fflush(stdout)
                    }
                }
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Toggle Floating Panel") { PanelController.shared.toggle(model: model) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        Settings { SettingsView(model: model) }
    }
}

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        switch model.phase {
        case .needsSetup(let error):
            SetupView(model: model, error: error)
        case .building(let step):
            VStack(spacing: 12) {
                ProgressView()
                Text(step).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            WebView(model: model)
        }
    }
}

/// First-run setup. Doubles as the installer: find the game, choose how much disk
/// to use, build the data.
struct SetupView: View {
    @Bindable var model: AppModel
    var error: String?
    @State private var mode: StorageMode = .compact

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up Isaac Companion").font(.largeTitle.bold())
            Text(
                "Reads item data from your own Binding of Isaac install. Nothing is "
                    + "modified, and no mod is required — so your Steam achievements keep working."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            GroupBox("Game folder") {
                HStack {
                    Text(model.gameRoot.path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button("Choose…") { pickGameFolder() }
                }
                .padding(4)
            }

            GroupBox("Storage") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $mode) {
                        ForEach(StorageMode.allCases, id: \.self) { m in
                            Text(m.rawValue.capitalized).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(mode.explanation).font(.caption).foregroundStyle(.secondary)
                }
                .padding(4)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Build data") {
                    model.storageMode = mode
                    Task { await model.rebuild() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { mode = model.storageMode }
    }

    private func pickGameFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = model.gameRoot
        panel.message = "Select your 'The Binding of Isaac Rebirth' folder"
        if panel.runModal() == .OK, let url = panel.url { model.gameRoot = url }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var mode: StorageMode = .compact
    @State private var working = false

    var body: some View {
        Form {
            Section("Storage") {
                Picker("Mode", selection: $mode) {
                    ForEach(StorageMode.allCases, id: \.self) { m in
                        Text(m.rawValue.capitalized).tag(m)
                    }
                }
                Text(mode.explanation).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(working ? "Rebuilding…" : "Apply and restart") {
                        working = true
                        Task {
                            await model.applyStorageMode(mode)
                            working = false
                        }
                    }
                    .disabled(working || mode == model.storageMode)
                }
                Text("Changing this rebuilds the item data and restarts the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Data") {
                LabeledContent("Items", value: "\(model.bundle?.items.count ?? 0)")
                LabeledContent("Item pools", value: "\(model.pools?.pools.count ?? 0)")
                LabeledContent("Game version", value: model.bundle?.binaryVersion ?? "—")
                LabeledContent(
                    "Sprites & pools",
                    value: Extractor.isHarvested ? "extracted" : "not extracted yet")
                Button("Rebuild now") { Task { await model.rebuild() } }
                    .disabled(model.isRebuilding)
                if !Extractor.isHarvested {
                    Text(
                        "Sprites and item pools come from the game's packed archives and "
                            + "need a one-off extraction (about a minute). Rebuilding runs it."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.buildWarnings.isEmpty {
                Section("Warnings") {
                    ForEach(model.buildWarnings, id: \.self) { warning in
                        Text(warning).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear { mode = model.storageMode }
    }
}
