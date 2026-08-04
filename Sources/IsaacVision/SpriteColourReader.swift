import CoreGraphics
import Foundation

/// Identifies a small sprite by its colours -- the pill or the card in the pocket slot.
///
/// Deliberately not SpriteMatcher. That compares shape through zero-mean normalised
/// cross-correlation on grayscale, and for both of these jobs colour IS the signal:
///
///  - All thirteen pills are the same capsule. Subtracting the mean and dividing by the
///    norm throws away the only thing that tells them apart, so two pills differing
///    solely in hue score identically under NCC.
///  - Cards differ by artwork, but the pairs most easily confused differ by colour --
///    2 of Hearts against 2 of Spades is the same pip in red and black.
///
/// So this compares colour directly, per pixel, over the template's own alpha mask: the
/// background behind the sprite is whatever room the player is standing in, and must not
/// be part of the comparison.
public struct SpriteColourReader: Sendable {

    /// One pill colour, prepared once.
    public struct Template: Sendable {
        public let index: Int
        /// Row-major RGB, 0...1, `side * side` entries.
        public let rgb: [SIMD3<Float>]
        /// True where the sprite is opaque. Comparisons only look here.
        public let mask: [Bool]
        public let opaqueCount: Int
        /// Masked luminance with the mask's mean removed, and its norm -- the sprite's
        /// light/dark PATTERN, separated from its colours. See `scores`.
        public let lumCentred: [Float]
        public let lumNorm: Float
    }

    public struct Match: Sendable, Equatable {
        public let index: Int
        /// 1 is a perfect colour match, 0 is the worst possible. See `confidenceFloor`.
        public let score: Double
    }

    /// Below this, say nothing. An empty pocket slot and a dark room both produce a
    /// best-of-N that means nothing, and naming the wrong card is worse than naming none
    /// -- the whole point is to stop the player guessing.
    ///
    /// Calibrated to the two-term score. A genuine sighting that is resampled and a
    /// pixel or two off lands around 0.78-0.9 (colour high, structure merely good);
    /// the worst adversarial case measured -- a dark window with a stray bright sliver
    /// preferring the almost-black card -- lands at 0.57, because structural agreement
    /// is absent and the colour term is capped at 0.6 of the score. 0.72 sits between
    /// with margin on both sides. The old floor of 0.82 belonged to the colour-only
    /// metric and would reject real sightings under the new one.
    public static let confidenceFloor = 0.72

    /// A candidate window flatter than this cannot be a sprite, whatever it scores.
    ///
    /// Found live, first session: A Card Against Humanity is an almost entirely black
    /// card, so a window of flat black room background matched it at 0.92 and an empty
    /// pocket slot was announced as that card. Colour distance cannot tell "the same
    /// flat colour" from "the same sprite" -- but a real sprite always has edges, so
    /// the mean squared deviation from the window's own mean colour separates the two
    /// cleanly. Flat black measures ~0.0; the dimmest real sprite an order of
    /// magnitude above this.
    public static let candidateVarianceFloor: Float = 0.0025

    /// Templates are square; this is their side in pixels. Pills are a handful of flat
    /// colour blocks and need very little; cards carry actual artwork and need more.
    /// Pills: flat colour blocks, so very little resolution is needed.
    public static let pillSide = 16
    /// Cards: real artwork, and the confusable pairs differ in small details.
    public static let cardSide = 28

    public let side: Int
    public let templates: [Template]

    public init(side: Int, templates: [Template]) {
        self.side = side
        self.templates = templates
    }

    /// Builds from arbitrary sprites, keyed by whatever id the caller wants back --
    /// a card id, a pill colour index.
    public init?(side: Int, sprites: [(id: Int, image: CGImage)]) {
        let built = sprites.compactMap {
            Self.template(index: $0.id, from: $0.image, side: side)
        }
        guard !built.isEmpty else { return nil }
        self.side = side
        self.templates = built
    }

    /// Slices a harvested strip (one row of square cells) into one template per cell.
    public init?(strip: CGImage, side: Int = 16) {
        let h = strip.height
        guard h > 0, strip.width % h == 0 else { return nil }
        let count = strip.width / h
        var built: [Template] = []
        for i in 0..<count {
            guard let cell = strip.cropping(
                to: CGRect(x: i * h, y: 0, width: h, height: h)),
                let t = Self.template(index: i, from: cell, side: side)
            else { continue }
            built.append(t)
        }
        guard !built.isEmpty else { return nil }
        self.side = side
        self.templates = built
    }

    static func template(index: Int, from image: CGImage, side: Int) -> Template? {
        guard let (rgb, alpha) = Self.rgba(image, side: side) else { return nil }
        let mask = alpha.map { $0 > 0.5 }
        let opaque = mask.filter { $0 }.count
        // A cell that is entirely transparent would match any background perfectly.
        guard opaque >= 8 else { return nil }
        let (lum, norm) = Self.centredLuminance(rgb, mask: mask, count: opaque)
        return Template(
            index: index, rgb: rgb, mask: mask, opaqueCount: opaque,
            lumCentred: lum, lumNorm: norm)
    }

    /// Luminance over the mask with the masked mean removed. Off-mask entries are zero,
    /// so a plain dot product over the whole array correlates only where the sprite is.
    static func centredLuminance(
        _ rgb: [SIMD3<Float>], mask: [Bool], count: Int
    ) -> ([Float], Float) {
        let weights = SIMD3<Float>(0.299, 0.587, 0.114)
        var lum = [Float](repeating: 0, count: rgb.count)
        var mean: Float = 0
        for i in rgb.indices where mask[i] {
            lum[i] = (rgb[i] * weights).sum()
            mean += lum[i]
        }
        mean /= Float(max(count, 1))
        var norm: Float = 0
        for i in rgb.indices where mask[i] {
            lum[i] -= mean
            norm += lum[i] * lum[i]
        }
        return (lum, norm.squareRoot())
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
    ///
    /// Two terms, both needed, each covering the other's blind spot:
    ///
    ///  - COLOUR: mean RGB distance over the sprite's own mask. Tells the thirteen
    ///    same-shaped pills apart, which is the reason this type exists at all.
    ///  - STRUCTURE: correlation of mask-mean-centred luminance -- does the light and
    ///    dark PATTERN of the sprite appear in the window? Found necessary live: A Card
    ///    Against Humanity is almost entirely black, so by colour alone a dark window
    ///    with any stray bright pixel preferred it over every real answer, and an empty
    ///    slot was announced as that card. Colour cannot tell flat-matches-flat from
    ///    sprite-matches-sprite; the pattern term can, because a real sighting places
    ///    the template's own bright pixels where the template has them.
    ///
    /// Weighted so that a perfect colour match with NO structural agreement lands well
    /// under `confidenceFloor`, while genuine sightings -- which agree on both -- stay
    /// comfortably above it.
    public func scores(candidate: [SIMD3<Float>]) -> [Match] {
        templates.compactMap { t -> Match? in
            guard t.opaqueCount > 0 else { return nil }
            var total: Float = 0
            for i in 0..<t.rgb.count where t.mask[i] {
                let d = t.rgb[i] - candidate[i]
                // Euclidean in RGB. Crude as colour science, but these are flat,
                // saturated, well-separated sprites, not a photograph.
                total += (d * d).sum().squareRoot()
            }
            // sqrt(3) is the largest possible distance between two RGB points.
            let meanDistance = total / Float(t.opaqueCount) / Float(3.0.squareRoot())
            let colour = Double(1 - meanDistance)

            let (candLum, candNorm) = Self.centredLuminance(
                candidate, mask: t.mask, count: t.opaqueCount)
            var structure = 0.0
            if t.lumNorm > 1e-4 && candNorm > 1e-4 {
                var dot: Float = 0
                for i in t.lumCentred.indices { dot += t.lumCentred[i] * candLum[i] }
                structure = Double(max(0, dot / (t.lumNorm * candNorm)))
            }
            return Match(index: t.index, score: colour * (0.6 + 0.4 * structure))
        }
        .sorted { $0.score > $1.score }
    }

    /// The best match plus anything indistinguishable from it.
    ///
    /// Two sprites can be byte-identical -- Blank Rune and Black Rune ship no distinct
    /// art in Afterbirth+, so both fall back to the same generic card pickup. Picking one
    /// at random would state a coin flip as fact. Returning both lets the caller say
    /// "one of these two", which is the true answer.
    public func ranked(candidate: [SIMD3<Float>], tieWithin: Double = 1e-6)
        -> (best: [Match], runnerUp: Match?)
    {
        let all = scores(candidate: candidate)
        guard let top = all.first else { return ([], nil) }
        let tied = all.prefix { top.score - $0.score <= tieWithin }
        return (Array(tied), all.dropFirst(tied.count).first)
    }

    /// Mean squared deviation of a window from its own mean colour -- the flatness test.
    static func variance(of rgb: [SIMD3<Float>]) -> Float {
        guard !rgb.isEmpty else { return 0 }
        var mean = SIMD3<Float>.zero
        for v in rgb { mean += v }
        mean /= Float(rgb.count)
        var total: Float = 0
        for v in rgb {
            let d = v - mean
            total += (d * d).sum()
        }
        return total / Float(rgb.count)
    }

    /// Finds the best pill anywhere in a larger image, by sliding a square window.
    ///
    /// Used because the pocket slot's position depends on the window size and the HUD's
    /// own scaling, and searching a small region is more robust than hardcoding a
    /// rectangle that is one patch away from being wrong.
    ///
    /// - Parameter window: the side of the search window, in `haystack` pixels. Should be
    ///   roughly the on-screen size of the sprite being looked for.
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
                      let (rgb, _) = Self.rgba(crop, side: side),
                      Self.variance(of: rgb) >= Self.candidateVarianceFloor,
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
