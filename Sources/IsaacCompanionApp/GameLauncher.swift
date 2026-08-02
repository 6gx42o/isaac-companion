import AppKit
import Foundation

/// Starts the game, and answers whether it is actually running.
///
/// The log cannot answer the second question on its own. `log.txt` is only rewritten
/// when the game launches, and "Isaac has shut down" is written on a clean quit --
/// so after a crash, a force-quit, or simply on the next launch of this app, a stale
/// file from a previous session reads as a live game forever. Asking the OS for the
/// process is the only answer that cannot go stale.
@MainActor
enum GameLauncher {
    /// From the game's own Info.plist. Afterbirth+ keeps the Rebirth folder name but
    /// its own bundle id, so this identifies the release as well as the process.
    static let bundleID = "com.Nicalis.The-Binding-of-Isaac-Afterbirth-"

    /// Rebirth's Steam app id; the DLC does not get its own launch target.
    static let steamAppID = "250900"

    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            if app.bundleIdentifier == bundleID { return true }
            // A non-Steam or repackaged copy can carry a different id, so fall back to
            // the executable name rather than reporting "not running" for a game the
            // user is plainly playing.
            guard app.bundleIdentifier == nil else { return false }
            return app.localizedName?.localizedCaseInsensitiveContains("Binding of Isaac") == true
        }
    }

    enum LaunchError: LocalizedError {
        case noSteam

        var errorDescription: String? {
            "Steam is not installed, so the game cannot be launched the way that keeps "
                + "achievements working. Start it from Steam yourself."
        }
    }

    /// Launches through Steam rather than opening the `.app` directly.
    ///
    /// This matters for the one constraint this whole project is built around: Steam
    /// has to be the parent process for achievements to register. Double-clicking the
    /// bundle starts the game with no Steam session attached, and every trophy earned
    /// in that session is lost.
    static func launch() throws {
        let url = URL(string: "steam://rungameid/\(steamAppID)")!
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            throw LaunchError.noSteam
        }
        NSWorkspace.shared.open(url)
    }

    /// Brings the already-running game to the front instead of launching a second copy.
    static func focus() {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleID }?
            .activate(options: [])
    }
}
