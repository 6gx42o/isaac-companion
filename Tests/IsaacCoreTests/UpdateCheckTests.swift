import Foundation
import Testing

@testable import IsaacCore

@Suite("SemVer")
struct SemVerTests {
    @Test("Parses the shapes our own tags and plist actually use")
    func parses() {
        // The git tag carries a v, CFBundleShortVersionString does not, and both have to
        // compare equal or every launch offers the version already installed.
        #expect(SemVer("v0.2.0") == SemVer("0.2.0"))
        #expect(SemVer("0.2.0")?.description == "0.2.0")
        #expect(SemVer("1.2")?.patch == 0)
        #expect(SemVer("3")?.major == 3)
        #expect(SemVer("1.0.0-beta.1")?.prerelease == "beta.1")
        // Build metadata never affects precedence.
        #expect(SemVer("1.0.0+abc") == SemVer("1.0.0"))
    }

    @Test("Rejects things that are not versions")
    func rejects() {
        #expect(SemVer("") == nil)
        #expect(SemVer("nightly") == nil)
        #expect(SemVer("1.2.3.4") == nil)
        #expect(SemVer("1.-2.0") == nil)
        #expect(SemVer("v") == nil)
    }

    @Test("Orders by component, not by string")
    func ordering() {
        // The one that a naive string compare gets wrong: "0.10.0" < "0.9.0" as text.
        #expect(SemVer("0.9.0")! < SemVer("0.10.0")!)
        #expect(SemVer("1.0.0")! < SemVer("1.0.1")!)
        #expect(SemVer("1.9.9")! < SemVer("2.0.0")!)
        #expect(!(SemVer("1.0.0")! < SemVer("1.0.0")!))
    }

    @Test("A pre-release precedes its own release")
    func prereleaseOrdering() {
        #expect(SemVer("1.0.0-beta.1")! < SemVer("1.0.0")!)
        #expect(SemVer("1.0.0-beta.1")! < SemVer("1.0.0-beta.2")!)
        #expect(SemVer("1.0.0")! > SemVer("1.0.0-rc.9")!)
    }
}

@Suite("UpdateCheck")
struct UpdateCheckTests {
    /// Shaped like GitHub's real payload, trimmed to the fields we read.
    private func feed(_ entries: String) -> Data {
        Data("[\(entries)]".utf8)
    }

    private func entry(
        tag: String, draft: Bool = false, prerelease: Bool = false, assets: String = ""
    ) -> String {
        """
        {"tag_name":"\(tag)","draft":\(draft),"prerelease":\(prerelease),
         "body":"notes for \(tag)","assets":[\(assets)]}
        """
    }

    private let asset = """
        {"name":"IsaacCompanion-0.3.0.zip","size":2189299,
         "browser_download_url":"https://example.invalid/IsaacCompanion-0.3.0.zip"},
        {"name":"SHA256SUMS","size":400,
         "browser_download_url":"https://example.invalid/SHA256SUMS"}
        """

    @Test("Reads a GitHub releases payload")
    func parsesFeed() throws {
        let data = feed(entry(tag: "v0.3.0", assets: asset))
        let releases = try UpdateCheck.releases(fromJSON: data)
        #expect(releases.count == 1)
        #expect(releases[0].version == SemVer("0.3.0"))
        #expect(releases[0].tag == "v0.3.0")
        #expect(releases[0].notes == "notes for v0.3.0")
        #expect(releases[0].asset(matching: ".zip")?.size == 2_189_299)
        #expect(releases[0].checksums != nil)
    }

    @Test("Skips drafts and tags that are not versions, rather than failing the check")
    func skipsUnusable() throws {
        // One hand-made tag in the list should not stop updates forever.
        let data = feed(
            [
                entry(tag: "nightly"),
                entry(tag: "v0.3.0", draft: true),
                entry(tag: "v0.2.0"),
            ].joined(separator: ","))
        let releases = try UpdateCheck.releases(fromJSON: data)
        #expect(releases.map(\.tag) == ["v0.2.0"])
    }

    @Test("Malformed JSON is an error, not a crash")
    func malformed() {
        #expect(throws: UpdateError.malformedFeed) {
            try UpdateCheck.releases(fromJSON: Data(#"{"not":"an array"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try UpdateCheck.releases(fromJSON: Data("not json at all".utf8))
        }
    }

    @Test("Offers only something strictly newer")
    func picksNewest() throws {
        let releases = try UpdateCheck.releases(
            fromJSON: feed(
                [entry(tag: "v0.1.0"), entry(tag: "v0.3.0"), entry(tag: "v0.2.0")]
                    .joined(separator: ",")))
        #expect(UpdateCheck.newest(in: releases, current: SemVer("0.2.0")!)?.tag == "v0.3.0")
        // Running the newest already: nothing to offer. Re-offering the installed
        // version is how an updater ends up in a loop.
        #expect(UpdateCheck.newest(in: releases, current: SemVer("0.3.0")!) == nil)
        // And never downgrade.
        #expect(UpdateCheck.newest(in: releases, current: SemVer("9.0.0")!) == nil)
    }

    @Test("Pre-releases are opt-in")
    func prereleaseOptIn() throws {
        let releases = try UpdateCheck.releases(
            fromJSON: feed(
                [entry(tag: "v0.2.0"), entry(tag: "v0.3.0-beta.1", prerelease: true)]
                    .joined(separator: ",")))
        #expect(UpdateCheck.newest(in: releases, current: SemVer("0.2.0")!) == nil)
        #expect(
            UpdateCheck.newest(
                in: releases, current: SemVer("0.2.0")!, includePrereleases: true)?.tag
                == "v0.3.0-beta.1")
    }

    @Test("Picks the macOS zip, not the Windows one that sorts before it")
    func picksTheRightZip() throws {
        // Regression. GitHub returns assets alphabetically, so "-windows-x64.zip" comes
        // before the plain ".zip" -- and a bare hasSuffix(".zip") match handed the macOS
        // updater the Windows build on every real release.
        let all = """
            {"name":"IsaacCompanion-0.3.0-windows-x64.exe","size":1,
             "browser_download_url":"https://example.invalid/a.exe"},
            {"name":"IsaacCompanion-0.3.0-windows-x64.zip","size":2,
             "browser_download_url":"https://example.invalid/a-win.zip"},
            {"name":"IsaacCompanion-0.3.0.dmg","size":3,
             "browser_download_url":"https://example.invalid/a.dmg"},
            {"name":"IsaacCompanion-0.3.0.zip","size":4,
             "browser_download_url":"https://example.invalid/a.zip"},
            {"name":"SHA256SUMS","size":5,
             "browser_download_url":"https://example.invalid/SHA256SUMS"}
            """
        let release = try #require(
            UpdateCheck.releases(fromJSON: feed(entry(tag: "v0.3.0", assets: all))).first)
        #expect(release.macAppZip?.name == "IsaacCompanion-0.3.0.zip")
        #expect(release.windowsExe?.name == "IsaacCompanion-0.3.0-windows-x64.exe")
        #expect(release.checksums?.name == "SHA256SUMS")
    }

    @Test("A release with no macOS build is reported, not silently skipped")
    func noMacBuild() throws {
        let winOnly = """
            {"name":"IsaacCompanion-0.3.0-windows-x64.zip","size":2,
             "browser_download_url":"https://example.invalid/a-win.zip"}
            """
        let release = try #require(
            UpdateCheck.releases(fromJSON: feed(entry(tag: "v0.3.0", assets: winOnly))).first)
        #expect(release.macAppZip == nil)
    }

    @Test("Finds a file's hash in a shasum manifest")
    func checksumLookup() {
        let manifest = """
            964ccfabb83b9219a722517f95bb1393ddf88ae4ed61166e6a2f0f0884813d07  IsaacCompanion-0.2.0-windows-x64.exe
            8fe7965641a1f28fedef3e06e28697a05e4fcb2557ea8347f32a882ded37bb40  IsaacCompanion-0.2.0.zip
            """
        #expect(
            UpdateCheck.expectedHash(
                forFile: "IsaacCompanion-0.2.0.zip", inManifest: manifest)
                == "8fe7965641a1f28fedef3e06e28697a05e4fcb2557ea8347f32a882ded37bb40")
        // A file that is not listed must come back nil so the caller refuses to install
        // it, rather than installing something unverified.
        #expect(UpdateCheck.expectedHash(forFile: "other.zip", inManifest: manifest) == nil)
    }

    @Test("Tolerates the several shapes shasum output comes in")
    func checksumFormats() {
        let hash = String(repeating: "a", count: 64)
        for line in ["\(hash)  f.zip", "\(hash) f.zip", "\(hash) *f.zip", "\(hash)  ./f.zip"] {
            #expect(
                UpdateCheck.expectedHash(forFile: "f.zip", inManifest: line) == hash,
                "failed on: \(line)")
        }
    }
}
