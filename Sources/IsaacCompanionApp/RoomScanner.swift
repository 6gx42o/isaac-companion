import AppKit
import CoreGraphics
import Foundation
import Ingest
import IsaacCore
// @preconcurrency because SCShareableContent is not annotated Sendable in every SDK we
// build against: it compiles clean on Swift 6.2 here and fails strict-concurrency on the
// 6.1 toolchain CI uses. The annotation is the SDK's gap, not ours -- every use below is
// already confined to this actor.
@preconcurrency import ScreenCaptureKit

/// Identifies the items sitting on pedestals by looking at the screen.
///
/// The log announces that a collectible pedestal spawned, and at what room position,
/// but never which item is on it -- so the only way to know is to look. This is
/// read-only screen capture: it never touches the game, so achievements are unaffected.
///
/// Capture only happens on demand (entering a Devil/Treasure room, or a hotkey), never
/// continuously, so the idle cost is zero.
@MainActor
final class RoomScanner {
    struct Match {
        var itemID: Int
        var confidence: Double
        var position: CGPoint       // room coordinates, from the log
    }

    enum ScanError: LocalizedError {
        case noPermission
        case gameWindowNotFound
        case noAtlas

        var errorDescription: String? {
            switch self {
            case .noPermission:
                "Screen Recording permission is needed to read the pedestals. "
                    + "Grant it in System Settings > Privacy & Security > Screen Recording."
            case .gameWindowNotFound:
                "Could not find the Isaac window — is the game running?"
            case .noAtlas:
                "Sprite atlas is missing; rebuild the data first."
            }
        }
    }

    /// Isaac's playable room area in the game's own position units. A 1x1 room spans
    /// this box, and its centre is (320, 280) -- which is exactly what the log reports
    /// for a lone pedestal, so these bounds are self-checking.
    static let roomOrigin = CGPoint(x: 80, y: 160)
    static let roomSize = CGSize(width: 480, height: 240)

    private var templates: [(id: Int, pixels: [Float], mean: Float, norm: Float)] = []
    private var templateSide = 32

    /// Builds normalised templates once, from the same atlas the UI draws.
    func loadTemplates(items: [Item]) throws {
        guard let index = Pipeline.loadAtlasIndex(),
            let atlasData = try? Data(
                contentsOf: DataPaths.dataDir(.abplus).appending(path: "atlas.png")),
            let atlas = NSImage(data: atlasData),
            let atlasCG = atlas.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw ScanError.noAtlas }

        templateSide = index.cell
        let byGfx = Dictionary(
            items.filter { $0.kind != .trinket && !$0.gfx.isEmpty }
                .map { ($0.gfx.lowercased(), $0.id) },
            uniquingKeysWith: { a, _ in a })

        templates = index.entries.compactMap { entry in
            guard let id = byGfx[entry.key.lowercased()],
                  let crop = atlasCG.cropping(
                    to: CGRect(x: entry.x, y: entry.y, width: entry.w, height: entry.h)),
                  let pixels = Self.grayscale(crop, side: index.cell)
            else { return nil }
            let (mean, norm) = Self.normalise(pixels)
            guard norm > 0 else { return nil }
            return (id, pixels, mean, norm)
        }
    }

    /// Grabs the Isaac window and matches each logged pedestal position.
    func scan(pedestals: [(x: Double, y: Double)], items: [Item]) async throws -> [Match] {
        if templates.isEmpty { try loadTemplates(items: items) }
        guard !pedestals.isEmpty else { return [] }

        // Ask up front rather than letting SCScreenshotManager fail with the opaque
        // "audio/video capture failure", which is what a missing grant actually
        // produces. CGRequestScreenCaptureAccess raises the system prompt once.
        guard CGPreflightScreenCaptureAccess() else {
            log("no Screen Recording permission; requesting it")
            _ = CGRequestScreenCaptureAccess()
            throw ScanError.noPermission
        }

        // `onScreenWindowsOnly: false` — a fullscreen game lives on its own Space, so
        // from this app's Space its window is not "on screen" and would be filtered out.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        if ProcessInfo.processInfo.environment["ISAAC_SCAN_DEBUG"] == "1" {
            for window in content.windows where (window.owningApplication?.applicationName ?? "")
                .localizedCaseInsensitiveContains("isaac") {
                log("saw '\(window.owningApplication?.applicationName ?? "?")' "
                        + "[\(window.owningApplication?.bundleIdentifier ?? "?")] "
                        + "\(Int(window.frame.width))x\(Int(window.frame.height))")
            }
        }
        // Match the game by bundle id, not by name: this app is called
        // "IsaacCompanion", so a name match happily selects our own window.
        // Falling back to a name match still excludes ourselves, and the largest
        // candidate wins so a title bar or helper window cannot be picked.
        let ownBundleID = Bundle.main.bundleIdentifier ?? ""
        let candidates = content.windows.filter { window in
            guard let app = window.owningApplication else { return false }
            guard app.bundleIdentifier != ownBundleID else { return false }
            let isGame =
                app.bundleIdentifier.localizedCaseInsensitiveContains("binding-of-isaac")
                || app.bundleIdentifier.localizedCaseInsensitiveContains("nicalis")
                || app.applicationName.localizedCaseInsensitiveContains("binding of isaac")
            // A real game window, not a 48px title strip.
            return isGame && window.frame.width >= 320 && window.frame.height >= 240
        }
        guard let window = candidates.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else { throw ScanError.gameWindowNotFound }

        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width)
        config.height = Int(window.frame.height)
        config.scalesToFit = false
        config.showsCursor = false

        // Window capture is preferred (it crops to the game for free), but a game
        // running fullscreen on its own Space often cannot be captured that way. Fall
        // back to grabbing the display it sits on and cropping to its frame.
        var shot: CGImage
        do {
            shot = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: config)
        } catch {
            log("window capture failed (\(error.localizedDescription)); trying the display")
            guard let display = content.displays.first(where: {
                CGRect(
                    x: CGFloat($0.frame.origin.x), y: CGFloat($0.frame.origin.y),
                    width: CGFloat($0.width), height: CGFloat($0.height)
                ).intersects(window.frame)
            }) ?? content.displays.first else { throw error }

            let displayConfig = SCStreamConfiguration()
            displayConfig.width = display.width
            displayConfig.height = display.height
            displayConfig.showsCursor = false
            let full = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: []),
                configuration: displayConfig)

            // Crop to the game's frame, in display-local pixels.
            let scaleX = CGFloat(full.width) / CGFloat(display.frame.width)
            let scaleY = CGFloat(full.height) / CGFloat(display.frame.height)
            let local = CGRect(
                x: (window.frame.minX - display.frame.minX) * scaleX,
                y: (window.frame.minY - display.frame.minY) * scaleY,
                width: window.frame.width * scaleX,
                height: window.frame.height * scaleY)
            shot = full.cropping(to: local) ?? full
        }

        let debug = ProcessInfo.processInfo.environment["ISAAC_SCAN_DEBUG"] == "1"
        if debug {
            log("window '\(window.title ?? "?")' "
                    + "frame \(Int(window.frame.width))x\(Int(window.frame.height)) "
                    + "capture \(shot.width)x\(shot.height) templates=\(templates.count)")
            Self.dump(shot, name: "scan-full")
        }

        return pedestals.compactMap { pedestal in
            guard let rect = Self.screenRect(
                forRoomPosition: CGPoint(x: pedestal.x, y: pedestal.y),
                in: CGSize(width: shot.width, height: shot.height))
            else { return nil }
            guard let crop = shot.cropping(to: rect) else { return nil }
            if debug {
                log("pedestal (\(Int(pedestal.x)),\(Int(pedestal.y))) -> "
                        + "rect \(Int(rect.origin.x)),\(Int(rect.origin.y)) "
                        + "\(Int(rect.width))x\(Int(rect.height))")
                Self.dump(crop, name: "scan-crop-\(Int(pedestal.x))-\(Int(pedestal.y))")
                for candidate in topMatches(in: crop, count: 5) {
                    log("  candidate #\(candidate.id) "
                            + String(format: "%.3f", candidate.score))
                }
            }
            guard let best = bestMatch(in: crop) else { return nil }
            return Match(
                itemID: best.id, confidence: best.score,
                position: CGPoint(x: pedestal.x, y: pedestal.y))
        }
    }

    /// Writes an image to the scratch dir so a failing scan can actually be looked at.
    private static func dump(_ image: CGImage, name: String) {
        let dir = ProcessInfo.processInfo.environment["ISAAC_SCAN_DUMP_DIR"]
            ?? NSTemporaryDirectory()
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: dir).appending(path: "\(name).png")
        try? png.write(to: url)
        log("wrote \(url.path)")
    }

    /// Maps a room position to the pixel box the sprite should occupy.
    ///
    /// The game letterboxes the room to the window, so this scales by the smaller
    /// axis and centres. The box is deliberately generous: pedestal sprites bob up
    /// and down a few pixels.
    static func screenRect(forRoomPosition position: CGPoint, in imageSize: CGSize) -> CGRect? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let scale = min(
            imageSize.width / roomSize.width, imageSize.height / roomSize.height)
        let drawn = CGSize(width: roomSize.width * scale, height: roomSize.height * scale)
        let offset = CGPoint(
            x: (imageSize.width - drawn.width) / 2, y: (imageSize.height - drawn.height) / 2)
        let local = CGPoint(
            x: (position.x - roomOrigin.x) * scale + offset.x,
            y: (position.y - roomOrigin.y) * scale + offset.y)
        let side = 40 * scale                       // one tile, plus bob headroom
        let rect = CGRect(
            x: local.x - side / 2, y: local.y - side * 0.75, width: side, height: side * 1.5)
        return rect.intersection(CGRect(origin: .zero, size: imageSize)).isNull ? nil : rect
    }


    /// Debug output goes to a file as well as stdout: the app has to be launched with
    /// `open` for Screen Recording permission to attribute correctly, and that detaches
    /// stdout.
    static func log(_ message: String) {
        // `print`, never `log` — calling itself here recurses until the stack blows.
        print("SCAN DEBUG: \(message)")
        guard let dir = ProcessInfo.processInfo.environment["ISAAC_SCAN_DUMP_DIR"] else { return }
        let url = URL(fileURLWithPath: dir).appending(path: "scan.log")
        let line = message + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func log(_ message: String) { Self.log(message) }

    // MARK: - matching

    func topMatches(in image: CGImage, count: Int) -> [(id: Int, score: Double)] {
        guard let haystack = Self.grayscale(image, side: templateSide * 2) else { return [] }
        let side = templateSide * 2
        var scored: [(id: Int, score: Double)] = []
        for template in templates {
            var best: Float = -1
            for dy in stride(from: 0, through: side - templateSide, by: 4) {
                for dx in stride(from: 0, through: side - templateSide, by: 4) {
                    var window = [Float](repeating: 0, count: templateSide * templateSide)
                    for row in 0..<templateSide {
                        let src = (dy + row) * side + dx
                        for col in 0..<templateSide {
                            window[row * templateSide + col] = haystack[src + col]
                        }
                    }
                    let (mean, norm) = Self.normalise(window)
                    guard norm > 0 else { continue }
                    var dot: Float = 0
                    for i in 0..<window.count {
                        dot += (window[i] - mean) * (template.pixels[i] - template.mean)
                    }
                    best = max(best, dot / (norm * template.norm))
                }
            }
            scored.append((template.id, Double(best)))
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(count))
    }

    private func bestMatch(in image: CGImage) -> (id: Int, score: Double)? {
        guard let haystack = Self.grayscale(image, side: templateSide * 2) else { return nil }
        let side = templateSide * 2
        var best: (id: Int, score: Double)?

        // Slide each template over the crop. The crop is small (64x64 by default) and
        // the stride is coarse, so this stays well inside the 300 ms budget even with
        // ~550 templates.
        for template in templates {
            var bestForTemplate: Float = -1
            for dy in stride(from: 0, through: side - templateSide, by: 4) {
                for dx in stride(from: 0, through: side - templateSide, by: 4) {
                    var window = [Float](repeating: 0, count: templateSide * templateSide)
                    for row in 0..<templateSide {
                        let src = (dy + row) * side + dx
                        for col in 0..<templateSide {
                            window[row * templateSide + col] = haystack[src + col]
                        }
                    }
                    let (mean, norm) = Self.normalise(window)
                    guard norm > 0 else { continue }
                    var dot: Float = 0
                    for i in 0..<window.count {
                        dot += (window[i] - mean) * (template.pixels[i] - template.mean)
                    }
                    bestForTemplate = max(bestForTemplate, dot / (norm * template.norm))
                }
            }
            if best == nil || Double(bestForTemplate) > best!.score {
                best = (template.id, Double(bestForTemplate))
            }
        }
        // Below this the match is noise; better to say nothing than to name the wrong item.
        guard let best, best.score > 0.55 else { return nil }
        return best
    }

    private static func normalise(_ pixels: [Float]) -> (mean: Float, norm: Float) {
        let mean = pixels.reduce(0, +) / Float(pixels.count)
        let norm = pixels.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) }.squareRoot()
        return (mean, norm)
    }

    private static func grayscale(_ image: CGImage, side: Int) -> [Float]? {
        var bytes = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(
            data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return bytes.map { Float($0) / 255 }
    }
}
