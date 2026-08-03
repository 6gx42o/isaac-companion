import CoreGraphics
import Foundation
import Testing

@testable import IsaacVision

/// The correlation itself, which nothing covered before -- it lived in the app's
/// executable target where no test could reach it.
///
/// These use synthetic sprites rather than real game art, deliberately: the point is to
/// pin the *properties* the algorithm is supposed to have (finds the right one, tolerates
/// lighting, refuses noise), which real art tests less clearly because a failure could
/// always be blamed on the art. A golden-image test against a real screenshot is the
/// separate question of whether the templates and the crop line up, and needs a capture
/// from a live game.
@Suite("Sprite matcher")
struct SpriteMatcherTests {
    private let side = 8

    /// A deterministic, distinctive pattern per id.
    private func pattern(_ id: Int, side: Int) -> [Float] {
        (0..<(side * side)).map { i in
            let x = i % side, y = i / side
            // Different id -> visibly different shape, not just a different brightness.
            return Float(((x * (id + 1) + y * (id + 3)) % 7)) / 6
        }
    }

    private func matcher(ids: [Int], stride: Int = 1) -> SpriteMatcher {
        SpriteMatcher(
            side: side,
            templates: ids.compactMap {
                SpriteMatcher.Template(id: $0, pixels: pattern($0, side: side))
            },
            stride: stride)
    }

    /// Places a template into the top-left of a haystack twice its size.
    private func haystack(containing id: Int, brightness: Float = 0, contrast: Float = 1)
        -> [Float] {
        let big = side * 2
        var out = [Float](repeating: 0.5, count: big * big)
        let p = pattern(id, side: side)
        for y in 0..<side {
            for x in 0..<side {
                out[y * big + x] = p[y * side + x] * contrast + brightness
            }
        }
        return out
    }

    @Test("A blank template is refused rather than matching everything")
    func flatTemplateRejected() {
        // Zero variance means the correlation denominator is zero; such a template would
        // otherwise score against anything at all.
        #expect(SpriteMatcher.Template(id: 1, pixels: [Float](repeating: 0.5, count: 64)) == nil)
        #expect(SpriteMatcher.Template(id: 1, pixels: [])  == nil)
        #expect(SpriteMatcher.Template(id: 1, pixels: pattern(1, side: 8)) != nil)
    }

    @Test("Finds the sprite that is actually there")
    func findsTheRightOne() throws {
        let m = matcher(ids: [10, 11, 12, 13])
        for wanted in [10, 11, 12, 13] {
            let hit = try #require(
                m.best(in: haystack(containing: wanted), haystackSide: side * 2),
                "nothing cleared the floor for \(wanted)")
            #expect(hit.id == wanted, "matched \(hit.id) instead of \(wanted)")
            #expect(hit.score > 0.99, "an exact copy should score ~1, got \(hit.score)")
        }
    }

    @Test("Lighting and Curse of Darkness do not change the answer")
    func brightnessAndContrastInvariant() throws {
        // This is the whole reason for zero-mean NORMALISED cross-correlation rather than
        // a plain difference: a dark room scales and offsets every pixel, and the sprite
        // is still the same sprite.
        let m = matcher(ids: [10, 11, 12])
        for (brightness, contrast) in [(Float(0.3), Float(1)), (0, 0.4), (-0.2, 0.6)] {
            let hit = try #require(
                m.best(
                    in: haystack(containing: 11, brightness: brightness, contrast: contrast),
                    haystackSide: side * 2))
            #expect(hit.id == 11, "lost the match at brightness \(brightness) contrast \(contrast)")
            #expect(hit.score > 0.99)
        }
    }

    @Test("Noise does not clear the confidence floor")
    func refusesNoise() {
        let m = matcher(ids: [10, 11, 12])
        // A fixed pseudo-random field: no template is in here, so naming one would be
        // worse than saying nothing.
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        let noise = (0..<(side * 2 * side * 2)).map { _ -> Float in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(seed >> 40) / Float(1 << 24)
        }
        let hit = m.best(in: noise, haystackSide: side * 2)
        #expect(hit == nil, "matched \(String(describing: hit)) against noise")
    }

    @Test("Scores come back sorted, best first")
    func sorted() {
        let m = matcher(ids: [10, 11, 12, 13])
        let scores = m.scores(in: haystack(containing: 12), haystackSide: side * 2)
        #expect(scores.count == 4)
        #expect(scores.first?.id == 12)
        #expect(scores == scores.sorted { $0.score > $1.score })
    }

    @Test("A mis-sized haystack is refused rather than read out of bounds")
    func rejectsWrongSizedHaystack() {
        let m = matcher(ids: [10])
        #expect(m.scores(in: [0, 1, 2], haystackSide: side * 2).isEmpty)
        // Smaller than one template: there is nowhere to slide.
        #expect(m.scores(in: [Float](repeating: 0, count: 4), haystackSide: 2).isEmpty)
    }

    @Test("Greyscale conversion produces the requested size in 0...1")
    func greyscale() throws {
        let w = 16
        var px = [UInt8](repeating: 0, count: w * w * 4)
        for i in 0..<(w * w) { px[i * 4] = UInt8(i % 256) }
        let provider = CGDataProvider(data: Data(px) as CFData)!
        let image = CGImage(
            width: w, height: w, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)!
        let grey = try #require(SpriteMatcher.grayscale(image, side: 8))
        #expect(grey.count == 64)
        #expect(grey.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(SpriteMatcher.grayscale(image, side: 0) == nil)
    }
}
