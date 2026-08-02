import AppKit
import Foundation

/// Everything about the floating panel that the user gets to decide.
///
/// One flat struct of value types with a default on every property. Flat matters:
/// `load()` merges the stored blob over a freshly defaulted one key by key, so a
/// setting added after someone's preferences were written still arrives at its
/// default instead of taking the whole object down with it. That failure mode is not
/// hypothetical here -- making one field non-optional in the vendored EID snapshot
/// once turned a stale file into a hard decode error and killed a whole code path.
/// Nested containers would defeat the merge, which is why the six stat toggles are
/// six Bools rather than a dictionary.
public struct PanelSettings: Codable, Equatable {

    // ---- overlay behaviour ----------------------------------------------------
    /// The mouse passes straight through to the game. The panel becomes pure
    /// readout -- no dragging, no buttons, no slider -- which is the point.
    public var clickThrough = false
    /// Pin it where it is. Unlike clickThrough this keeps the controls usable.
    public var locked = false
    /// "free" keeps whatever position you dragged it to; the rest re-snap on every
    /// change and on every screen-geometry change.
    public var corner = "free"          // free | topLeft | topRight | bottomLeft | bottomRight
    public var margin = 24.0
    /// Index into NSScreen.screens. Out of range falls back to the main screen.
    public var screenIndex = 0
    /// `.screenSaver` sits above a fullscreen game; `.floating` is a normal utility
    /// level and will lose to some fullscreen modes.
    public var aboveFullscreen = true
    public var autoShow = true          // appears when Isaac starts
    public var autoHide = true          // disappears when Isaac quits
    /// Fade back while no game is running, so it stops shouting at an empty desktop.
    public var dimWhenIdle = false
    public var idleOpacity = 0.35

    // ---- size and type --------------------------------------------------------
    public var width = 242.0
    /// Multiplies every font size. The panel sizes itself, so this changes the whole
    /// readout rather than clipping it.
    public var scale = 1.0
    /// One dense strip instead of a stat per line.
    public var compact = false
    public var decimals = 2

    // ---- what it shows --------------------------------------------------------
    public var showCharacter = true
    public var showFloor = true
    public var showSeed = false
    public var showTags = true
    public var showUnverified = true
    public var showDamage = true
    public var showTears = true
    public var showRange = true
    public var showShotSpeed = true
    public var showSpeed = true
    public var showLuck = true
    public var showShots = true
    public var showDeltas = true
    public var showLast = true
    public var showRecent = false
    public var recentCount = 3
    public var showFooter = true

    // ---- appearance -----------------------------------------------------------
    /// Which stat gets the hot accent. "none" gives every number the same weight.
    public var accent = "Damage"
    public var border = true
    public var cornerRadius = 6.0
    public var shadow = true

    // MARK: persistence

    private static let key = "panelSettings"

    /// Stored settings merged over the defaults, key by key.
    public static func load() -> PanelSettings {
        let fallback = PanelSettings()
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaultData = try? JSONEncoder().encode(fallback),
              var merged = (try? JSONSerialization.jsonObject(with: defaultData))
                as? [String: Any]
        else { return fallback }
        // Stored wins where it has an opinion; unknown keys from an older or newer
        // build are simply ignored by the decode below.
        merged.merge(stored) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let out = try? JSONDecoder().decode(PanelSettings.self, from: data)
        else { return fallback }
        return out
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    /// The stat rows that are switched on, in the order the panel draws them.
    public var visibleStats: [String] {
        var out: [String] = []
        if showDamage { out.append("Damage") }
        if showTears { out.append("Tears") }
        if showRange { out.append("Range") }
        if showShotSpeed { out.append("Shot speed") }
        if showSpeed { out.append("Speed") }
        if showLuck { out.append("Luck") }
        return out
    }

    /// Where the panel should sit, or nil when the user is placing it themselves.
    ///
    /// `visibleFrame` rather than `frame`: it excludes the menu bar and the Dock, so
    /// a top-left snap does not slide under the menu bar on the main display.
    public func origin(for size: NSSize) -> NSPoint? {
        guard corner != "free" else { return nil }
        let screens = NSScreen.screens
        let screen = screens.indices.contains(screenIndex) ? screens[screenIndex]
            : NSScreen.main ?? screens.first
        guard let area = screen?.visibleFrame else { return nil }
        let x = corner.hasSuffix("Left")
            ? area.minX + margin : area.maxX - size.width - margin
        // AppKit's y grows upward, so "top" is the high edge.
        let y = corner.hasPrefix("top")
            ? area.maxY - size.height - margin : area.minY + margin
        return NSPoint(x: x, y: y)
    }
}

extension PanelSettings {
    /// Memberwise init is internal by default on a public struct.
    public init(defaults: Void = ()) { self.init() }
}
