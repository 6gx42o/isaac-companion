import Foundation
import IsaacCore

/// Works out which release of Isaac is actually installed.
///
/// Steam's `appmanifest_250900.acf` lists an `dlcappid` line per owned DLC, and each
/// release keeps its own Application Support folder. Both are checked: the manifest
/// says what is OWNED, the support folder says what has been RUN. A release needs the
/// manifest to count -- a stale support folder from an uninstalled DLC would otherwise
/// make the app read the wrong item set.
public struct VersionDetector: Sendable {
    public struct Result: Sendable {
        public var version: GameVersion
        public var owned: [GameVersion]
        public var hasLog: Bool
        public var reason: String
    }

    public static var steamManifest: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Application Support/Steam/steamapps/appmanifest_250900.acf")
    }

    public static func logFile(for version: GameVersion) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Application Support")
            .appending(path: version.supportFolder)
            .appending(path: "log.txt")
    }

    public static func supportFolderExists(_ version: GameVersion) -> Bool {
        FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: NSHomeDirectory())
                .appending(path: "Library/Application Support")
                .appending(path: version.supportFolder).path)
    }

    /// DLC app ids present in Steam's manifest for Isaac.
    public static func ownedDLCIDs() -> Set<String> {
        guard let text = try? String(contentsOf: steamManifest, encoding: .utf8) else { return [] }
        var ids = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) where line.contains("dlcappid") {
            let digits = line.drop { !$0.isNumber }.prefix { $0.isNumber }
            if !digits.isEmpty { ids.insert(String(digits)) }
        }
        return ids
    }

    /// The newest owned release wins: someone with Repentance is playing Repentance,
    /// even though the Afterbirth+ DLC is still listed as owned.
    public static func detect() -> Result {
        let dlc = ownedDLCIDs()
        let owned = GameVersion.allCases.filter { v in
            guard let id = v.dlcAppID else {
                // Rebirth is the base game; it counts if the manifest exists at all.
                return FileManager.default.fileExists(atPath: steamManifest.path)
            }
            return dlc.contains(id)
        }
        // allCases is declared oldest -> newest, so the last owned entry is the newest.
        let newest = owned.last ?? .abplus
        let hasLog = FileManager.default.fileExists(atPath: logFile(for: newest).path)
        let reason: String
        if owned.isEmpty {
            reason = "No Steam manifest found; assuming Afterbirth+."
        } else if !hasLog {
            reason = "\(newest.displayName) is owned, but it has never been run "
                + "(no log.txt yet) -- launch it once."
        } else {
            reason = "Detected \(newest.displayName) from Steam"
                + (owned.count > 1
                    ? " (also own \(owned.dropLast().map(\.displayName).joined(separator: ", ")))"
                    : "")
        }
        return Result(version: newest, owned: owned, hasLog: hasLog, reason: reason)
    }
}
