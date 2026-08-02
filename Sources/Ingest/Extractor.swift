import AppKit
import Foundation

/// Drives the game's own ResourceExtractor, then keeps only what we need.
///
/// The extractor writes ~570 MB. Item pools and sprites exist nowhere else -- they
/// live inside `resources/packed/*.a` -- but they are only ~4 MB of that. So the
/// flow is extract -> harvest -> delete, and Compact mode never keeps the bulk.
public struct Extractor: Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case notFound(URL)
        case failed(Int32, String)
        case missingOutput(String)

        public var description: String {
            switch self {
            case .notFound(let url):
                "ResourceExtractor not found at \(url.path). It ships with the game under tools/."
            case .failed(let code, let output):
                "ResourceExtractor exited with code \(code). \(output)"
            case .missingOutput(let what):
                "ResourceExtractor ran but produced no \(what)."
            }
        }
    }

    public var gameRoot: URL
    public init(gameRoot: URL) { self.gameRoot = gameRoot }

    public var binary: URL { gameRoot.appending(path: "tools/ResourceExtractor/ResourceExtractor") }

    public var isAvailable: Bool { FileManager.default.fileExists(atPath: binary.path) }

    /// Where harvested inputs live between builds.
    public static var harvestDir: URL { DataPaths.cacheDir.appending(path: "harvested") }
    public static var itemsXML: URL { harvestDir.appending(path: "items.xml") }
    /// Unlock conditions, and the consumables that are gated behind them.
    public static var achievementsXML: URL { harvestDir.appending(path: "achievements.xml") }
    public static var pocketItemsXML: URL { harvestDir.appending(path: "pocketitems.xml") }
    /// Every enemy and boss: names, HP, and the bossID the save-state line refers to.
    public static var entitiesXML: URL { harvestDir.appending(path: "entities2.xml") }
    public static var itemPoolsXML: URL { harvestDir.appending(path: "itempools.xml") }
    public static var spritesDir: URL { harvestDir.appending(path: "sprites") }
    public static var achievementIconsDir: URL { harvestDir.appending(path: "achievements") }
    public static var monsterArtDir: URL { harvestDir.appending(path: "monsters") }
    /// "type.variant" -> sheet file name, written by the harvest.
    public static var monsterArtIndex: URL { monsterArtDir.appending(path: "index.json") }
    /// How many idle frames each monster strip holds. Every strip is padded to this,
    /// so one atlas cell size and one `steps()` rule cover the whole bestiary.
    public static let monsterFrames = 3
    /// Every pill colour the game deals, in one horizontal strip.
    public static var pillStrip: URL { harvestDir.appending(path: "pills_strip.png") }

    public static var isHarvested: Bool {
        FileManager.default.fileExists(atPath: itemPoolsXML.path)
            && FileManager.default.fileExists(atPath: itemsXML.path)
    }

    /// Runs the extractor into a scratch directory, copies out the ~4 MB we need, and
    /// (unless `keepRaw`) deletes the rest.
    public func extractAndHarvest(
        keepRaw: Bool = false, progress: (@Sendable (String) -> Void)? = nil
    ) throws {
        guard isAvailable else { throw Failure.notFound(binary) }
        let fm = FileManager.default

        let scratch = DataPaths.cacheDir.appending(path: "extract-scratch")
        try? fm.removeItem(at: scratch)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)

        progress?("Extracting game resources (~570 MB, about a minute)…")
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            DataPaths.resourcesDir(gameRoot: gameRoot).path,
            scratch.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.failed(process.terminationStatus, String(output.suffix(400)))
        }

        progress?("Harvesting item pools and sprites…")
        let resources = scratch.appending(path: "resources")
        guard fm.fileExists(atPath: resources.appending(path: "itempools.xml").path) else {
            throw Failure.missingOutput("itempools.xml")
        }

        try? fm.removeItem(at: Self.harvestDir)
        try fm.createDirectory(at: Self.spritesDir, withIntermediateDirectories: true)
        try fm.copyItem(
            at: resources.appending(path: "itempools.xml"), to: Self.itemPoolsXML)
        // The extracted items.xml is the ENGLISH one -- better than the Japanese
        // resources.jp copy we fall back to when the extractor has not been run.
        // achievements.xml and pocketitems.xml are English-only and exist nowhere
        // unpacked, so this is the only chance to keep them.
        for name in ["items.xml", "achievements.xml", "pocketitems.xml", "entities2.xml"] {
            let src = resources.appending(path: name)
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.copyItem(at: src, to: Self.harvestDir.appending(path: name))
        }

        // Sprites land in gfx/items/{collectibles,trinkets}/ with lowercased names,
        // while items.xml refers to them in mixed case -- so they are re-keyed on
        // copy and matched case-insensitively later.
        var copied = 0
        // Achievement badges are plain PNGs keyed by the `gfx` attribute; monster art is
        // animation SHEETS, kept here so a representative frame can be cropped later.
        for (src, dest) in [("gfx/ui/achievement", "achievements")] {
            let from = resources.appending(path: src)
            let to = Self.harvestDir.appending(path: dest)
            try? fm.createDirectory(at: to, withIntermediateDirectories: true)
            if let e = fm.enumerator(at: from, includingPropertiesForKeys: nil) {
                for case let url as URL in e where url.pathExtension.lowercased() == "png" {
                    try? fm.copyItem(
                        at: url, to: to.appending(path: url.lastPathComponent.lowercased()))
                    copied += 1
                }
            }
        }
        copied += harvestMonsterArt(resources: resources)
        copied += harvestPocketArt(resources: resources)

        for kind in ["collectibles", "trinkets"] {
            let dir = resources.appending(path: "gfx/items/\(kind)")
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasSuffix(".png") {
                let dest = Self.spritesDir.appending(path: name.lowercased())
                try? fm.removeItem(at: dest)
                try? fm.copyItem(at: dir.appending(path: name), to: dest)
                copied += 1
            }
        }
        progress?("Harvested \(copied) sprites.")

        if !keepRaw {
            progress?("Cleaning up the raw extraction…")
            try? fm.removeItem(at: scratch)
        }
    }

    /// Trims a PNG to its art and squares it into a `box`-pixel sprite.
    ///
    /// The giant-book rune plates are 256x256 with the glyph floating in the middle,
    /// and the item atlas only ever takes the top-left cell of a file -- which for
    /// those is empty. Smooth interpolation here, unlike everywhere else in this file:
    /// the plates are anti-aliased artwork, not pixel art, so nearest-neighbour at 8:1
    /// would shred the outline.
    static func fitted(_ url: URL, to box: Int) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let art = Anm2.trimmed(img),
              let ctx = CGContext(
                data: nil, width: box, height: box, bitsPerComponent: 8,
                bytesPerRow: box * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        let fit = min(Double(box) / Double(art.width), Double(box) / Double(art.height))
        let w = max(1, Int(Double(art.width) * fit)), h = max(1, Int(Double(art.height) * fit))
        ctx.draw(art, in: CGRect(x: (box - w) / 2, y: (box - h) / 2, width: w, height: h))
        return ctx.makeImage().flatMap {
            NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:])
        }
    }

    /// Renders one still frame per entity and writes it as its own PNG.
    ///
    /// The sheet cannot be guessed from the entity name: only 49 of the 229 files in
    /// gfx/monsters are named after their type/variant, and all 133 bosses live in
    /// gfx/bosses. The chain that does work is
    /// `entity@anm2path -> the .anm2 -> its <Spritesheet Path=...>`.
    ///
    /// Cropping a fixed square out of that sheet does not work either -- see Anm2 --
    /// so the frame is composited from the anm2's own crop rectangles instead.
    private func harvestMonsterArt(resources: URL) -> Int {
        let fm = FileManager.default
        let gfx = resources.appending(path: "gfx")
        guard let xml = try? String(contentsOf: resources.appending(path: "entities2.xml"),
                                    encoding: .utf8) else { return 0 }

        var anm2: [String: URL] = [:]          // basename -> file
        var pngs: [String: URL] = [:]          // path relative to gfx/ -> file
        if let e = fm.enumerator(at: gfx, includingPropertiesForKeys: nil) {
            for case let url as URL in e {
                switch url.pathExtension.lowercased() {
                case "anm2": anm2[url.lastPathComponent.lowercased()] = url
                case "png":
                    let rel = url.path.replacingOccurrences(of: gfx.path + "/", with: "")
                    pngs[rel.lowercased()] = url
                default: break
                }
            }
        }
        // Sheet paths inside an anm2 use Windows separators and are relative to gfx/.
        let resolve: (String) -> URL? = { path in
            pngs[path.replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .lowercased()]
        }

        try? fm.removeItem(at: Self.monsterArtDir)
        try? fm.createDirectory(at: Self.monsterArtDir, withIntermediateDirectories: true)
        var index: [String: String] = [:]
        var rendered: [String: Bool] = [:]     // anm2 basename -> produced a frame
        let entity = try! NSRegularExpression(pattern: #"<entity\b([^>]*)>"#)
        let attr = try! NSRegularExpression(pattern: #"(\w+)\s*=\s*"([^"]*)""#)

        for m in entity.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            guard let r = Range(m.range(at: 1), in: xml) else { continue }
            let body = String(xml[r])
            var a: [String: String] = [:]
            for am in attr.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let k = Range(am.range(at: 1), in: body),
                      let v = Range(am.range(at: 2), in: body) else { continue }
                a[String(body[k])] = String(body[v])
            }
            guard let type = a["id"], let variant = a["variant"], let path = a["anm2path"]
            else { continue }
            let name = (path as NSString).lastPathComponent.lowercased()
            guard let file = anm2[name] else { continue }
            let key = ((name as NSString).deletingPathExtension) + ".png"

            if rendered[name] == nil {
                var ok = false
                // The idle, laid out as one horizontal strip so CSS can step through it
                // and the sprite moves the way it does in game. Every frame is padded
                // into the same box and every strip to the same length -- otherwise a
                // bobbing enemy jitters as each frame's tight crop changes size, and
                // the atlas cell stops lining up with the step width.
                let fs = Anm2.frames(of: file, limit: Self.monsterFrames, resolve: resolve)
                if let strip = Anm2.strip(fs, count: Self.monsterFrames),
                   let png = NSBitmapImageRep(cgImage: strip)
                       .representation(using: .png, properties: [:]) {
                    try? png.write(to: Self.monsterArtDir.appending(path: key))
                    ok = true
                }
                rendered[name] = ok
            }
            if rendered[name] == true { index["\(type).\(variant)"] = key }
        }
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: Self.monsterArtIndex)
        }
        return rendered.values.filter { $0 }.count
    }


    /// Slices the card faces out of the HUD sheet, and takes one pill pickup.
    ///
    /// Cards and pills are the only items with no sprite of their own: items.xml never
    /// names one, which is why 101 of them rendered as an empty box. The faces do exist
    /// in `gfx/ui/ui_cardfronts.png`, and pocketitems.xml gives each card a `hud`
    /// attribute ("23_TwoOfHearts") -- but the number in it is NOT the cell index. The
    /// sheet is an 8x6 grid of 16x24 cells with four holes in it, and 2 of Hearts is at
    /// cell 4, not 23. Reading the index as a cell handed those cards an empty crop.
    ///
    /// `ui_cardfronts.anm2` is the mapping: one animation per card, named exactly like
    /// the `hud` attribute, whose single frame carries the real crop rect.
    ///
    /// Pills get one shared icon on purpose. A pill effect has no fixed appearance: the
    /// game shuffles which colour carries which effect every run, so picking a colour
    /// per effect would invent a mapping the game does not have.
    private func harvestPocketArt(resources: URL) -> Int {
        let fm = FileManager.default
        let cardAnm2 = resources.appending(path: "gfx/ui/ui_cardfronts.anm2")
        guard let xml = try? String(
                contentsOf: resources.appending(path: "pocketitems.xml"), encoding: .utf8),
              fm.fileExists(atPath: cardAnm2.path)
        else { return 0 }
        // The anm2 names its sheet relative to its own folder, not to gfx/.
        let resolve: (String) -> URL? = { path in
            resources.appending(
                path: "gfx/ui/" + (path.replacingOccurrences(of: "\\", with: "/")
                    as NSString).lastPathComponent)
        }

        let card = try! NSRegularExpression(pattern: #"<(?:card|rune)\b([^>]*)/>"#)
        let attr = try! NSRegularExpression(pattern: #"(\w+)\s*=\s*"([^"]*)""#)
        var written = 0

        for m in card.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            guard let r = Range(m.range(at: 1), in: xml) else { continue }
            let body = String(xml[r])
            var a: [String: String] = [:]
            for am in attr.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let k = Range(am.range(at: 1), in: body),
                      let v = Range(am.range(at: 2), in: body) else { continue }
                a[String(body[k])] = String(body[v])
            }
            guard let id = a["id"], let hud = a["hud"],
                  let face = Anm2.firstFrame(of: cardAnm2, resolve: resolve, named: hud),
                  let png = NSBitmapImageRep(cgImage: face)
                      .representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: Self.spritesDir.appending(path: "card_\(id).png"))
            written += 1
        }

        // Runes carry no `hud`, so the loop above skips them and they would show a
        // blank tile. Their glyphs do exist, as the full-screen plates the giant book
        // shows on pickup -- one per named rune, and the only art that tells them
        // apart (on the floor every rune is the same grey stone).
        let book = resources.appending(path: "gfx/ui/giantbook")
        var glyphs: [String: URL] = [:]        // "hagal" -> plate
        if let names = try? fm.contentsOfDirectory(atPath: book.path) {
            for n in names where n.hasPrefix("rune_") {
                // rune_07_berkand.png is the plate for Berkano -- the file name is
                // misspelled in the game, so match on a prefix rather than equality.
                let stem = ((n as NSString).deletingPathExtension)
                    .split(separator: "_").last.map(String.init) ?? n
                glyphs[String(stem.prefix(5)).lowercased()] = book.appending(path: n)
            }
        }
        // Blank and Black Rune have no plate; they fall back to the card pickup.
        let generic = try? Data(
            contentsOf: resources.appending(path: "gfx/items/pick ups/pickup_017_card.png"))
        for m in card.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            guard let r = Range(m.range(at: 1), in: xml) else { continue }
            let body = String(xml[r])
            var a: [String: String] = [:]
            for am in attr.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let k = Range(am.range(at: 1), in: body),
                      let v = Range(am.range(at: 2), in: body) else { continue }
                a[String(body[k])] = String(body[v])
            }
            guard let id = a["id"], id != "0" else { continue }
            let dest = Self.spritesDir.appending(path: "card_\(id).png")
            guard !fm.fileExists(atPath: dest.path) else { continue }
            let key = String((a["name"] ?? "").prefix(5)).lowercased()
            if let plate = glyphs[key], let png = Self.fitted(plate, to: 32) {
                try? png.write(to: dest)
            } else if let generic {
                try? generic.write(to: dest)
            } else { continue }
            written += 1
        }

        // The pill pickup is a 4x8 grid of 32px frames -- every colour the game can
        // deal. A pill EFFECT has no fixed colour (the game reshuffles which colour
        // carries which effect each run), so instead of picking one, the icon cycles
        // through them. Laid out as one horizontal strip so CSS can step through it.
        let pill = resources.appending(path: "gfx/items/pick ups/pickup_007_pill.png")
        if let data = try? Data(contentsOf: pill),
           let grid = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let cell = 32
            var frames: [CGImage] = []
            for row in 0..<(grid.height / cell) {
                for col in 0..<(grid.width / cell) {
                    let r = CGRect(x: col * cell, y: row * cell, width: cell, height: cell)
                    guard let c = grid.cropping(to: r), Anm2.trimmed(c) != nil else { continue }
                    frames.append(c)
                }
            }
            // The last few cells of that sheet are runes and glow effects, not pills.
            frames = Array(frames.prefix(13))
            if let first = frames.first,
               let png = NSBitmapImageRep(cgImage: first)
                   .representation(using: .png, properties: [:]) {
                try? png.write(to: Self.spritesDir.appending(path: "pill.png"))
                written += 1
            }
            if let ctx = CGContext(
                data: nil, width: cell * frames.count, height: cell, bitsPerComponent: 8,
                bytesPerRow: cell * frames.count * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .none
                for (i, f) in frames.enumerated() {
                    ctx.draw(f, in: CGRect(x: i * cell, y: 0, width: cell, height: cell))
                }
                if let out = ctx.makeImage(),
                   let png = NSBitmapImageRep(cgImage: out)
                       .representation(using: .png, properties: [:]) {
                    try? png.write(to: Self.harvestDir.appending(path: "pills_strip.png"))
                    written += 1
                }
            }
        }
        return written
    }
}
