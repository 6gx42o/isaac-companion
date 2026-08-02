import AppKit
import Foundation

/// Renders a representative still frame for an entity from its `.anm2` file.
///
/// The naive approach -- crop the top-left NxN of the sprite sheet -- does not work.
/// A sheet is not a uniform grid: `Boss_Delirium.png` is 512x512 whose real frame is
/// 160x144, and the top-left 32x32 of it is empty padding. Measured over the shipped
/// atlas, that guesswork left 34 icons completely transparent and 79 more under 10%
/// opaque, so about a fifth of the bestiary had no usable art.
///
/// The `.anm2` states the answer outright. Each `<Frame>` carries `XCrop`/`YCrop`/
/// `Width`/`Height` -- the exact source rectangle in the sheet -- plus `XPosition`/
/// `YPosition` and `XPivot`/`YPivot` giving where that rectangle sits relative to the
/// entity's origin. Compositing the first frame of every visible layer therefore
/// reproduces what the game actually draws, e.g. Delirium's head *and* its eyes,
/// rather than one arbitrary corner of a texture page.
public enum Anm2 {
    private static let attr = try! NSRegularExpression(pattern: #"(\w+)\s*=\s*"([^"]*)""#)
    private static let spritesheet = try! NSRegularExpression(pattern: #"<Spritesheet\b([^>]*)/>"#)
    private static let layer = try! NSRegularExpression(pattern: #"<Layer\b([^>]*)/>"#)
    private static let animation = try! NSRegularExpression(
        pattern: #"<Animation\b([^>]*)>(.*?)</Animation>"#, options: [.dotMatchesLineSeparators])
    private static let layerAnimation = try! NSRegularExpression(
        pattern: #"<LayerAnimation\b([^>]*)>(.*?)</LayerAnimation>"#,
        options: [.dotMatchesLineSeparators])
    private static let frame = try! NSRegularExpression(pattern: #"<Frame\b([^>]*)/>"#)

    private static func attributes(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for m in attr.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let k = Range(m.range(at: 1), in: s),
                  let v = Range(m.range(at: 2), in: s) else { continue }
            out[String(s[k])] = String(s[v])
        }
        return out
    }

    private struct Part {
        var x: Int, y: Int          // top-left, relative to the entity origin
        var image: CGImage
        var alpha: Int
    }

    /// Composites up to `limit` frames of the default animation, so a sprite can move
    /// the way it does in game rather than sitting as a still. Frames share one origin
    /// box, otherwise a bobbing enemy would jitter between differently-sized crops.
    public static func frames(
        of url: URL, limit: Int, resolve: (String) -> URL?
    ) -> [CGImage] {
        var out: [CGImage] = []
        for i in 0..<limit {
            guard let img = firstFrame(of: url, resolve: resolve, frameIndex: i) else { break }
            out.append(img)
        }
        return out
    }

    /// Composites the first frame of the default animation, or of `named` when given.
    ///
    /// `resolve` maps a sheet path as written in the file -- Windows separators,
    /// relative to `gfx/` -- onto a real file.
    public static func firstFrame(
        of url: URL, resolve: (String) -> URL?, frameIndex: Int = 0, named: String? = nil
    ) -> CGImage? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let whole = NSRange(text.startIndex..., in: text)

        var sheets: [String: CGImage] = [:]
        for m in spritesheet.matches(in: text, range: whole) {
            guard let r = Range(m.range(at: 0), in: text) else { continue }
            let a = attributes(String(text[r]))
            guard let id = a["Id"], let path = a["Path"],
                  let file = resolve(path),
                  let src = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            sheets[id] = img
        }
        guard !sheets.isEmpty else { return nil }

        var layerSheet: [String: CGImage] = [:]
        var layerName: [String: String] = [:]
        for m in layer.matches(in: text, range: whole) {
            guard let r = Range(m.range(at: 0), in: text) else { continue }
            let a = attributes(String(text[r]))
            guard let id = a["Id"] else { continue }
            layerSheet[id] = sheets[a["SpritesheetId"] ?? ""]
            layerName[id] = a["Name"] ?? ""
        }

        // Try the declared default animation first, then every other block in file
        // order. Some entities render nothing on their default frame -- Satan's
        // "Appear" starts invisible, Gaper's default frame is fully cropped out --
        // and giving up there is why 21 fightable entities had no art at all.
        let defaultName = named ?? defaultAnimationName(text)
        var blocks: [String] = []
        for m in animation.matches(in: text, range: whole) {
            guard let head = Range(m.range(at: 1), in: text),
                  let inner = Range(m.range(at: 2), in: text) else { continue }
            if attributes(String(text[head]))["Name"] == defaultName {
                blocks.insert(String(text[inner]), at: 0)
            } else if named == nil {
                blocks.append(String(text[inner]))
            }
            // With `named`, only that animation is wanted -- an atlas like
            // ui_cardfronts.anm2 holds one animation per card, so falling through to
            // the next block would silently return a different card's face.
        }
        // Two passes: prefer a frame with the shadow layer dropped, but a few entities
        // ARE their shadow -- Mom Stomp's telegraph is the foot's shadow and nothing
        // else -- so fall back to keeping it rather than losing the art entirely.
        for dropShadows in [true, false] {
            for block in blocks {
                if let img = composite(
                    block, layerSheet: layerSheet, layerName: layerName,
                    dropShadows: dropShadows, frameIndex: frameIndex) {
                    return img
                }
            }
        }
        return nil
    }

    private static func composite(
        _ block: String, layerSheet: [String: CGImage], layerName: [String: String] = [:],
        dropShadows: Bool = true, frameIndex: Int = 0
    ) -> CGImage? {
        var parts: [Part] = []
        for m in layerAnimation.matches(in: block, range: NSRange(block.startIndex..., in: block)) {
            guard let head = Range(m.range(at: 1), in: block),
                  let inner = Range(m.range(at: 2), in: block) else { continue }
            let la = attributes(String(block[head]))
            if la["Visible"] == "false" { continue }
            // The engine draws entity shadows itself from entities2.xml's shadowSize,
            // so an anm2 shadow layer is a second copy. Composited into a still it is
            // an opaque black ellipse that swamps the cell and drags the colour
            // measurement to black -- Satan came out as a figure on a dark blob.
            if dropShadows, let name = layerName[la["LayerId"] ?? ""],
               name.localizedCaseInsensitiveContains("shadow") { continue }
            let innerText = String(block[inner])
            // A layer can have fewer frames than the animation; the last one holds.
            let fms = frame.matches(
                in: innerText, range: NSRange(innerText.startIndex..., in: innerText))
            guard !fms.isEmpty,
                  let fr = Range(fms[min(frameIndex, fms.count - 1)].range(at: 0), in: innerText)
            else { continue }
            let f = attributes(String(innerText[fr]))
            if f["Visible"] == "false" { continue }
            guard let w = f["Width"].flatMap(Int.init), let h = f["Height"].flatMap(Int.init),
                  w > 0, h > 0,
                  let sheet = layerSheet[la["LayerId"] ?? ""] else { continue }
            let xc = f["XCrop"].flatMap(Int.init) ?? 0
            let yc = f["YCrop"].flatMap(Int.init) ?? 0
            // A crop rect can overhang the sheet; cropping(to:) returns nil for that.
            let rect = CGRect(x: xc, y: yc, width: w, height: h)
                .intersection(CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height))
            guard !rect.isEmpty, let cropped = sheet.cropping(to: rect) else { continue }
            let dx = (f["XPosition"].flatMap(Int.init) ?? 0) - (f["XPivot"].flatMap(Int.init) ?? 0)
            let dy = (f["YPosition"].flatMap(Int.init) ?? 0) - (f["YPivot"].flatMap(Int.init) ?? 0)
            parts.append(Part(
                x: dx + Int(rect.minX) - xc, y: dy + Int(rect.minY) - yc,
                image: cropped, alpha: f["AlphaTint"].flatMap(Int.init) ?? 255))
        }
        guard !parts.isEmpty else { return nil }

        let minX = parts.map(\.x).min()!, minY = parts.map(\.y).min()!
        let maxX = parts.map { $0.x + $0.image.width }.max()!
        let maxY = parts.map { $0.y + $0.image.height }.max()!
        let width = maxX - minX, height = maxY - minY
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none
        for p in parts {
            ctx.setAlpha(CGFloat(p.alpha) / 255)
            // CGContext counts y up from the bottom; the anm2 counts it down from the top.
            let bottom = height - (p.y - minY) - p.image.height
            ctx.draw(p.image, in: CGRect(
                x: p.x - minX, y: bottom, width: p.image.width, height: p.image.height))
        }
        return ctx.makeImage().flatMap(trimmed)
    }

    private static func defaultAnimationName(_ text: String) -> String? {
        guard let r = text.range(of: #"<Animations\b[^>]*>"#, options: .regularExpression)
        else { return nil }
        return attributes(String(text[r]))["DefaultAnimation"]
    }

    /// Crops away fully transparent margins so every sprite fills its atlas cell.
    /// Layers are positioned against the entity origin, which for a flying enemy sits
    /// well below the art, so untrimmed frames carry a lot of empty space.
    public static func trimmed(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = pixels.withUnsafeMutableBytes({ buf in
            CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }   // nothing visible at all
        return image.cropping(to: CGRect(
            x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }

    /// Lays frames side by side, each normalised into an exact `box` x `box` cell.
    ///
    /// Exactness is the point: CSS steps through the strip by shifting whole cell
    /// widths, so any padding that is not identical per frame would make the sprite
    /// drift as it plays. Frames are trimmed individually, so they are centred in the
    /// box and anything larger is scaled down to fit.
    ///
    /// Short strips are padded out to `count` by holding the last frame. Every strip
    /// then has the same width, which is what lets one atlas cell size and one
    /// `steps(count)` rule serve every entity -- an entity with a one-frame idle just
    /// plays three identical frames, which looks exactly like standing still.
    public static func strip(_ frames: [CGImage], box: Int = 64, count: Int = 0) -> CGImage? {
        guard let last = frames.last else { return nil }
        let frames = frames + Array(repeating: last, count: max(0, count - frames.count))
        // nil, not `frames.first`, when the strip cannot be drawn. The caller writes
        // whatever comes back as if it were a full-width strip, so handing back one
        // un-normalised frame would be read as N frames: the colour sampler would
        // measure a third of it and the sprite would play frame/blank/blank. No art
        // at all is a visible failure; a silently wrong strip is not.
        guard frames.count * box <= 8192,
              let ctx = CGContext(
                data: nil, width: box * frames.count, height: box, bitsPerComponent: 8,
                bytesPerRow: box * frames.count * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none
        for (i, f) in frames.enumerated() {
            let fit = min(Double(box) / Double(f.width), Double(box) / Double(f.height))
            let scale = fit >= 1 ? fit.rounded(.down) : fit    // whole-number upscales only
            let w = max(1, Int((Double(f.width) * scale).rounded(.down)))
            let h = max(1, Int((Double(f.height) * scale).rounded(.down)))
            ctx.draw(f, in: CGRect(
                x: i * box + (box - w) / 2, y: (box - h) / 2, width: w, height: h))
        }
        return ctx.makeImage()
    }
}
