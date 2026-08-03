import AppKit
import CryptoKit
import Foundation
import IsaacCore
import Security

/// Downloads and installs new versions from GitHub Releases.
///
/// This is the only feature in the app that fetches code and then runs it, so the rules
/// it follows are worth stating plainly:
///
///  1. **Nothing is installed that cannot be verified.** The SHA-256 of the download must
///     match the `SHA256SUMS` asset published with the release, and the extracted app must
///     carry a valid signature from the same identity as the running one. A build that
///     fails either check is deleted, not run, and the failure is reported rather than
///     retried.
///  2. **Nothing is swapped mid-run.** This app sits beside a game. Replacing its own
///     binary while a run is in progress is worse than being one version behind, so an
///     install waits for the game to close.
///  3. **The user is told first.** Checking is automatic; installing is not.
///
/// The decision logic lives in `IsaacCore.UpdateCheck`, which has no networking and is
/// unit-tested. This half does the talking, hashing and file-shuffling.
@MainActor
@Observable
public final class Updater {
    public enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(fraction: Double)
        /// Verified and staged at the given path, waiting for the user to say go.
        case ready(Release)
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var lastChecked: Date?
    /// Set when an install is held back because the game is running.
    public private(set) var waitingForGame = false

    /// Test hook (ISAAC_UPDATE_TEST): pretend the manifest said something else, so the
    /// refusal path can be exercised against a real download rather than reasoned about.
    /// A security check nobody has ever seen fire is a security check nobody has tested.
    var forceHashMismatch = false

    private(set) var staged: URL?
    private let feedURL = URL(
        string: "https://api.github.com/repos/6gx42o/isaac-companion/releases")!

    public init() {}

    // MARK: - what we are

    public static var currentVersion: SemVer {
        let s =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
        return SemVer(s) ?? SemVer(major: 0, minor: 0, patch: 0)
    }

    public var currentVersionString: String { Self.currentVersion.description }

    // MARK: - checking

    /// Fetches the feed and reports whether anything newer exists.
    public func check(includePrereleases: Bool = false) async {
        state = .checking
        do {
            var request = URLRequest(url: feedURL)
            // Unauthenticated GitHub API calls are rate-limited per IP; a daily check is
            // nowhere near it, but identify ourselves so a throttle is diagnosable.
            request.setValue(
                "IsaacCompanion/\(currentVersionString)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw NSError(
                    domain: "IsaacCompanion", code: http.statusCode,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The update server returned \(http.statusCode)."
                    ])
            }
            let releases = try UpdateCheck.releases(fromJSON: data)
            lastChecked = Date()
            if let next = UpdateCheck.newest(
                in: releases, current: Self.currentVersion,
                includePrereleases: includePrereleases) {
                state = .available(next)
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - downloading and verifying

    /// Downloads, verifies, and stages the release. Does not install it.
    public func download(_ release: Release) async {
        state = .downloading(fraction: 0)
        do {
            guard let zip = release.macAppZip else { throw UpdateError.noMacBuild(release.tag) }
            guard let sums = release.checksums else { throw UpdateError.noChecksums }

            let work = URL.temporaryDirectory.appending(
                path: "IsaacCompanionUpdate-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            // Any failure from here on leaves nothing behind. An updater that litters
            // half-downloaded apps around /tmp is its own kind of bug.
            defer { try? FileManager.default.removeItem(at: work) }

            let manifest = String(decoding: try await fetch(sums.url), as: UTF8.self)
            guard var expected = UpdateCheck.expectedHash(
                forFile: zip.name, inManifest: manifest)
            else { throw UpdateError.unknownAsset(zip.name) }
            if forceHashMismatch { expected = String(repeating: "0", count: 64) }

            state = .downloading(fraction: 0.15)
            let payload = try await fetch(zip.url)
            state = .downloading(fraction: 0.7)

            let got = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            guard got == expected else {
                throw UpdateError.hashMismatch(expected: expected, got: got)
            }

            let zipPath = work.appending(path: zip.name)
            try payload.write(to: zipPath)
            let unpacked = work.appending(path: "unpacked", directoryHint: .isDirectory)
            try run("/usr/bin/ditto", ["-x", "-k", zipPath.path, unpacked.path])

            guard let app = try FileManager.default
                .contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" })
            else { throw UpdateError.unknownAsset("the archive contains no .app") }

            try verifySignature(of: app)

            // Staged outside `work` so the defer above does not delete it.
            let stage = URL.temporaryDirectory.appending(
                path: "IsaacCompanion-\(release.tag).app", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: stage)
            try FileManager.default.moveItem(at: app, to: stage)
            staged = stage
            state = .ready(release)
        } catch {
            staged = nil
            state = .failed(error.localizedDescription)
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(
            "IsaacCompanion/\(currentVersionString)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(
                domain: "IsaacCompanion", code: http.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey: "Download failed (HTTP \(http.statusCode))."
                ])
        }
        return data
    }

    /// The signature must be valid, and — when we can tell — from the same identity.
    ///
    /// The hash check above is the primary guard: it pins the bytes to a manifest fetched
    /// over HTTPS from the release. This is defence in depth, and it is what stops a
    /// correctly-hashed but differently-signed build from being installed.
    ///
    /// When the *running* app is ad-hoc signed there is no certificate to compare against,
    /// so the identity comparison is skipped and only validity is required. That is the
    /// honest answer rather than a false sense of security: a build with no signing
    /// identity cannot attest to anything about its successor.
    func verifySignature(of app: URL) throws {
        var new: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &new) == errSecSuccess,
            let new
        else { throw UpdateError.signatureRejected("it has no readable signature") }

        let status = SecStaticCodeCheckValidity(
            new, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil)
        guard status == errSecSuccess else {
            throw UpdateError.signatureRejected("its signature is not valid (OSStatus \(status))")
        }

        guard let mine = leafCertificateHash(of: currentCode()) else { return }
        guard let theirs = leafCertificateHash(of: new) else {
            throw UpdateError.signatureRejected("it is unsigned, but this build is signed")
        }
        guard mine == theirs else {
            throw UpdateError.signatureRejected("different signing certificate")
        }
    }

    private func currentCode() -> SecStaticCode? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var stat: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &stat) == errSecSuccess else { return nil }
        return stat
    }

    private func leafCertificateHash(of code: SecStaticCode?) -> Data? {
        guard let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let dict = info as? [String: Any],
            let chain = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
            let leaf = chain.first
        else { return nil }
        return Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
    }

    // MARK: - installing

    /// Swaps the staged build in and relaunches.
    ///
    /// A process cannot replace the bundle it is executing from and keep running, so the
    /// swap is handed to a detached shell that waits for this process to exit first. That
    /// is also why the game check happens here rather than at download time: the download
    /// is harmless, the relaunch is not.
    public func install(gameIsRunning: Bool) {
        guard case .ready = state, let staged else { return }
        guard !gameIsRunning else {
            waitingForGame = true
            return
        }
        waitingForGame = false

        let target = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        // Wait for the pid to go away, swap, relaunch. `kill -0` polls without signalling.
        // The old bundle is kept until the move succeeds, so a failure part-way leaves a
        // working app rather than a missing one.
        let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            rm -rf '\(target.path).old'
            mv '\(target.path)' '\(target.path).old' || exit 1
            if mv '\(staged.path)' '\(target.path)'; then
              rm -rf '\(target.path).old'
            else
              mv '\(target.path).old' '\(target.path)'
              exit 1
            fi
            open -n '\(target.path)'
            """
        let task = Process()
        task.executableURL = URL(filePath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(filePath: tool)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw NSError(
                domain: "IsaacCompanion", code: Int(task.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(URL(filePath: tool).lastPathComponent) failed: "
                        + String(decoding: out, as: UTF8.self).trimmingCharacters(
                            in: .whitespacesAndNewlines)
                ])
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - for the web UI

    public func stateJSON() -> String {
        var out: [String: Any] = [
            "current": currentVersionString,
            "waitingForGame": waitingForGame,
        ]
        if let lastChecked {
            out["lastChecked"] = ISO8601DateFormatter().string(from: lastChecked)
        }
        switch state {
        case .idle: out["status"] = "idle"
        case .checking: out["status"] = "checking"
        case .upToDate: out["status"] = "current"
        case .available(let r):
            out["status"] = "available"
            out["version"] = r.version.description
            out["tag"] = r.tag
            out["notes"] = r.notes
        case .downloading(let f):
            out["status"] = "downloading"
            out["fraction"] = f
        case .ready(let r):
            out["status"] = "ready"
            out["version"] = r.version.description
            out["tag"] = r.tag
            out["notes"] = r.notes
        case .failed(let message):
            out["status"] = "failed"
            out["error"] = message
        }
        return (try? JSONSerialization.data(withJSONObject: out))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
