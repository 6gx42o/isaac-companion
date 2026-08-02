import Foundation
import IsaacCore

/// Reads Isaac's persistent save to find out which achievements YOU have unlocked.
///
/// Format, verified byte by byte against this machine's saves:
///
///     0x00  "ISAACNGSAVE09R  "   16-byte magic
///     0x10  checksum             u32
///     0x14  unknown (always 1)   u32
///     0x18  count (404)          u32
///     0x1C  size in bytes (404)  u32   -> one byte per entry
///     0x20  flags                404 x u8, each 0 or 1
///
/// Index 0 is unused; indices 1...403 line up with `achievements.xml` ids. Confirmed
/// two ways: the three dated saves on disk read 8 -> 16 -> 32 unlocks with **zero**
/// flags ever going 1 -> 0, and the named results are a coherent early-game profile
/// (Magdalene, Cain, beat Mom, kill the 7 sins).
///
/// This is read-only. The app never writes here — corrupting a save would cost real
/// progress, and nothing about this feature needs to.
public struct SaveFile: Sendable {
    public static let magic = "ISAACNGSAVE09R"

    /// Steam's copy is the live one the game writes during play. The dated copies in
    /// Application Support are the game's own backups and lag behind.
    public static func candidatePaths() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let steam = home.appending(path: "Library/Application Support/Steam/userdata")
        var found: [URL] = []
        if let users = try? FileManager.default.contentsOfDirectory(atPath: steam.path) {
            for user in users {
                let p = steam.appending(path: "\(user)/250900/remote/abp_persistentgamedata1.dat")
                if FileManager.default.fileExists(atPath: p.path) { found.append(p) }
            }
        }
        let support = home.appending(path: "Library/Application Support/Binding of Isaac Afterbirth+")
        if let files = try? FileManager.default.contentsOfDirectory(atPath: support.path) {
            // Newest backup first, so a missing Steam copy still gets recent data.
            for f in files.filter({ $0.hasSuffix("abp_persistentgamedata1.dat") }).sorted().reversed() {
                found.append(support.appending(path: f))
            }
        }
        return found
    }

    public struct Progress: Sendable {
        public var unlocked: Set<Int>
        public var source: URL
        public var modified: Date?
        public var total: Int
    }

    public init() {}

    public func read(from url: URL) throws -> Progress {
        let data = try Data(contentsOf: url)
        guard data.count >= 0x20,
              String(decoding: data[0..<14], as: UTF8.self) == Self.magic
        else {
            throw NSError(
                domain: "IsaacCompanion", code: 20,
                userInfo: [NSLocalizedDescriptionKey:
                    "\(url.lastPathComponent) is not an Afterbirth+ save (bad magic)."])
        }
        func u32(_ offset: Int) -> Int {
            Int(
                data.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                }.littleEndian)
        }
        let count = u32(0x18)
        let size = u32(0x1C)
        // One byte per flag is the only layout observed. Anything else means the format
        // changed, and guessing would silently produce a wrong unlock list.
        guard count > 0, count <= 4096, size == count, data.count >= 0x20 + count else {
            throw NSError(
                domain: "IsaacCompanion", code: 21,
                userInfo: [NSLocalizedDescriptionKey:
                    "Unexpected save layout (count \(count), size \(size)). "
                    + "The format may have changed; unlock data was not read."])
        }
        var unlocked = Set<Int>()
        for i in 0..<count where data[0x20 + i] == 1 { unlocked.insert(i) }
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        return Progress(unlocked: unlocked, source: url, modified: modified, total: count - 1)
    }

    /// Best available progress, or nil if no readable save exists.
    public func readBest() -> Progress? {
        for url in Self.candidatePaths() {
            if let p = try? read(from: url) { return p }
        }
        return nil
    }
}
