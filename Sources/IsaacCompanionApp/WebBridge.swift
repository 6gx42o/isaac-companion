import AppKit
import Ingest
import IsaacCore
import SwiftUI
import WebKit

/// Hosts the web UI. The page is loaded from the app bundle and never touches the
/// network -- all data arrives by `evaluateJavaScript` push.
struct WebView: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "app")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = view

        if let index = Bundle.module.url(forResource: "Web/index", withExtension: "html") {
            view.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        // Reading themeRevision here is what makes SwiftUI call this again when the
        // panel's own picker changes the theme, so the flow works both ways.
        context.coordinator.pushTheme(model.theme, revision: model.themeRevision)
        context.coordinator.push(model.stateJSON())
        // Updater is @Observable and lives on the model, so a background check landing
        // invalidates this view -- which is how the settings row learns about a release
        // nobody asked it to look for. Deduped inside pushUpdate.
        context.coordinator.pushUpdate()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let model: AppModel
        weak var webView: WKWebView?
        private var loaded = false
        private var lastState = ""
        /// The badge sheet is ~1.9 MB and the enemy sheet ~1.1 MB. Base64 in a JS
        /// string that is ~4 MB of argument, so it is sent once per page load rather
        /// than on every tab switch.
        private var sentIconAtlases: Set<String> = []

        /// Settings plus the display list, so the page can draw the screen picker
        /// without a second round trip.
        private func pushPanelSettings() {
            webView?.evaluateJavaScript(
                "window.onPanelSettings(\(model.panelSettingsJSON()), \(model.screenListJSON()))")
            pushPanelGeometry()
        }

        /// Where the panel actually is. Pushed on every settings change and, via
        /// PanelController.geometryChanged, whenever the window itself moves --
        /// otherwise dragging the real panel would leave the preview drawing it in
        /// its old place.
        func pushPanelGeometry() {
            webView?.evaluateJavaScript(
                "window.onPanelGeometry(\(PanelController.shared.geometryJSON()))")
        }

        func pushPills() {
            webView?.evaluateJavaScript("window.onPills(\(model.pillsJSON()))")
        }

        func pushHistory() {
            webView?.evaluateJavaScript("window.onHistory(\(model.historyJSON()))")
        }

        func pushLogPath() {
            webView?.evaluateJavaScript("window.onLogPath(\(model.logPathJSON()))")
        }

        func pushStreamText() {
            webView?.evaluateJavaScript("window.onStreamText(\(model.streamTextJSON()))")
        }

        func pushResumeSavedRuns() {
            webView?.evaluateJavaScript("window.onResumeSavedRuns(\(model.resumeSavedRuns))")
        }

        private func chooseStreamDir() {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.message = "Pick a folder for the text files OBS will read"
            if panel.runModal() == .OK, let url = panel.url {
                model.streamTextDir = url
                model.refreshStreamText()
            }
        }

        /// A Swift string as a JavaScript string literal, via the JSON encoder rather
        /// than by hand. The hand-rolled version replaced double quotes with single
        /// quotes and nothing else, so a backslash or newline in an error message --
        /// which system error descriptions are entirely capable of containing -- would
        /// corrupt the injected script and the push would silently do nothing.
        static func jsString(_ value: String) -> String {
            (try? JSONEncoder().encode([value]))
                .flatMap { String(data: $0, encoding: .utf8) }
                .map { String($0.dropFirst().dropLast()) } ?? "\"\""
        }

        private var lastUpdateJSON = ""

        func pushUpdate() {
            var payload = model.updater.stateJSON()
            // The two preferences live on the model, not the updater, so they survive a
            // failed check; splice them into the same push rather than adding a second
            // callback the page would have to keep in sync.
            payload.removeLast()
            payload +=
                ",\"auto\":\(model.updateAuto),\"beta\":\(model.updateChannelBeta)"
                + ",\"dataStale\":\(model.dataIsStale)}"
            // updateNSView fires on every SwiftUI invalidation, which is often. Without
            // this the page would be re-rendering the same status line continuously.
            guard payload != lastUpdateJSON else { return }
            lastUpdateJSON = payload
            webView?.evaluateJavaScript("window.onUpdate(\(payload))")
        }

        private func pushIconAtlas(_ name: String) {
            guard sentIconAtlases.insert(name).inserted else { return }
            webView?.evaluateJavaScript(
                "window.onIconAtlas('\(name)', \(model.iconAtlasJSON(name)))")
        }

        init(model: AppModel) {
            self.model = model
            super.init()
            PanelController.shared.geometryChanged = { [weak self] in self?.pushPanelGeometry() }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            sentIconAtlases.removeAll()      // a reload needs them again
            // Swift owns the theme, so hand it to the page before anything paints.
            lastThemeRevision = model.themeRevision
            webView.evaluateJavaScript("window.applyTheme(\"\(model.theme)\")")
            webView.evaluateJavaScript("window.onAtlas(\(model.atlasJSON()))")
            // A few KB, and every pill row needs it, so it rides along with the atlas.
            webView.evaluateJavaScript("window.onStrip('pills', \(model.pillStripJSON()))")
            webView.evaluateJavaScript("window.onHudStats(\(model.hudStatsJSON()))")
            pushPills()
            webView.evaluateJavaScript("window.onCatalogue(\(model.catalogueJSON()))")
            pushPanelSettings()
            webView.evaluateJavaScript(
                "window.onStorageMode('\(model.storageMode.rawValue)')")
            push(model.stateJSON(), force: true)
            // The badge sheet decodes to ~78 MB of RGBA and the enemy sheet ~46 MB.
            // Doing that on the first tab click froze WebKit mid-paint, which looked
            // exactly like the tab failing to switch. Warm both just after the run
            // view has painted instead, so the cost lands where nothing is waiting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.pushIconAtlas("achievements")
                self?.pushIconAtlas("monsters")
            }
        }

        private var lastThemeRevision = -1

        /// Swift -> web. Only fires on an actual change; re-applying the theme would
        /// replay the switch animation on every state push.
        func pushTheme(_ theme: String, revision: Int) {
            guard loaded, revision != lastThemeRevision else { return }
            lastThemeRevision = revision
            webView?.evaluateJavaScript("window.applyTheme(\"\(theme)\")")
        }

        func push(_ json: String, force: Bool = false) {
            guard loaded, force || json != lastState else { return }
            lastState = json
            webView?.evaluateJavaScript("window.onState(\(json))")
        }

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "manualAdd":
                if let id = body["id"] as? Int {
                    // Kind matters: card 1, pill 1 and collectible 1 are three
                    // different things.
                    let kind = (body["kind"] as? String).flatMap(ItemKind.init(rawValue:))
                    model.manualAdd(itemID: id, kind: kind)
                }
            case "manualRemove":
                if let uid = body["uid"] as? Int { model.manualRemove(uid: uid) }
            case "pin":
                // nil clears the pin; the view re-requests to redraw.
                model.pinnedAchievement = body["id"] as? Int
                webView?.evaluateJavaScript(
                    "window.onAchievements(\(model.achievementsJSON()))")
            case "achievements":
                model.refreshProgress()
                pushIconAtlas("achievements")
                webView?.evaluateJavaScript(
                    "window.onAchievements(\(model.achievementsJSON()))")
            case "bestiary":
                pushIconAtlas("monsters")
                webView?.evaluateJavaScript("window.onBestiary(\(model.bestiaryJSON()))")
            case "setTheme":
                // Sent by the web toggle so the native panel follows along.
                if let name = body["theme"] as? String { model.theme = name }
            case "launchGame":
                model.launchGame()
                push(model.stateJSON(), force: true)
            case "setPanelField":
                if let key = body["key"] as? String, let value = body["value"] {
                    model.setPanelField(key, value)
                    pushPanelSettings()
                }
            case "resetPanel":
                model.resetPanelSettings()
                pushPanelSettings()
            case "setStorageMode":
                // Only the preference. Applying it means re-extracting ~570 MB, so
                // that is a separate, explicit action rather than something a
                // segmented control does the instant you touch it.
                if let mode = (body["mode"] as? String).flatMap(StorageMode.init(rawValue:)) {
                    model.storageMode = mode
                }
            case "logPath":
                pushLogPath()
            case "streamText":
                pushStreamText()
            case "setStreamText":
                if let on = body["value"] as? Bool {
                    model.streamTextEnabled = on
                    // Turning it on with no folder yet is a dead switch, so ask for one
                    // in the same gesture rather than leaving it silently doing nothing.
                    if on, model.streamTextDir == nil { chooseStreamDir() }
                    if on { model.refreshStreamText() }
                }
                pushStreamText()
            case "chooseStreamDir":
                chooseStreamDir()
                pushStreamText()
            case "resumeSavedRuns":
                pushResumeSavedRuns()
            case "setResumeSavedRuns":
                if let on = body["value"] as? Bool { model.resumeSavedRuns = on }
                pushResumeSavedRuns()
            case "chooseLogPath":
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.message = "Select the log.txt your copy of Isaac writes"
                panel.directoryURL = DataPaths.logFile.deletingLastPathComponent()
                if panel.runModal() == .OK, let url = panel.url {
                    model.useLogFile(url)
                    push(model.stateJSON(), force: true)
                }
                pushLogPath()
            case "clearLogPath":
                model.useLogFile(nil)
                push(model.stateJSON(), force: true)
                pushLogPath()
            case "rebuildData":
                Task { @MainActor in
                    await model.rebuild()
                    webView?.evaluateJavaScript(
                        "window.onRebuilt(\(model.buildWarnings.isEmpty))", completionHandler: nil)
                }
            case "history":
                pushHistory()
            case "deleteRun":
                if let id = body["id"] as? String {
                    model.deleteRun(id: id)
                    pushHistory()
                }
            case "deleteAllRuns":
                model.deleteAllRuns()
                pushHistory()
            case "exportHistory":
                // A file the user can keep, rather than a copy-to-clipboard of JSON.
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "isaac-run-history.json"
                panel.allowedContentTypes = [.json]
                if panel.runModal() == .OK, let url = panel.url {
                    try? Data(model.historyJSON().utf8).write(to: url)
                }
            case "updateState":
                pushUpdate()
            case "checkUpdate":
                Task { @MainActor in
                    await model.updater.check(includePrereleases: model.updateChannelBeta)
                    pushUpdate()
                }
            case "downloadUpdate":
                // Only ever downloads what the last check offered, so the URL is never
                // taken from the page.
                guard case .available(let release) = model.updater.state else { return }
                Task { @MainActor in
                    await model.updater.download(release)
                    pushUpdate()
                }
            case "installUpdate":
                model.updater.install(gameIsRunning: model.gameProcessRunning)
                pushUpdate()
            case "setUpdateField":
                if let key = body["key"] as? String {
                    if key == "auto", let on = body["value"] as? Bool { model.updateAuto = on }
                    if key == "beta", let on = body["value"] as? Bool {
                        model.updateChannelBeta = on
                    }
                }
                pushUpdate()
            case "showPanel":
                PanelController.shared.show(model: model)
                pushPanelGeometry()
            case "movePanel":
                // The preview drags in top-left desktop coordinates.
                if let x = body["x"] as? Double, let y = body["y"] as? Double {
                    PanelController.shared.move(toTopLeft: x, y)
                }
            case "panelGeometry":
                pushPanelGeometry()
            case "togglePanel":
                PanelController.shared.toggle(model: model)
            case "scanPocket", "scanPills":
                Task { @MainActor in
                    let result = await model.scanPocket()
                    let what: String
                    switch result.found {
                    case .card(let id, let confidence):
                        what = "{\"kind\":\"card\",\"id\":\(id),\"confidence\":\(confidence)}"
                    case .pill(let colour, let confidence):
                        what = "{\"kind\":\"pill\",\"colour\":\(colour),"
                            + "\"confidence\":\(confidence)}"
                    case nil:
                        what = "null"
                    }
                    let err = result.error.map(Self.jsString) ?? "null"
                    self.webView?.evaluateJavaScript(
                        "window.onPocketScan({\"found\":\(what),\"error\":\(err)})",
                        completionHandler: nil)
                    self.pushPills()
                }
            case "identifyPill":
                if let colour = body["colour"] as? Int, let effect = body["effectID"] as? Int {
                    model.identifyPill(colour: colour, effectID: effect)
                    pushPills()
                }
            case "forgetPill":
                if let colour = body["colour"] as? Int {
                    model.forgetPill(colour: colour)
                    pushPills()
                }
            case "measureBase":
                let n = { (k: String) -> Double? in
                    (body[k] as? NSNumber)?.doubleValue
                        ?? (body[k] as? String).flatMap(Double.init)
                }
                let err = model.recordMeasuredBase(
                    damage: n("damage"), tearDelay: n("delay"), range: n("range"),
                    shotSpeed: n("shotSpeed"), speed: n("speed"), luck: n("luck"))
                let msg = err.map(Self.jsString) ?? "null"
                webView?.evaluateJavaScript(
                    "window.onMeasured(\(msg))", completionHandler: nil)
                push(model.stateJSON(), force: true)
            case "forgetBase":
                model.forgetMeasuredBase()
                push(model.stateJSON(), force: true)
            case "pills":
                pushPills()
            case "scanRoom":
                Task { @MainActor in
                    let result = await model.scanRoom()
                    let payload: [String: Any] = [
                        "matches": result.matches.map { ["id": $0.id, "confidence": $0.confidence] },
                        "error": result.error as Any,
                    ]
                    guard let data = try? JSONSerialization.data(withJSONObject: payload),
                          let json = String(data: data, encoding: .utf8) else { return }
                    // In an async context evaluateJavaScript resolves to the async
                    // overload, which throws; the result is not needed either way.
                    webView?.evaluateJavaScript("window.onScan(\(json))", completionHandler: nil)
                }
            case "reroll":
                let id = body["id"] as? Int
                webView?.evaluateJavaScript(
                    "window.onReroll(\(model.rerollAdviceJSON(candidateID: id)))")
            case "verdicts":
                guard let id = body["id"] as? Int else { return }
                let kind = (body["kind"] as? String).flatMap(ItemKind.init(rawValue:))
                webView?.evaluateJavaScript(
                    "window.onVerdicts(\(id), \(model.verdictsJSON(forItemID: id, kind: kind)))")
            default:
                break
            }
        }
    }
}
