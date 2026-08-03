import CoreGraphics
import Foundation

/// Names the pill in the pocket slot by its colour.
///
/// Deliberately not SpriteMatcher. That compares shape through zero-mean normalised
/// cross-correlation on grayscale, which is exactly the wrong tool here: all thirteen
/// pills are the same capsule, and subtracting the mean and dividing by the norm throws
/// away the only thing that tells them apart. Two pills that differ solely in hue score
/// identically under NCC.
///
/// So this compares colour directly, per pixel, over the template's own alpha mask --
/// the background behind the sprite is whatever room the player is standing in and must
/// not be part of the comparison.
///
/// What this can and cannot know: it reads the pill's COLOUR. Which effect that colour
/// carries is reshuffled by the game every run and is written down nowhere the app can
/// reach, so the colour is the answer, and the effect has to be learned once per run.
public struct PillReader: Sendable {

    /// One pill colour, prepared once.
    public struct Template: Sendable {
        public let index: Int
        /// Row-major RGB, 0...1, `side * side` entries.
        public let rgb: [SIMD3<Float>]
        /// True where the sprite is opaque. Comparisons only look here.
        public let mask: [Bool]
        public let opaqueCount: Int
    }

    public struct Match: Sendable, Equatable {
        public let index: Int
        /// 1 is a perfect colour match, 0 is the worst possible. See `confidenceFloor`.
        public let score: Double
        public init(index: Int, score: Double) {
            self.index = index
            self.score = score
        }
    }

    /// Below this, say nothing. An empty pocket slot and a dark room both produce a
    /// best-of-thirteen that means nothing, and naming a pill wrongly is worse than
    /// naming none -- the whole point is to stop the player guessing.
    public static let confidenceFloor = 0.82

    /// Templates are square; this is their side in pixels. Small on purpose: pill sprites
    /// are a handful of flat colour blocks, so more resolution adds cost and no signal.
    public static let side = 16

    public let templates: [Template]

    public init(templates: [Template]) {
        self.templates = templates
    }

    /// Slices the harvested strip (one row of square cells) into one template per colour.
    public init?(strip: CGImage) {
        let h = strip.height
        guard h > 0, strip.width % h == 0 else { return nil }
        let count = strip.width / h
        var built: [Template] = []
        for i in 0..<count {
            guard let cell = strip.cropping(
                to: CGRect(x: i * h, y: 0, width: h, height: h)),
                let t = Self.template(index: i, from: cell)
            else { continue }
            built.append(t)
        }
        guard !built.isEmpty else { return nil }
        self.templates = built
    }

    static func template(index: Int, from image: CGImage) -> Template? {
        guard let (rgb, alpha) = Self.rgba(image, side: Self.side) else { return nil }
        let mask = alpha.map { $0 > 0.5 }
        let opaque = mask.filter { $0 }.count
        // A cell that is entirely transparent would match any background perfectly.
        guard opaque >= 8 else { return nil }
        return Template(index: index, rgb: rgb, mask: mask, opaqueCount: opaque)
    }

    /// Resamples to `side` x `side` and returns straight (un-premultiplied) RGB plus alpha.
    ///
    /// Nearest-neighbour: these are pixel-art sprites a few pixels across, and smoothing
    /// them blends the two halves of a two-tone pill into one average that no longer
    /// distinguishes it from its neighbours on the strip.
    public static func rgba(_ image: CGImage, side: Int) -> ([SIMD3<Float>], [Float])? {
        let count = side * side
        var buffer = [UInt8](repeating: 0, count: count * 4)
        guard let ctx = CGContext(
            data: &buffer, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        var rgb = [SIMD3<Float>](repeating: .zero, count: count)
        var alpha = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let a = Float(buffer[i * 4 + 3]) / 255
            alpha[i] = a
            guard a > 0 else { continue }
            // The context is premultiplied, so undo it before comparing colours --
            // otherwise a semi-transparent edge pixel reads as a darker shade.
            rgb[i] = SIMD3<Float>(
                Float(buffer[i * 4 + 0]) / 255 / a,
                Float(buffer[i * 4 + 1]) / 255 / a,
                Float(buffer[i * 4 + 2]) / 255 / a)
        }
        return (rgb, alpha)
    }

    /// Scores one prepared candidate against every template, best first.
    public func scores(candidate: [SIMD3<Float>]) -> [Match] {
        templates.compactMap { t -> Match? in
            guard t.opaqueCount > 0 else { return nil }
            var total: Float = 0
            for i in 0..<t.rgb.count where t.mask[i] {
                let d = t.rgb[i] - candidate[i]
                // Euclidean in RGB. Crude as colour science, but these are thirteen
                // flat, saturated, well-separated sprites, not a photograph.
                total += (d * d).sum().squareRoot()
            }
            // sqrt(3) is the largest possible distance between two RGB points.
            let mean = total / Float(t.opaqueCount) / Float(3.0.squareRoot())
            return Match(index: t.index, score: Double(1 - mean))
        }
        .sorted { $0.score > $1.score }
    }

    /// Reads a tight crop -- one pill, filling the frame.
    public func match(_ crop: CGImage) -> Match? {
        guard let (rgb, _) = Self.rgba(crop, side: Self.side) else { return nil }
        guard let best = scores(candidate: rgb).first,
              best.score >= Self.confidenceFloor else { return nil }
        return best
    }

    /// Finds the best pill anywhere in a larger image, by sliding a square window.
    ///
    /// Used because the pocket slot's position depends on the window size and the HUD's
    /// own scaling, and searching a small region is more robust than hardcoding a
    /// rectangle that is one patch away from being wrong.
    ///
    /// - Parameter window: the side of the search window, in `haystack` pixels. Should be
    ///   roughly the on-screen size of a pill.
    public func best(in haystack: CGImage, window: Int, stride: Int = 2)
        -> (match: Match, rect: CGRect)?
    {
        guard window > 0, stride > 0,
              haystack.width >= window, haystack.height >= window else { return nil }
        var bestFound: (match: Match, rect: CGRect)?
        for y in Swift.stride(from: 0, through: haystack.height - window, by: stride) {
            for x in Swift.stride(from: 0, through: haystack.width - window, by: stride) {
                let rect = CGRect(x: x, y: y, width: window, height: window)
                guard let crop = haystack.cropping(to: rect),
                      let (rgb, _) = Self.rgba(crop, side: Self.side),
                      let top = scores(candidate: rgb).first
                else { continue }
                if bestFound == nil || top.score > bestFound!.match.score {
                    bestFound = (top, rect)
                }
            }
        }
        guard let found = bestFound, found.match.score >= Self.confidenceFloor else { return nil }
        return found
    }
}
