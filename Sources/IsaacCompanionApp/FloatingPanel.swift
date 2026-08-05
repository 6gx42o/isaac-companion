import AppKit
import IsaacCore
import SwiftUI

/// The palette, mirrored from `Web/style.css` so the native panel and the web view
/// are the same two rooms. Swift owns which one is live (`AppModel.theme`), so they
/// cannot drift apart.
struct PanelTheme {
    var ground: Color
    var rule: Color
    var text: Color
    var dim: Color
    var faint: Color
    var mark: Color        // what is DEAD
    var hot: Color         // your LIVE damage number
    var warn: Color
    var good: Color
    var isDark: Bool

    static let devil = PanelTheme(
        ground: Color(red: 0.031, green: 0.016, blue: 0.020),   // #080405
        rule:   Color(red: 0.200, green: 0.102, blue: 0.122),   // #331a1f
        text:   Color(red: 0.910, green: 0.851, blue: 0.776),   // #e8d9c6
        dim:    Color(red: 0.604, green: 0.498, blue: 0.459),   // #9a7f75
        faint:  Color(red: 0.420, green: 0.329, blue: 0.314),   // #6b5450
        mark:   Color(red: 0.722, green: 0.122, blue: 0.133),   // #b81f22
        hot:    Color(red: 0.886, green: 0.329, blue: 0.169),   // #e2542b
        warn:   Color(red: 0.851, green: 0.643, blue: 0.255),   // #d9a441
        good:   Color(red: 0.494, green: 0.612, blue: 0.275),   // #7e9c46
        isDark: true)

    static let angel = PanelTheme(
        ground: Color(red: 0.957, green: 0.945, blue: 0.914),   // #f4f1e9
        rule:   Color(red: 0.867, green: 0.831, blue: 0.753),   // #ddd4c0
        text:   Color(red: 0.173, green: 0.149, blue: 0.125),   // #2c2620
        dim:    Color(red: 0.427, green: 0.392, blue: 0.333),   // #6d6455
        faint:  Color(red: 0.580, green: 0.541, blue: 0.463),   // #948a76
        mark:   Color(red: 0.627, green: 0.169, blue: 0.149),   // #a02b26
        hot:    Color(red: 0.722, green: 0.525, blue: 0.059),   // #b8860f
        warn:   Color(red: 0.663, green: 0.455, blue: 0.102),   // #a9741a
        good:   Color(red: 0.361, green: 0.478, blue: 0.204),   // #5c7a34
        isDark: false)

    static func named(_ name: String) -> PanelTheme { name == "angel" ? .angel : .devil }
}

/// The always-on-top readout.
///
/// A native panel rather than a second web view: it has to stay visible over a
/// fullscreen game, and `.fullScreenAuxiliary` + `.canJoinAllSpaces` on a
/// non-activating panel is the only combination that reliably does that without
/// stealing focus from Isaac.
final class StatsPanel: NSPanel, NSWindowDelegate {
    init(model: AppModel) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 264, height: 300),
            // No `.titled`, and therefore no `.closable` or `.utilityWindow`. A system
            // titlebar over a fullscreen game is the one thing on screen that is not
            // Isaac and not this readout: grey chrome, a stoplight, and ~28px of a
            // 340px panel spent on a title that says what the panel obviously is. The
            // panel supplies its own header, close control and rounded ground instead.
            // Not `.resizable`: the panel now sizes itself to the readout (see
            // sizingOptions below), so a drag handle would only ever produce dead
            // space or a clipped row. Position is still the user's, and autosaved.
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        // The only way to move a borderless window, now that there is no titlebar.
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        // The panel draws its own themed ground, so the system one must get out of
        // the way -- otherwise the opacity slider fades onto grey, not onto the game.
        isOpaque = false
        backgroundColor = .clear
        // Without a frame, the drop shadow is what separates the panel from whatever
        // Isaac is drawing behind it.
        hasShadow = true
        let host = NSHostingView(rootView: CompactStatsView(model: model))
        // The window follows the content instead of the content stretching to fill a
        // fixed window. At a fixed 340pt a run with no curses and the controls closed
        // left a third of the panel as empty themed ground sitting over the game.
        host.sizingOptions = [.preferredContentSize]
        contentView = host
        setFrameAutosaveName("IsaacCompanionPanel")
        delegate = self
    }

    /// Re-seat after the content resizes. A shrink-wrapping panel anchored to a bottom
    /// or right edge grows away from that edge otherwise: AppKit keeps the origin, so
    /// adding a row would walk a bottom-snapped panel down off the screen.
    /// setFrameOrigin does not resize, so this cannot feed back into itself.
    func windowDidResize(_ notification: Notification) {
        PanelController.shared.snapIfNeeded(settings())
        PanelController.shared.geometryChanged?()
    }

    /// Dragging the real panel has to move the rectangle in the app's preview, or the
    /// preview is a drawing of where the panel used to be.
    func windowDidMove(_ notification: Notification) {
        PanelController.shared.geometryChanged?()
    }

    /// The window is created before the model hands over settings, so it asks rather
    /// than caching a copy that could go stale.
    var settings: () -> PanelSettings = { PanelSettings.load() }

    // Keep the panel from taking focus away from the game.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController {
    static let shared = PanelController()
    private var panel: StatsPanel?

    func toggle(model: AppModel) {
        if let panel, panel.isVisible {
            hide()
        } else {
            show(model: model)
        }
    }

    func show(model: AppModel) {
        if panel == nil {
            let p = StatsPanel(model: model)
            p.settings = { [weak model] in model?.panelSettings ?? PanelSettings.load() }
            panel = p
        }
        applySettings(model.panelSettings)
        panel?.orderFrontRegardless()
    }

    /// The parts of the settings that are properties of the WINDOW rather than of the
    /// view inside it. Re-applied on every change and on every show.
    func applySettings(_ s: PanelSettings) {
        guard let panel else { return }
        // Click-through is what turns a floating window into an overlay: events go to
        // the game instead of being swallowed. It also disables the panel's own
        // controls, which is why it is off by default and called out in the UI.
        panel.ignoresMouseEvents = s.clickThrough
        panel.isMovableByWindowBackground = !s.locked && !s.clickThrough
        // .screenSaver clears a fullscreen game; .floating does not always.
        panel.level = s.aboveFullscreen ? .screenSaver : .floating
        panel.hasShadow = s.shadow
        snapIfNeeded(s)
    }

    /// Re-seats the panel in its chosen corner. Called after a settings change and
    /// after the content resizes, since a shrink-wrapping panel anchored to a bottom
    /// or right edge would otherwise drift as rows appear and disappear.
    func snapIfNeeded(_ s: PanelSettings) {
        guard let panel, let origin = s.origin(for: panel.frame.size) else { return }
        panel.setFrameOrigin(origin)
    }

    /// The panel's own close control. Ordering out rather than closing keeps the frame
    /// and the autosaved position, so reopening puts it back where it was.
    func hide() { panel?.orderOut(nil) }

    /// The panel as it is actually drawn, as PNG data.
    ///
    /// `cacheDisplay` renders the view's own layers, so this needs no Screen Recording
    /// permission and captures nothing but the panel -- which matters because the only
    /// time the panel is doing its real job, a fullscreen game is on top of it.
    func snapshot() -> Data? {
        guard let view = panel?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// For the snapshot hook: cacheDisplay renders a window whether or not it is on
    /// screen, so a picture of the panel is not on its own evidence that dropping the
    /// titlebar left it able to order front.
    var isOnScreen: Bool { panel?.isVisible ?? false }

    /// Set by the web bridge so the Overlay tab's preview follows the real window.
    var geometryChanged: (() -> Void)?

    /// Where the panel is, and the screen it is on, in one payload the preview can
    /// draw straight from. AppKit's origin is bottom-left; the preview works in
    /// top-left like the rest of the web UI, so the flip happens here rather than
    /// being re-derived (and re-got-wrong) on the page.
    func geometryJSON() -> String {
        let screens = NSScreen.screens.enumerated().map { i, sc -> [String: Any] in
            ["index": i, "name": sc.localizedName,
             "x": sc.frame.minX, "y": sc.frame.minY,
             "w": sc.frame.width, "h": sc.frame.height,
             "vx": sc.visibleFrame.minX, "vy": sc.visibleFrame.minY,
             "vw": sc.visibleFrame.width, "vh": sc.visibleFrame.height]
        }
        var payload: [String: Any] = ["screens": screens, "visible": panel?.isVisible ?? false]
        if let f = panel?.frame {
            // Top-left origin, measured from the top of the whole desktop.
            let deskTop = NSScreen.screens.map(\.frame.maxY).max() ?? f.maxY
            payload["panel"] = [
                "x": f.minX, "y": deskTop - f.maxY, "w": f.width, "h": f.height,
            ]
            payload["deskTop"] = deskTop
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    /// Moves the panel from the preview. Takes top-left desktop coordinates, the same
    /// ones geometryJSON hands out, so the page never has to think in AppKit's
    /// bottom-left space.
    func move(toTopLeft x: Double, _ y: Double) {
        guard let panel else { return }
        let deskTop = NSScreen.screens.map(\.frame.maxY).max() ?? panel.frame.maxY
        panel.setFrameOrigin(NSPoint(x: x, y: deskTop - y - panel.frame.height))
    }

    /// One line describing the window-level settings, for the snapshot hook. These
    /// are the ones a picture cannot show: whether the mouse passes through, which
    /// level it sits at, and where the corner snap actually put it.
    var diagnostics: String {
        guard let p = panel else { return "no panel" }
        return "visible=\(p.isVisible) clickThrough=\(p.ignoresMouseEvents) "
            + "level=\(p.level.rawValue) movable=\(p.isMovableByWindowBackground) "
            + "shadow=\(p.hasShadow) origin=\(Int(p.frame.minX)),\(Int(p.frame.minY)) "
            + "size=\(Int(p.frame.width))x\(Int(p.frame.height))"
    }
}


struct CompactStatsView: View {
    @Bindable var model: AppModel
    @State private var showingControls = false
    /// What the most recent pickup changed, and what caused it. Held until the next
    /// pickup rather than flashed: mid-fight you look up seconds after grabbing the
    /// item, and a chip that had already faded would have answered nobody.
    @State private var deltas: [String: Double] = [:]
    @State private var deltaSource = ""

    private var theme: PanelTheme {
        _ = model.themeRevision            // redraw when the web view toggles it
        return PanelTheme.named(model.theme)
    }

    /// Reading `panelRevision` here is what makes every settings change repaint: the
    /// struct is behind `private(set)`, so mutating it does not on its own invalidate
    /// a body that only read the struct.
    private var s: PanelSettings {
        _ = model.panelRevision
        return model.panelSettings
    }

    private static let allRows: [(String, KeyPath<ComputedStats, Stat>)] = [
        ("Damage", \.damage), ("Tears", \.tears), ("Range", \.range),
        ("Shot speed", \.shotSpeed), ("Speed", \.speed), ("Luck", \.luck),
    ]
    /// Compact mode has no room for "Shot speed" spelled out.
    private static let short = [
        "Damage": "DMG", "Tears": "TPS", "Range": "RNG",
        "Shot speed": "SHT", "Speed": "SPD", "Luck": "LCK",
    ]

    private var rows: [(String, KeyPath<ComputedStats, Stat>)] {
        let on = Set(s.visibleStats)
        return Self.allRows.filter { on.contains($0.0) }
    }

    /// Every size in the panel goes through here, so one slider rescales the whole
    /// readout instead of some parts of it.
    private func size(_ pt: Double) -> CGFloat { CGFloat(pt * s.scale) }

    private func number(_ v: Double) -> String {
        String(format: "%.\(max(0, min(3, s.decimals)))f", v)
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: size(8), weight: .regular, design: .monospaced))
            .tracking(1.6 * s.scale)
            .foregroundStyle(theme.faint)
    }

    /// A small pill: curses, flight, and the room when it holds a choice.
    private func tag(_ text: String, _ colour: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: size(7.5), weight: .medium, design: .monospaced))
            .tracking(1.1 * s.scale)
            .foregroundStyle(colour)
            .padding(.horizontal, size(4)).padding(.vertical, size(1.5))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(colour.opacity(0.5), lineWidth: 1))
    }

    /// Every shown stat is one where more is better, so up is always good and down is
    /// always bad -- no per-stat polarity table needed.
    private func deltaChip(_ name: String) -> some View {
        Group {
            if s.showDeltas, let d = deltas[name] {
                Text((d > 0 ? "+" : "−") + number(abs(d)))
                    .font(.system(size: size(9), weight: .semibold, design: .monospaced))
                    .foregroundStyle(d > 0 ? theme.good : theme.mark)
            }
        }
        .frame(width: s.showDeltas ? size(40) : 0, alignment: .trailing)
    }

    private func value(_ name: String, _ stat: Stat) -> some View {
        Text((stat.approx ? "~" : "") + number(stat.value))
            .font(.system(size: size(14), weight: .medium, design: .monospaced))
            // One stat carries the accent, and which one is the user's call: a Lost
            // run cares about speed, an Azazel run about damage.
            .foregroundStyle(
                stat.approx ? theme.warn : (name == s.accent ? theme.hot : theme.text))
    }

    /// The whole readout on one wrapped line. For players who want the numbers and
    /// nothing else taking up screen.
    private var compactStats: some View {
        FlowRow(spacing: size(9)) {
            ForEach(rows, id: \.0) { name, path in
                if let stats = model.stats {
                    HStack(spacing: size(3)) {
                        Text(Self.short[name] ?? name)
                            .font(.system(size: size(7.5), weight: .regular, design: .monospaced))
                            .foregroundStyle(theme.faint)
                        value(name, stats[keyPath: path])
                    }
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: size(7)) {
            if s.showCharacter || s.showFloor {
                HStack(alignment: .firstTextBaseline, spacing: size(6)) {
                    if s.showCharacter {
                        Text(model.character.name)
                            .font(.system(size: size(16), weight: .semibold, design: .serif))
                            .foregroundStyle(theme.text)
                    }
                    Spacer(minLength: 4)
                    if s.showFloor { label("Floor \(model.run.stage)") }
                    // Stands in for the titlebar's close button. Pointless while the
                    // panel ignores the mouse, so it goes away with click-through.
                    if !s.clickThrough {
                        Button { PanelController.shared.hide() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: size(8), weight: .bold))
                                .foregroundStyle(theme.faint)
                        }
                        .buttonStyle(.plain)
                        .help("Hide the panel (⇧⌘P)")
                    }
                }
            }

            if s.showSeed, let seed = model.run.seed {
                Text(seed)
                    .font(.system(size: size(9.5), design: .monospaced))
                    .foregroundStyle(theme.dim)
                    .textSelection(.enabled)
            }

            if s.showUnverified, !model.character.unverified.isEmpty {
                Text("Unverified: \(model.character.unverified.joined(separator: ", "))")
                    .font(.system(size: size(9.5)))
                    .foregroundStyle(theme.warn)
            }

            // The three things that change how you read everything below: a curse can
            // be actively lying to you (Blind hides pedestal art), flight changes which
            // rooms exist for you, and a room that offers a choice is why you would be
            // looking at the panel at all.
            let tags = runTags
            if s.showTags, !tags.isEmpty {
                FlowRow(spacing: size(4)) {
                    ForEach(tags, id: \.0) { text, colour in tag(text, colour) }
                }
            }

            if s.border { Rectangle().fill(theme.rule).frame(height: 1) }

            if let stats = model.stats {
                if s.compact {
                    compactStats
                } else {
                    ForEach(rows, id: \.0) { name, path in
                        let stat = stats[keyPath: path]
                        HStack(alignment: .firstTextBaseline, spacing: size(6)) {
                            label(name)
                            Spacer(minLength: 4)
                            value(name, stat)
                            deltaChip(name)
                        }
                        .help(stat.reason ?? "")
                    }
                }
                if s.showShots, stats.shots > 1 {
                    HStack {
                        label("Shots")
                        Spacer()
                        Text("\(stats.shots)")
                            .font(.system(size: size(14), weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.text)
                        if s.showDeltas && !s.compact { Spacer().frame(width: size(40)) }
                    }
                }
                // Which item produced the numbers above. Without it a delta is a
                // change with no cause, and the log is the only thing that knows.
                if s.showLast, !deltaSource.isEmpty {
                    HStack(spacing: size(4)) {
                        label("last")
                        Text(deltaSource)
                            .font(.system(size: size(10)))
                            .foregroundStyle(theme.dim)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                if s.showRecent, !recent.isEmpty {
                    VStack(alignment: .leading, spacing: size(1)) {
                        label("recent")
                        ForEach(recent, id: \.uid) { item in
                            Text(item.name)
                                .font(.system(size: size(10)))
                                .foregroundStyle(theme.dim)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                }
            } else {
                Text("Waiting for a run…")
                    .font(.system(size: size(11))).foregroundStyle(theme.dim)
            }

            if s.showFooter {
                if s.border { Rectangle().fill(theme.rule).frame(height: 1) }
                HStack(spacing: size(6)) {
                    label("\(model.run.items.count) items")
                    Spacer()
                    // Same three states as the main window: the panel must not claim
                    // "live" while it is only looking at a character's base stats.
                    if !model.gameProcessRunning {
                        label("game closed")
                    } else if model.run.seed == nil {
                        Circle().fill(theme.warn).frame(width: size(5), height: size(5))
                        label("scanning")
                    } else {
                        Circle().fill(theme.good).frame(width: size(5), height: size(5))
                        label("live")
                    }
                    if !s.clickThrough {
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) { showingControls.toggle() }
                        } label: {
                            Image(systemName: showingControls ? "chevron.up" : "slider.horizontal.3")
                                .font(.system(size: size(9)))
                                .foregroundStyle(theme.faint)
                        }
                        .buttonStyle(.plain)
                        .help("Theme and transparency — everything else lives in Settings")
                    }
                }
            }

            if showingControls && !s.clickThrough {
                VStack(alignment: .leading, spacing: size(5)) {
                    Picker("", selection: themeBinding) {
                        Text("Devil").tag("devil")
                        Text("Angel").tag("angel")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.mini)

                    HStack(spacing: size(6)) {
                        label("opacity")
                        Slider(value: opacityBinding, in: 0.15...1)
                            .controlSize(.mini)
                        Text("\(Int(model.panelOpacity * 100))%")
                            .font(.system(size: size(9), design: .monospaced))
                            .foregroundStyle(theme.faint)
                            .frame(width: size(30), alignment: .trailing)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(size(11))
        // Fixed width, intrinsic height. `maxHeight: .infinity` would ask for all
        // the room there is, which is exactly what shrink-wrapping must not be told.
        .frame(width: CGFloat(s.width), alignment: .topLeading)
        // Keeping the text opaque is only half of "the numbers never get harder to
        // read". The other half is contrast, and contrast came from the ground -- so
        // as the ground fades, the labels start competing with whatever Isaac happens
        // to be drawing behind them. This is the HUD answer: a contrasting halo that
        // costs nothing at full opacity and does all the work at low opacity, so the
        // readout survives being over a bright floor or a boss explosion.
        .shadow(
            color: (theme.isDark ? Color.black : Color.white)
                .opacity(min(0.9, (1 - ground) * 1.15)),
            radius: 2, x: 0, y: 0)
        .background(
            // Only the GROUND fades. The text stays fully opaque at every setting —
            // a slider that dimmed the numbers too would make the panel useless
            // exactly when you most want it out of the way.
            //
            // The ground is a rounded rect now, not a plain fill: without a titlebar
            // the window has no system frame, so its corners are whatever this draws.
            // A square fill under a rounded border showed the ground poking out past
            // the stroke at each corner.
            ZStack {
                RoundedRectangle(cornerRadius: CGFloat(s.cornerRadius))
                    .fill(theme.ground.opacity(ground))
                if s.border {
                    RoundedRectangle(cornerRadius: CGFloat(s.cornerRadius))
                        .strokeBorder(theme.rule.opacity(max(ground, 0.35)), lineWidth: 1)
                }
            }
            .ignoresSafeArea()
        )
        .animation(.easeInOut(duration: 0.28), value: model.themeRevision)
        .animation(.easeInOut(duration: 0.22), value: model.gameProcessRunning)
        // Deltas come from comparing the two stat sets either side of a pickup, which
        // means they cost no extra state in the model -- the panel is the only place
        // that cares what CHANGED rather than what is.
        .onChange(of: model.stats) { old, new in
            guard let old, let new else { deltas = [:]; deltaSource = ""; return }
            var next: [String: Double] = [:]
            for (name, path) in Self.allRows {
                let d = new[keyPath: path].value - old[keyPath: path].value
                // 0.005 is below what the two-decimal readout can show, so anything
                // under it would be a chip next to a number that had not moved.
                if abs(d) > 0.005 { next[name] = d }
            }
            // A recompute that changes nothing (a floor change, a re-render) must not
            // wipe the chips that are still answering "what did that last item do".
            guard !next.isEmpty else { return }
            deltas = next
            deltaSource = model.run.items.last?.name ?? ""
        }
        // A new seed is a new run: the previous run's last pickup is not news.
        .onChange(of: model.run.seed) { deltas = [:]; deltaSource = "" }
    }

    /// The ground's actual opacity right now. Dimming while no game is running keeps
    /// the panel from shouting at an empty desktop without hiding it outright.
    private var ground: Double {
        s.dimWhenIdle && !model.gameProcessRunning
            ? min(model.panelOpacity, s.idleOpacity) : model.panelOpacity
    }

    /// The last few pickups, newest first, excluding the one already named by "last".
    private var recent: [PickupRecord] {
        let n = max(1, min(8, s.recentCount))
        return Array(model.run.items.suffix(n + 1).dropLast().reversed())
    }

    /// Curses, flight and a room worth stopping in.
    private var runTags: [(String, Color)] {
        var out: [(String, Color)] = []
        // This floor's curses, not the run's. Curses are rolled per floor, so the
        // accumulated list kept claiming you were still blind two floors later.
        for curse in model.run.floorCurses { out.append((curse, theme.mark)) }
        if model.stats?.flight == true { out.append(("flight", theme.good)) }
        if model.run.room.offersChoice {
            let room = String(describing: model.run.room)
            let count = model.run.pedestals.count
            out.append((count > 0 ? "\(room) · \(count)" : room, theme.warn))
        }
        return out
    }

    private var themeBinding: Binding<String> {
        Binding(get: { model.theme }, set: { model.theme = $0 })
    }
    private var opacityBinding: Binding<Double> {
        Binding(get: { model.panelOpacity }, set: { model.panelOpacity = $0 })
    }
}

/// Wraps its children onto as many lines as they need.
///
/// `HStack` cannot wrap, and a panel whose width the user controls will always find a
/// width where four curse pills do not fit on one line. Written as a Layout rather
/// than a grid because the items are different widths and should sit shoulder to
/// shoulder, not in columns.
struct FlowRow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += lineHeight + spacing; lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
