import Foundation

/// Carries settings across the bundle-identifier change.
///
/// The app shipped as `local.isaaccompanion` and is now
/// `com.rushilluthra.isaaccompanion`, which notarisation will want later and which is a
/// real reverse-DNS name rather than a placeholder. To macOS that is a different app, so
/// without this the first launch after updating looks like a fresh install: theme back to
/// devil, panel placement and opacity gone, and every one of the settings-page switches
/// back to its default.
///
/// Two stores have to move, which is the part that is easy to get half-right:
///   - UserDefaults, keyed by bundle id (theme, panel geometry, storage mode, pins).
///   - WebKit's localStorage, ALSO keyed by bundle id, which is where the settings page
///     keeps its 21 switches. Migrating only the first leaves a half-restored app.
///
/// Runs once, guarded by a flag in the new domain. Failure is not fatal: losing settings
/// is annoying, refusing to launch is worse.
enum LegacyMigration {
    static let legacyBundleID = "local.isaaccompanion"
    private static let doneKey = "didMigrateFromLegacyBundleID"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }

        guard let current = Bundle.main.bundleIdentifier, current != legacyBundleID else { return }

        // persistentDomain, not dictionaryRepresentation: the latter folds in the global
        // domain and the argument domain, so it would copy unrelated system-wide keys
        // into the app's own prefs.
        if let legacy = defaults.persistentDomain(forName: legacyBundleID) {
            for (key, value) in legacy where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        // WebKit keeps a non-sandboxed app's local storage under ~/Library/WebKit/<id>.
        // Copy rather than move, so a failure part-way leaves the old install intact.
        let webKit = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/WebKit", directoryHint: .isDirectory)
        let old = webKit.appending(path: legacyBundleID, directoryHint: .isDirectory)
        let new = webKit.appending(path: current, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: old.path),
            !FileManager.default.fileExists(atPath: new.path) {
            try? FileManager.default.copyItem(at: old, to: new)
        }
    }
}
