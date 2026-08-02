import AppKit
import Foundation
import IsaacCore

/// Packs the item sprites into one PNG plus an index.
///
/// ~700 individual 4 KB PNGs cost far more than their pixels: each burns a whole
/// filesystem block and its own PNG header, and the browser would issue 700 separate
/// file loads. One sheet is smaller on disk, loads once, and gives the phase-3
/// template matcher a single image to slice from.
public struct Atlas {
    public struct Entry: Codable, Sendable {
        public var key: String      // the item's `gfx` filename
        public var x: Int
        public var y: Int
        public var w: Int
        public var h: Int
    }

    public struct Index: Codable, Sendable {
        public var width: Int
        public var height: Int
        public var cell: Int
        /// Cells are not always square: an achievement badge is 263x176. Optional so a
        /// previously written index still decodes; both fall back to `cell`.
        public var cellW: Int?
        public var cellH: Int?
        /// How many animation frames sit side by side inside one cell. 1 means the
        /// cell is a still; the enemy sheet packs a short idle loop into each.
        public var steps: Int?
        public var entries: [Entry]

        public init(
            width: Int, height: Int, cell: Int,
            cellW: Int? = nil, cellH: Int? = nil, steps: Int? = nil, entries: [Entry]
        ) {
            self.width = width; self.height = height; self.cell = cell
            self.cellW = cellW; self.cellH = cellH; self.steps = steps
            self.entries = entries
        }
    }

    /// Sprites are laid out on a fixed grid. Isaac's collectible sprites are all
    /// 32x32, but a couple of oddities exist, so anything larger is skipped rather
    /// than silently clipped.
    public static func build(
        sprites: [(key: String, url: URL)], cell: Int = 32
    ) -> (png: Data, index: Index)? {
        guard !sprites.isEmpty else { return nil }
        let columns = Int(Double(sprites.count).squareRoot().rounded(.up))
        let rows = Int((Double(sprites.count) / Double(columns)).rounded(.up))
        let width = columns * cell
        let height = rows * cell

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        var entries: [Entry] = []
        for (i, sprite) in sprites.enumerated() {
            guard let image = NSImage(contentsOf: sprite.url),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { continue }
            // Sprite sheets wider/taller than one cell are animation strips. Draw the
            // FIRST frame at native size rather than squashing the whole strip into the
            // cell -- monkeypaw (128x32) is the one AB+ case and rendered as 4 tiny
            // frames crammed together.
            let sourceRect = CGRect(
                x: 0, y: max(0, cg.height - cell), width: min(cell, cg.width),
                height: min(cell, cg.height))
            let frame = cg.cropping(to: sourceRect) ?? cg
            let col = i % columns
            let row = i / columns
            let x = col * cell
            // CGContext's origin is bottom-left; the index is top-left so the web
            // layer can use it directly as a CSS background offset.
            let yTop = row * cell
            let yBottom = height - yTop - cell
            // Centred, not corner-anchored. Almost every collectible is exactly one
            // cell, but a card face is 16x24 -- drawn from the corner it hangs off the
            // bottom-left of its tile while every neighbour is centred. No integer
            // upscale fits (2x is 48 tall), so it stays native size and is placed.
            context.draw(
                frame,
                in: CGRect(
                    x: x + (cell - frame.width) / 2,
                    y: yBottom + (cell - frame.height) / 2,
                    width: frame.width, height: frame.height))
            entries.append(Entry(key: sprite.key, x: x, y: yTop, w: cell, h: cell))
        }

        guard let cgImage = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (png, Index(width: width, height: height, cell: cell, entries: entries))
    }
}

/// Names the dominant colours of each sprite, so the website can answer "grey items".
///
/// The reference site (thefindingofisaac) lets you *describe* an item rather than name
/// it. Colour is the half of that no text source provides — EID describes what an item
/// DOES, never what it looks like — so it is measured off the pixels instead.
public enum SpriteColors {
    /// Coarse on purpose. People search "grey", not "slate"; a fine-grained vocabulary
    /// would split one intuitive query across several buckets.
    static let vocabulary: [(name: String, hue: ClosedRange<Double>)] = [
        ("red",    0...12), ("orange", 12...40), ("gold",  40...62),
        ("yellow", 62...70), ("green",  70...160), ("teal", 160...195),
        ("blue",   195...255), ("purple", 255...290), ("pink", 290...345),
        ("red",    345...360),
    ]

    public static func names(for image: CGImage) -> [String] {
        let w = min(image.width, 32), h = min(image.height, 32)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var tally: [String: Int] = [:]
        var opaque = 0
        var dark = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Double(px[i + 3]) / 255
            guard a > 0.55 else { continue }          // ignore the transparent surround
            opaque += 1
            let r = Double(px[i]) / 255 / max(a, 0.001)
            let g = Double(px[i + 1]) / 255 / max(a, 0.001)
            let b = Double(px[i + 2]) / 255 / max(a, 0.001)
            let mx = max(r, g, b), mn = min(r, g, b)
            let light = (mx + mn) / 2
            // Every Isaac sprite is drawn with a dark outline and dark shading. Counting
            // those made "brown" match 95% of the catalogue, which is worse than no tag
            // at all -- a search term that matches everything discriminates nothing.
            if light < 0.24 { dark += 1; continue }
            let sat = mx == mn ? 0 : (light > 0.5 ? (mx - mn) / (2 - mx - mn) : (mx - mn) / (mx + mn))

            // Achromatic first: a desaturated pixel has no meaningful hue, and letting
            // one through would tag every grey sprite with a random colour.
            if sat < 0.16 {
                // light is >= 0.24 here, so "black" is handled after the loop instead.
                tally[light > 0.82 ? "white" : "grey", default: 0] += 1
                continue
            }
            var hue: Double
            if mx == r { hue = (g - b) / (mx - mn) } else if mx == g { hue = 2 + (b - r) / (mx - mn) }
            else { hue = 4 + (r - g) / (mx - mn) }
            hue = (hue * 60).truncatingRemainder(dividingBy: 360)
            if hue < 0 { hue += 360 }
            var name = vocabulary.first { $0.hue.contains(hue) }?.name ?? "grey"
            // Dark warm hues read as brown to a person, not as dark orange.
            if (name == "orange" || name == "gold" || name == "red") && light < 0.38 { name = "brown" }
            if name == "red" && light > 0.7 && sat < 0.55 { name = "pink" }
            tally[name, default: 0] += 1
        }
        guard opaque > 0 else { return [] }
        // Only colours covering >=16% of the sprite. Below that it is trim, and
        // returning it would make the search noisy.
        let named = tally
            .filter { Double($0.value) / Double(opaque) >= 0.16 }
            .sorted { $0.value > $1.value }
            .map(\.key)
        // Discarding the dark pixels is what stops every sprite reading as "brown",
        // but it also means a genuinely black sprite -- Satan, Death's Head -- comes
        // back with no tag at all and cannot be found by description. If that is what
        // the sprite mostly is, say so.
        if named.isEmpty && Double(dark) / Double(opaque) > 0.5 { return ["black"] }
        return named
    }
}

/// Builds icon atlases for achievements and enemies.
///
/// Achievement badges are plain single PNGs. Monster art is animation SHEETS laid out
/// as a grid, so a representative frame has to be cropped: the file name encodes
/// `TYPE.VARIANT`, which joins straight to entities2.xml.
public enum IconAtlas {
    /// (key -> image) into one sheet.
    ///
    /// Sources vary wildly in size -- a composited enemy is anywhere from 16px to
    /// 435px, a badge is 263x176 -- so each is fitted into the cell rather than
    /// stretched to it. The previous version drew every image at exactly `cell` x
    /// `cell`, which squashed the 3:2 badges by 33% and made their lettering
    /// unreadable.
    ///
    /// Enlargement is clamped to a whole-number factor. Pixel art scaled by 4.7x
    /// lands off the pixel grid and some rows come out a pixel taller than their
    /// neighbours; 4x does not.
    public static func build(
        _ images: [(key: String, image: CGImage)], cell: Int = 32,
        cellW: Int? = nil, cellH: Int? = nil, steps: Int? = nil
    ) -> (png: Data, index: Atlas.Index)? {
        guard !images.isEmpty else { return nil }
        let cw = cellW ?? cell, ch = cellH ?? cell
        let columns = Int(Double(images.count).squareRoot().rounded(.up))
        let rows = Int((Double(images.count) / Double(columns)).rounded(.up))
        let width = columns * cw, height = rows * ch
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none

        var entries: [Atlas.Entry] = []
        for (i, item) in images.enumerated() {
            let col = i % columns, row = i / columns
            let x = col * cw
            let yTop = row * ch

            let fit = min(Double(cw) / Double(item.image.width),
                          Double(ch) / Double(item.image.height))
            let scale = fit >= 1 ? fit.rounded(.down) : fit
            let dw = max(1, Int((Double(item.image.width) * scale).rounded(.down)))
            let dh = max(1, Int((Double(item.image.height) * scale).rounded(.down)))
            let ox = x + (cw - dw) / 2
            let oy = height - yTop - ch + (ch - dh) / 2
            ctx.draw(item.image, in: CGRect(x: ox, y: oy, width: dw, height: dh))
            entries.append(Atlas.Entry(key: item.key, x: x, y: yTop, w: cw, h: ch))
        }
        guard let out = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: out)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (png, Atlas.Index(
            width: width, height: height, cell: cell,
            cellW: cw, cellH: ch, steps: steps, entries: entries))
    }

    public static func load(_ url: URL) -> CGImage? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
