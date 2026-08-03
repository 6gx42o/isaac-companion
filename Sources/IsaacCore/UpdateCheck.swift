import Foundation

/// Deciding whether an update applies, with no networking in sight.
///
/// Everything here is a pure function over bytes someone else fetched. That is the whole
/// point: an updater is the one feature that downloads and runs code, so the part that
/// decides *what* to run should be testable against fixtures rather than against GitHub.
/// `Updater` in the app target does the talking; this decides.

// MARK: - versions

/// Enough of semver for a version string we generate ourselves.
///
/// Deliberately not a full semver implementation: this compares releases of one app whose
/// VERSION file we control. It tolerates a leading `v` (git tags carry one, the plist does
/// not) and ignores build metadata, and it treats a pre-release suffix as *older* than the
/// same version without one, which is the only pre-release rule that matters here.
public struct SemVer: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// `beta.1` in `1.2.0-beta.1`; empty for a normal release.
    public let prerelease: String

    public init(major: Int, minor: Int, patch: Int, prerelease: String = "") {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // Build metadata never affects precedence, so drop it before anything else.
        if let plus = s.firstIndex(of: "+") { s = String(s[s.startIndex..<plus]) }
        var pre = ""
        if let dash = s.firstIndex(of: "-") {
            pre = String(s[s.index(after: dash)...])
            s = String(s[s.startIndex..<dash])
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var nums = [0, 0, 0]
        for (i, p) in parts.enumerated() {
            guard let n = Int(p), n >= 0 else { return nil }
            nums[i] = n
        }
        self.init(major: nums[0], minor: nums[1], patch: nums[2], prerelease: pre)
    }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : "\(core)-\(prerelease)"
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        // 1.0.0-beta precedes 1.0.0. Two pre-releases fall back to string order, which is
        // right for `beta.1` < `beta.2` and close enough for anything we would ship.
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false      // release is newer than its own pre-release
        case (false, true): return true
        case (false, false): return a.prerelease < b.prerelease
        }
    }
}

// MARK: - releases

public struct ReleaseAsset: Sendable, Equatable {
    public let name: String
    public let url: URL
    public let size: Int

    public init(name: String, url: URL, size: Int) {
        self.name = name
        self.url = url
        self.size = size
    }
}

public struct Release: Sendable, Equatable {
    public let version: SemVer
    public let tag: String
    public let notes: String
    public let assets: [ReleaseAsset]
    public let isPrerelease: Bool

    public init(
        version: SemVer, tag: String, notes: String, assets: [ReleaseAsset],
        isPrerelease: Bool
    ) {
        self.version = version
        self.tag = tag
        self.notes = notes
        self.assets = assets
        self.isPrerelease = isPrerelease
    }

    /// The asset whose name ends in `suffix`, e.g. `.dmg` or `-windows-x64.exe`.
    public func asset(matching suffix: String) -> ReleaseAsset? {
        assets.first { $0.name.hasSuffix(suffix) }
    }

    /// The macOS app archive.
    ///
    /// Not `asset(matching: ".zip")`: the release also carries `-windows-x64.zip`, and
    /// GitHub returns assets in alphabetical order, so the plain suffix match picked the
    /// Windows one every time.
    public var macAppZip: ReleaseAsset? {
        assets.first { $0.name.hasSuffix(".zip") && !$0.name.contains("windows") }
    }

    /// The Windows executable, for the updater built into the .exe.
    public var windowsExe: ReleaseAsset? {
        assets.first { $0.name.hasSuffix("-windows-x64.exe") }
    }

    /// The checksum manifest `package.sh` publishes next to the binaries. Without it the
    /// updater has nothing to verify against and must refuse to install.
    public var checksums: ReleaseAsset? { assets.first { $0.name == "SHA256SUMS" } }
}

public enum UpdateCheck {
    /// Decodes GitHub's `/releases` array. Entries that are drafts, or whose tag is not a
    /// version we understand, are skipped rather than failing the whole check -- one
    /// hand-made tag should not stop updates forever.
    public static func releases(fromJSON data: Data) throws -> [Release] {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw UpdateError.malformedFeed
        }
        return raw.compactMap { item in
            guard (item["draft"] as? Bool) != true,
                let tag = item["tag_name"] as? String,
                let version = SemVer(tag)
            else { return nil }
            let assets: [ReleaseAsset] = (item["assets"] as? [[String: Any]] ?? [])
                .compactMap { a in
                    guard let name = a["name"] as? String,
                        let urlString = a["browser_download_url"] as? String,
                        let url = URL(string: urlString)
                    else { return nil }
                    return ReleaseAsset(name: name, url: url, size: a["size"] as? Int ?? 0)
                }
            return Release(
                version: version, tag: tag,
                notes: (item["body"] as? String) ?? "",
                assets: assets,
                isPrerelease: (item["prerelease"] as? Bool) ?? version.isPrerelease)
        }
    }

    /// The newest release worth offering, or nil when the running build is current.
    ///
    /// Strictly greater than the running version: re-offering the version already
    /// installed is how an updater ends up in a loop.
    public static func newest(
        in releases: [Release], current: SemVer, includePrereleases: Bool = false
    ) -> Release? {
        releases
            .filter { includePrereleases || !$0.isPrerelease }
            .filter { $0.version > current }
            .max { $0.version < $1.version }
    }

    /// Looks a filename up in a `shasum -a 256` manifest.
    ///
    /// Tolerates the several shapes those files come in: two spaces or one, a `*` binary
    /// marker, and a leading `./` on the path.
    public static func expectedHash(forFile name: String, inManifest manifest: String) -> String? {
        for line in manifest.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            var file = String(parts[parts.count - 1])
            if file.hasPrefix("*") { file.removeFirst() }
            if file.hasPrefix("./") { file.removeFirst(2) }
            if file == name {
                return String(parts[0]).lowercased()
            }
        }
        return nil
    }
}

public enum UpdateError: LocalizedError, Equatable {
    case malformedFeed
    case noChecksums
    case noMacBuild(String)
    case unknownAsset(String)
    case hashMismatch(expected: String, got: String)
    case signatureRejected(String)

    public var errorDescription: String? {
        switch self {
        case .malformedFeed:
            return "The update feed could not be read."
        case .noChecksums:
            return "That release has no SHA256SUMS file, so the download cannot be verified."
        case .noMacBuild(let tag):
            return "\(tag) has no macOS build attached."
        case .unknownAsset(let name):
            return "\(name) is not listed in SHA256SUMS, so it cannot be verified."
        case .hashMismatch(let expected, let got):
            return "The download does not match its published checksum "
                + "(expected \(expected.prefix(12))…, got \(got.prefix(12))…). It was discarded."
        case .signatureRejected(let detail):
            return "The downloaded app is not signed by the same identity as this one "
                + "(\(detail)). It was discarded."
        }
    }
}
