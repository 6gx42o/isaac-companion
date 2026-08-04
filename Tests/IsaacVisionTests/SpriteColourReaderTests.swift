import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import IsaacVision

/// The harvested strip, if this machine has built its data. These tests run against the
/// real sprites rather than invented ones -- a pill reader that works on synthetic
/// swatches and not on the game's actual art would be worthless.
private func loadStrip() -> CGImage? {
    let url = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: "Library/Application Support/IsaacCompanion/data/abplus/pills.png")
    guard FileManager.default.fileExists(atPath: url.path),
          let src = CGImageSourceCreateWithURL(url as CFURL, nil)
    else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

private let strip = loadStrip()

@Suite("SpriteColourReader", .enabled(if: strip != nil, "no built data on this machine"))
struct SpriteColourReaderTests {

    @Test("the strip yields one template per colour")
    func slices() throws {
        let sheet = try #require(strip)
        let reader = try #require(SpriteColourReader(strip: sheet))
        #expect(reader.templates.count == 13, "AB+ deals thirteen pill colours")
        for t in reader.templates {
            #expect(t.opaqueCount > 8, "colour \(t.index) is nearly empty")
        }
    }

    /// The test that matters. Every colour must identify as ITSELF when shown its own
    /// sprite -- and the runner-up must be clearly behind, or the reader is guessing
    /// between two pills that happen to share a hue.
    @Test("every colour identifies as itself, with daylight to the runner-up")
    func eachColourIsItself() throws {
        let full = try #require(strip)
        let reader = try #require(SpriteColourReader(strip: full))
        let cell = full.height

        for i in 0..<reader.templates.count {
            let crop = try #require(
                full.cropping(to: CGRect(x: i * cell, y: 0, width: cell, height: cell)))
            // Trimmed, because that is what a correctly-sized search window contains:
            // the sprite filling the frame, not a padded atlas cell around it.
            let prepared = SpriteColourReader.rgba(
                SpriteColourReader.trimmed(crop),
                width: SpriteColourReader.pillSide, height: SpriteColourReader.pillSide)
            let rgb = try #require(prepared?.0, "could not read colour \(i)")
            let ranked = reader.scores(candidate: rgb)

            #expect(ranked.first?.index == i, "colour \(i) matched \(ranked.first?.index ?? -1)")
            #expect(
                (ranked.first?.score ?? 0) > 0.99,
                "colour \(i) should match itself almost exactly, got \(ranked.first?.score ?? 0)")
            // Separation, not just a win: a 0.001 lead would mean the next dark room
            // flips the answer.
            let gap = (ranked.first?.score ?? 0) - (ranked.dropFirst().first?.score ?? 0)
            #expect(gap > 0.02, "colour \(i) leads its runner-up by only \(gap)")
        }
    }

    /// The pocket slot is somewhere in a much larger frame, so the search has to find the
    /// pill without being told where it is.
    @Test("finds a pill placed in a larger frame")
    func findsInAFrame() throws {
        let full = try #require(strip)
        let reader = try #require(SpriteColourReader(strip: full))
        let cell = full.height
        let wanted = 6

        // A 200x140 "screen" of flat room-floor brown with one pill dropped into it.
        let W = 200, H = 140, at = CGPoint(x: 132, y: 84)
        let made = CGContext(
            data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        let ctx = try #require(made)
        ctx.setFillColor(CGColor(red: 0.42, green: 0.31, blue: 0.24, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.interpolationQuality = .none
        let padded = try #require(
            full.cropping(to: CGRect(x: wanted * cell, y: 0, width: cell, height: cell)))
        // The game draws the ART, not the padded atlas cell it is filed in, so the
        // fixture must too -- otherwise the search window frames 17px of pill inside
        // 32px of nothing and matches a template that is all pill.
        let sprite = SpriteColourReader.trimmed(padded)
        ctx.draw(
            sprite,
            in: CGRect(x: at.x, y: at.y, width: CGFloat(sprite.width), height: CGFloat(sprite.height)))
        let haystack = try #require(ctx.makeImage())

        // The window bounds the drawn art: pill sprites trim to about 17x17.
        let search = reader.best(in: haystack, windowW: 17, windowH: 17, stride: 1)
        let found = try #require(search, "found no pill at all")
        #expect(found.match.index == wanted, "found colour \(found.match.index)")
        // And roughly where it was put, not somewhere else that happened to score well.
        #expect(abs(found.rect.origin.x - at.x) <= 8, "x was \(found.rect.origin.x)")
    }

    /// The pocket slot is empty most of the time, and a reader that always answers is
    /// worse than one that admits it cannot see a pill.
    @Test("plain floor is not a pill")
    func emptyFrameSaysNothing() throws {
        let sheet = try #require(strip)
        let reader = try #require(SpriteColourReader(strip: sheet))
        let W = 120, H = 90
        let made = CGContext(
            data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        let ctx = try #require(made)
        ctx.setFillColor(CGColor(red: 0.42, green: 0.31, blue: 0.24, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let empty = try #require(ctx.makeImage())
        #expect(reader.best(in: empty, windowW: 32, windowH: 32, stride: 8) == nil, "named a pill on bare floor")
    }
}
