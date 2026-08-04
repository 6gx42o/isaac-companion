import AppKit
import CoreGraphics
import Foundation
import Ingest
import IsaacCore
import IsaacVision
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

    /// What is in the pocket slot.
    ///
    /// A card is a complete answer the moment it is seen -- its face IS its identity and
    /// the game never reshuffles it, unlike pill colours. A pill is only half an answer.
    enum Pocket: Equatable {
        /// Usually one id. More than one when the game ships no art that tells them
        /// apart -- Blank Rune and Black Rune are the same sprite -- in which case
        /// saying "one of these" is the only honest answer.
        case card(ids: [Int], confidence: Double)
        case pill(colour: Int, confidence: Double)
    }

    enum ScanError: LocalizedError {
        case noPermission
        case gameWindowNotFound
        case gameNotVisible
        case noAtlas

        var errorDescription: String? {
            switch self {
            case .noPermission:
                "Screen Recording permission is needed to read the pedestals. "
                    + "Grant it in System Settings > Privacy & Security > Screen Recording."
            case .gameWindowNotFound:
                "Could not find the Isaac window — is the game running?"
            case .gameNotVisible:
                "The game is running but not on screen — switch to it and scan again."
            case .noAtlas:
                "Sprite atlas is missing; rebuild the data first."
            }
        }
    }

    static var roomOrigin: CGPoint { RoomGeometry.origin }
    static var roomSize: CGSize { RoomGeometry.size }

    private var matcher = SpriteMatcher(side: 32, templates: [])

    /// Builds normalised templates once, from the same atlas the UI draws.
    private var pillReader: SpriteColourReader?
    private var cardReader: SpriteColourReader?

    func loadTemplates(items: [Item]) throws {
        guard let index = Pipeline.loadAtlasIndex(),
            let atlasData = try? Data(
                contentsOf: DataPaths.dataDir(.abplus).appending(path: "atlas.png")),
            let atlas = NSImage(data: atlasData),
            let atlasCG = atlas.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw ScanError.noAtlas }

        let byGfx = Dictionary(
            items.filter { $0.kind != .trinket && !$0.gfx.isEmpty }
                .map { ($0.gfx.lowercased(), $0.id) },
            uniquingKeysWith: { a, _ in a })

        let templates = index.entries.compactMap { entry -> SpriteMatcher.Template? in
            guard let id = byGfx[entry.key.lowercased()],
                  let crop = atlasCG.cropping(
                    to: CGRect(x: entry.x, y: entry.y, width: entry.w, height: entry.h)),
                  let pixels = SpriteMatcher.grayscale(crop, side: index.cell)
            else { return nil }
            return SpriteMatcher.Template(id: id, pixels: pixels)
        }
        matcher = SpriteMatcher(side: index.cell, templates: templates)
    }

    var templateCount: Int { matcher.templates.count }

    /// Grabs the Isaac window and matches each logged pedestal position.
    func scan(pedestals: [(x: Double, y: Double)], items: [Item]) async throws -> [Match] {
        if matcher.templates.isEmpty { try loadTemplates(items: items) }
        guard !pedestals.isEmpty else { return [] }

        let shot = try await captureGameWindow()
        let debug = ProcessInfo.processInfo.environment["ISAAC_SCAN_DEBUG"] == "1"
        if debug {
            log("capture \(shot.width)x\(shot.height) templates=\(templateCount)")
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

    /// One frame of the game window, with the permission preflight, the window search and
    /// the fullscreen fallback that every screen-reading feature needs.
    func captureGameWindow() async throws -> CGImage {
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
            // The display fallback captures what the SCREEN shows and crops to the game
            // window's frame -- which is only the game if the game's Space is the one on
            // screen. The first real capture ever taken proved the failure mode: the scan
            // fired while another Space was frontmost, and the "game" frame contained a
            // chat window. The confidence floor stopped a false match that time, but
            // pocket reads fire automatically, so refusing is the only safe answer.
            guard window.isOnScreen else {
                log("game window is not on screen; refusing the display fallback")
                throw ScanError.gameNotVisible
            }
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

        if ProcessInfo.processInfo.environment["ISAAC_SCAN_DEBUG"] == "1" {
            log("window '\(window.title ?? "?")' "
                    + "frame \(Int(window.frame.width))x\(Int(window.frame.height)) "
                    + "capture \(shot.width)x\(shot.height)")
        }
        return shot
    }

    /// Builds one colour template per card face, from the same atlas the UI draws.
    private func loadCardTemplates(items: [Item]) {
        guard cardReader == nil else { return }
        guard let index = Pipeline.loadAtlasIndex(),
              let data = try? Data(
                contentsOf: DataPaths.dataDir(.abplus).appending(path: "atlas.png")),
              let atlas = NSImage(data: data)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        let byGfx = Dictionary(
            items.filter { $0.kind == .card && !$0.gfx.isEmpty }
                .map { ($0.gfx.lowercased(), $0.id) },
            uniquingKeysWith: { a, _ in a })

        let sprites: [(id: Int, image: CGImage)] = index.entries.compactMap { entry in
            guard let id = byGfx[entry.key.lowercased()],
                  let crop = atlas.cropping(
                    to: CGRect(x: entry.x, y: entry.y, width: entry.w, height: entry.h))
            else { return nil }
            return (id, crop)
        }
        cardReader = SpriteColourReader(
            side: SpriteColourReader.cardSide, sprites: sprites)
    }

    /// Reads whatever is in the pocket slot -- a card or a pill.
    ///
    /// Both are searched and the better score wins, because the slot holds one or the
    /// other and the app cannot know which from the log. A card that scores 0.94 beats a
    /// pill that scores 0.85 and vice versa; if neither clears the floor, the honest
    /// answer is that the slot looks empty.
    func readPocket(pillStrip: CGImage, items: [Item]) async throws -> Pocket? {
        if pillReader == nil {
            pillReader = SpriteColourReader(
                strip: pillStrip, side: SpriteColourReader.pillSide)
        }
        loadCardTemplates(items: items)
        guard pillReader != nil || cardReader != nil else { throw ScanError.noAtlas }

        let shot = try await captureGameWindow()
        let debug = ProcessInfo.processInfo.environment["ISAAC_SCAN_DEBUG"] == "1"
        if debug { Self.dump(shot, name: "pocket-full") }

        // The game letterboxes a 480x270 field into the window, so on-screen sprite size
        // follows the same scale the room geometry already uses.
        let scale = min(CGFloat(shot.width) / 480, CGFloat(shot.height) / 270)
        // BOTTOM-RIGHT, and tight. Both facts were measured off a real frame, after an
        // entire play session of empty reads:
        //
        //  - The corner. Afterbirth+ draws the pocket item at the bottom RIGHT. The
        //    bottom left this used to crop is room floor, so the reader was looking at
        //    the wrong place and correctly finding nothing there.
        //  - The size. The card occupies roughly 13x19 game pixels, 7-25 in from the
        //    bottom edge and 10-23 in from the right. Searching a 120x90 region for it
        //    is searching mostly dark room floor, and dark textured floor scores well
        //    against an almost-black card -- the search found A Card Against Humanity
        //    in the wood planks rather than the Justice card actually held. A tight box
        //    removes the haystack instead of trying to out-score it.
        // 46 game px: enough to hold the 32-px template footprint plus room to slide.
        let cornerW = min(shot.width, Int(46 * scale))
        let cornerH = min(shot.height, Int(46 * scale))
        guard let corner = shot.cropping(
            to: CGRect(
                x: shot.width - cornerW, y: shot.height - cornerH,
                width: cornerW, height: cornerH))
        else { return nil }
        if debug { Self.dump(corner, name: "pocket-slot") }

        var best: Pocket?
        var bestScore = 0.0

        // Cards are drawn larger than pills in the slot.
        if let reader = cardReader,
           // 32 game px, because that is the template's own cell size -- the art fills
           // only 14x18 of it, and a window sized to the visible art would compare the
           // sprite against a resampling of itself at the wrong scale.
           let hit = reader.best(in: corner, window: max(16, Int((32 * scale).rounded())), stride: 2),
           hit.match.score > bestScore {
            bestScore = hit.match.score
            // Re-read the winning window to collect anything indistinguishable from it.
            var ids = [hit.match.index]
            if let crop = corner.cropping(to: hit.rect),
               let (rgb, _) = SpriteColourReader.rgba(crop, side: reader.side) {
                let tied = reader.ranked(candidate: rgb).best.map(\.index)
                if tied.count > 1 { ids = tied.sorted() }
            }
            best = .card(ids: ids, confidence: hit.match.score)
        }
        if let reader = pillReader,
           let hit = reader.best(in: corner, window: max(12, Int((32 * scale).rounded())), stride: 2),
           hit.match.score > bestScore {
            bestScore = hit.match.score
            best = .pill(colour: hit.match.index, confidence: hit.match.score)
        }
        if debug { log("pocket -> \(best.map { "\($0)" } ?? "nothing")") }
        return best
    }

    /// Reads the colour of a pill lying ON THE FLOOR, at the position the spawn line
    /// gave. This exists because the pocket slot is a losing race: a player who grabs
    /// and swallows leaves the slot occupied for under a second, and every slot read of
    /// an entire session came back empty. The floor position, by contrast, is known the
    /// moment the log announces it, while the pill just sits there.
    func readFloorPill(at position: (x: Double, y: Double), pillStrip: CGImage)
        async throws -> SpriteColourReader.Match?
    {
        if pillReader == nil {
            pillReader = SpriteColourReader(strip: pillStrip, side: SpriteColourReader.pillSide)
        }
        guard let reader = pillReader else { throw ScanError.noAtlas }
        let shot = try await captureGameWindow()
        guard let rect = Self.screenRect(
            forRoomPosition: CGPoint(x: position.x, y: position.y),
            in: CGSize(width: shot.width, height: shot.height)),
            let crop = shot.cropping(to: rect)
        else { return nil }
        if ProcessInfo.processInfo.environment["ISAAC_SCAN_DEBUG"] == "1" {
            Self.dump(crop, name: "floor-pill-\(Int(position.x))-\(Int(position.y))")
        }
        let scale = min(CGFloat(shot.width) / 480, CGFloat(shot.height) / 270)
        let window = max(12, Int((16 * scale).rounded()))
        guard let hit = reader.best(in: crop, window: window, stride: 2) else {
            log("floor pill at (\(Int(position.x)),\(Int(position.y))): no confident colour")
            return nil
        }
        log("floor pill at (\(Int(position.x)),\(Int(position.y))): colour \(hit.match.index) "
                + String(format: "%.3f", hit.match.score))
        return hit.match
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
    /// The arithmetic lives in IsaacVision.RoomGeometry, where it is testable.
    static func screenRect(forRoomPosition position: CGPoint, in imageSize: CGSize) -> CGRect? {
        RoomGeometry.screenRect(forRoomPosition: position, in: imageSize)
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
    //
    // Both of these are one line now: the correlation itself lives in
    // IsaacVision.SpriteMatcher so it can be run against a PNG from a test or from
    // `ingestctl scan`, rather than only against a live screen capture.

    func topMatches(in image: CGImage, count: Int) -> [(id: Int, score: Double)] {
        matcher.scores(inImage: image).prefix(count).map { ($0.id, $0.score) }
    }

    private func bestMatch(in image: CGImage) -> (id: Int, score: Double)? {
        matcher.best(inImage: image).map { ($0.id, $0.score) }
    }
}
