import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import IsaacVision

/// The real card faces, sliced from the built atlas. Cards are the easy half of the
/// pocket slot -- a face IS its identity and the game never reshuffles it -- but only if
/// they can actually be told apart, which is what this checks.
private struct Atlas {
    let image: CGImage
    let entries: [(key: String, x: Int, y: Int, w: Int, h: Int)]
}

private func loadAtlas() -> Atlas? {
    let dir = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: "Library/Application Support/IsaacCompanion/data/abplus")
    guard let src = CGImageSourceCreateWithURL(
            dir.appending(path: "atlas.png") as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
          let data = try? Data(contentsOf: dir.appending(path: "atlas.index.json")),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let raw = json["entries"] as? [[String: Any]]
    else { return nil }
    let entries = raw.compactMap { e -> (String, Int, Int, Int, Int)? in
        guard let k = e["key"] as? String, let x = e["x"] as? Int, let y = e["y"] as? Int,
              let w = e["w"] as? Int, let h = e["h"] as? Int else { return nil }
        return (k, x, y, w, h)
    }
    return Atlas(image: image, entries: entries)
}

private let atlas = loadAtlas()

/// Every `card_<id>.png` cell, keyed by the id in its name.
private func cardSprites() -> [(id: Int, image: CGImage)] {
    guard let atlas else { return [] }
    return atlas.entries.compactMap { entry in
        guard entry.key.hasPrefix("card_"),
              let id = Int(entry.key.dropFirst(5).replacingOccurrences(of: ".png", with: "")),
              let crop = atlas.image.cropping(
                to: CGRect(x: entry.x, y: entry.y, width: entry.w, height: entry.h))
        else { return nil }
        return (id, crop)
    }
}

@Suite("Card reading", .enabled(if: atlas != nil, "no built data on this machine"))
struct CardReaderTests {

    @Test("the atlas yields a template for every card")
    func slices() throws {
        let sprites = cardSprites()
        #expect(sprites.count >= 50, "AB+ has 54 cards and runes, got \(sprites.count)")
        let reader = try #require(
            SpriteColourReader(side: SpriteColourReader.cardSide, sprites: sprites))
        #expect(reader.templates.count == sprites.count)
    }

    /// The one that decides whether this feature works. Unlike pills there is no learning
    /// step to fall back on -- if a card is misread, the app states the wrong card as
    /// fact.
    @Test("every card identifies as itself")
    func eachCardIsItself() throws {
        let sprites = cardSprites()
        let reader = try #require(
            SpriteColourReader(side: SpriteColourReader.cardSide, sprites: sprites))

        var wrong: [String] = []
        var thinnest = (id: -1, gap: 1.0)
        for sprite in sprites {
            let prepared = SpriteColourReader.rgba(sprite.image, side: SpriteColourReader.cardSide)
            let rgb = try #require(prepared?.0)
            let (best, runnerUp) = reader.ranked(candidate: rgb)
            // Either it is named, or it is one of a set the game gives identical art --
            // both are correct answers. What must never happen is naming a DIFFERENT card.
            #expect(
                best.contains { $0.index == sprite.id },
                "card \(sprite.id) read as \(best.map(\.index))")
            if !best.contains(where: { $0.index == sprite.id }) {
                wrong.append("card \(sprite.id) -> \(best.map(\.index))")
            }
            // Distance to the nearest card that is NOT indistinguishable from this one.
            let gap = (best.first?.score ?? 0) - (runnerUp?.score ?? 0)
            if gap < thinnest.gap { thinnest = (sprite.id, gap) }
        }
        #expect(wrong.isEmpty, "\(wrong.count) misread: \(wrong.prefix(6).joined(separator: ", "))")
        // Once true ties are excluded, the closest genuinely-different pair must still be
        // clearly apart, or a dark room would flip it.
        #expect(
            thinnest.gap > 0.01,
            "card \(thinnest.id) leads the nearest different card by only \(thinnest.gap)")
    }

    /// Afterbirth+ ships no art that separates Blank Rune from Black Rune -- both fall
    /// back to the generic card pickup. The reader must report BOTH rather than pick one,
    /// because picking would state a coin flip as fact.
    @Test("cards the game draws identically are reported as a pair, not guessed")
    func identicalArtIsAmbiguous() throws {
        let sprites = cardSprites()
        let reader = try #require(
            SpriteColourReader(side: SpriteColourReader.cardSide, sprites: sprites))
        let blank = try #require(sprites.first { $0.id == 40 })
        let prepared = SpriteColourReader.rgba(blank.image, side: SpriteColourReader.cardSide)
        let rgb = try #require(prepared?.0)
        let (best, _) = reader.ranked(candidate: rgb)
        #expect(best.count == 2, "expected a tied pair, got \(best.map(\.index))")
        #expect(Set(best.map(\.index)) == [40, 41], "Blank Rune and Black Rune")
    }

    /// The suit cards are the confusable set: same pip shape, and 2 of Hearts against
    /// 2 of Diamonds differs almost entirely in the artwork's detail, not its colour.
    /// This is exactly the case grayscale NCC would fail.
    @Test("the playing cards are told apart from each other")
    func suitsAreDistinct() throws {
        let sprites = cardSprites()
        let reader = try #require(
            SpriteColourReader(side: SpriteColourReader.cardSide, sprites: sprites))
        // Cards 39-43 are the suit cards in AB+ (2 of Diamonds, Clubs, Spades, Hearts,
        // Ace of...). Whichever ids they are, they are adjacent and must not collide.
        // 40/41 excluded: the game draws them identically, covered by its own test.
        for sprite in sprites where (38...48).contains(sprite.id) && ![40, 41].contains(sprite.id) {
            let prepared = SpriteColourReader.rgba(sprite.image, side: SpriteColourReader.cardSide)
            let rgb = try #require(prepared?.0)
            let ranked = reader.scores(candidate: rgb)
            #expect(
                ranked.first?.index == sprite.id,
                "card \(sprite.id) read as \(ranked.first?.index ?? -1)")
        }
    }

    @Test("bare floor is not a card")
    func emptySlot() throws {
        let sprites = cardSprites()
        let reader = try #require(
            SpriteColourReader(side: SpriteColourReader.cardSide, sprites: sprites))
        let W = 120, H = 90
        let made = CGContext(
            data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        let ctx = try #require(made)
        ctx.setFillColor(CGColor(red: 0.42, green: 0.31, blue: 0.24, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let empty = try #require(ctx.makeImage())
        #expect(reader.best(in: empty, window: 26, stride: 8) == nil, "named a card on bare floor")
    }
}
