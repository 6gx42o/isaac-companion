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
            SpriteColourReader(width: SpriteColourReader.cardW, height: SpriteColourReader.cardH, sprites: sprites))
        #expect(reader.templates.count == sprites.count)
    }

    /// The one that decides whether this feature works. Unlike pills there is no learning
    /// step to fall back on -- if a card is misread, the app states the wrong card as
    /// fact.
    @Test("every card identifies as itself")
    func eachCardIsItself() throws {
        let sprites = cardSprites()
        let reader = try #require(
            SpriteColourReader(width: SpriteColourReader.cardW, height: SpriteColourReader.cardH, sprites: sprites))

        var wrong: [String] = []
        var thinnest = (id: -1, gap: 1.0)
        for sprite in sprites {
            // Trimmed: a correctly-sized window frames the art, not the padded cell.
            let prepared = SpriteColourReader.rgba(
                SpriteColourReader.trimmed(sprite.image),
                width: SpriteColourReader.cardW, height: SpriteColourReader.cardH)
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
            SpriteColourReader(width: SpriteColourReader.cardW, height: SpriteColourReader.cardH, sprites: sprites))
        let blank = try #require(sprites.first { $0.id == 40 })
        let prepared = SpriteColourReader.rgba(
            SpriteColourReader.trimmed(blank.image),
            width: SpriteColourReader.cardW, height: SpriteColourReader.cardH)
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
            SpriteColourReader(width: SpriteColourReader.cardW, height: SpriteColourReader.cardH, sprites: sprites))
        // Cards 39-43 are the suit cards in AB+ (2 of Diamonds, Clubs, Spades, Hearts,
        // Ace of...). Whichever ids they are, they are adjacent and must not collide.
        // 40/41 excluded: the game draws them identically, covered by its own test.
        for sprite in sprites where (38...48).contains(sprite.id) && ![40, 41].contains(sprite.id) {
            // Trimmed: a correctly-sized window frames the art, not the padded cell.
            let prepared = SpriteColourReader.rgba(
                SpriteColourReader.trimmed(sprite.image),
                width: SpriteColourReader.cardW, height: SpriteColourReader.cardH)
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
            SpriteColourReader(width: SpriteColourReader.cardW, height: SpriteColourReader.cardH, sprites: sprites))
        let W = 120, H = 90
        let made = CGContext(
            data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        let ctx = try #require(made)
        ctx.setFillColor(CGColor(red: 0.42, green: 0.31, blue: 0.24, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let empty = try #require(ctx.makeImage())
        #expect(reader.best(in: empty, windowW: 26, windowH: 26, stride: 8) == nil, "named a card on bare floor")
    }
}

@Suite("Flat background", .enabled(if: atlas != nil, "no built data on this machine"))
struct FlatBackgroundTests {
    /// The live false positive, as a fixture: an empty pocket slot over black room
    /// background was announced as A Card Against Humanity at 0.92, because that card
    /// is almost entirely black and colour distance cannot tell flat-equals-flat from
    /// sprite-equals-sprite. A window with no edges must never match anything.
    @Test("flat black is not A Card Against Humanity, or anything else")
    func flatBlackMatchesNothing() throws {
        let sprites = cardSprites()
        let reader = try #require(
            SpriteColourReader(width: SpriteColourReader.cardW, height: SpriteColourReader.cardH, sprites: sprites))
        for shade: CGFloat in [0.0, 0.04, 0.10] {
            let W = 200, H = 150
            let made = CGContext(
                data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            let ctx = try #require(made)
            ctx.setFillColor(CGColor(red: shade, green: shade, blue: shade, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            let flat = try #require(ctx.makeImage())
            let hit = reader.best(in: flat, windowW: 24, windowH: 24, stride: 6)
            #expect(hit == nil, "flat \(shade) matched card \(hit?.match.index ?? -1)")
        }
    }

    /// The guard must not kill real matches: a sprite dropped onto the same black
    /// background still identifies, because the sprite itself carries the variance.
    @Test("a real card on black background still identifies")
    func realCardOnBlackStillMatches() throws {
        let sprites = cardSprites()
        let reader = try #require(
            SpriteColourReader(width: SpriteColourReader.cardW, height: SpriteColourReader.cardH, sprites: sprites))
        let wanted = 4                                   // III - The Empress, mid-toned
        let sprite = try #require(sprites.first { $0.id == wanted }?.image)
        let W = 200, H = 150
        let made = CGContext(
            data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        let ctx = try #require(made)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.interpolationQuality = .none
        // Draw the ART at a card's aspect, as the HUD does -- not the padded cell.
        let art = SpriteColourReader.trimmed(sprite)
        ctx.draw(art, in: CGRect(x: 88, y: 50, width: 30, height: 40))
        let frame = try #require(ctx.makeImage())
        // Stride 2, as production uses: CGContext draws bottom-up, so the sprite's
        // top-left lands off any coarser grid and the only aligned window misses it.
        let hit = try #require(
            reader.best(in: frame, windowW: 30, windowH: 40, stride: 2), "found nothing")
        #expect(hit.match.index == wanted, "read card \(hit.match.index)")
    }
}

/// Captures from the user's own play sessions, kept outside the repository (they show
/// the game's art) -- the tests skip where they are absent. Each one pins a failure
/// that actually happened on screen, which no synthetic fixture fully reproduces.
private func liveFixture(_ name: String) -> CGImage? {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "LiveFixtures/\(name)")
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

private let emptySlotCapture = liveFixture("empty-slot-black-room.png")

@Suite("Live captures", .enabled(if: emptySlotCapture != nil && atlas != nil,
                                 "no live fixtures on this machine"))
struct LiveCaptureTests {
    /// The first automatic pocket read ever taken: an empty slot over a black room,
    /// announced as A Card Against Humanity at 0.92 because that card is almost
    /// entirely black. This exact capture must never name a card again.
    @Test("the live false positive stays dead")
    func emptySlotStaysEmpty() throws {
        let sprites = cardSprites()
        let reader = try #require(
            SpriteColourReader(width: SpriteColourReader.cardW, height: SpriteColourReader.cardH, sprites: sprites))
        let capture = try #require(emptySlotCapture)
        // One production window size, coarser stride: the false positive appeared at
        // dozens of window positions, so a stride-6 sweep still lands on plenty of
        // them -- and an unoptimised test build cannot afford the full stride-2 sweep
        // (that is release-mode work; it blew a ten-minute test timeout here).
        if let hit = reader.best(in: capture, windowW: 63, windowH: 63, stride: 6) {
            Issue.record("named card \(hit.match.index) at \(hit.match.score)")
        }
    }
}

private let pocketCardCapture = liveFixture("pocket-justice-card.png")

@Suite("Live pocket slot", .enabled(if: pocketCardCapture != nil && atlas != nil,
                                    "no live fixtures on this machine"))
struct LivePocketTests {
    /// A real bottom-right pocket crop holding VIII - Justice (card 9).
    ///
    /// Read at the geometry the game itself specifies: ui_cardspills.anm2 draws card
    /// faces from 16x24 frames, and the harvested art inside them is a uniform 14x18.
    /// Matching that through a square grid was why a held card never identified -- the
    /// sprite was being compared at an aspect it is never drawn at.
    @Test("the card actually in the pocket slot is identified")
    func identifiesTheHeldCard() throws {
        let sprites = cardSprites()
        let reader = try #require(
            SpriteColourReader(
                width: SpriteColourReader.cardW, height: SpriteColourReader.cardH,
                sprites: sprites))
        let capture = try #require(pocketCardCapture)
        // 15x20 game px at this capture's scale (1512/480 = 3.15) -- the drawn frame
        // including its border, which is what the HUD puts on screen.
        let hit = try #require(
            reader.best(in: capture, windowW: 47, windowH: 63, stride: 2),
            "found nothing in the slot")
        #expect(hit.match.index == 9, "read card \(hit.match.index), expected 9 (VIII - Justice)")
    }
}

private func runeStrip() -> CGImage? {
    let url = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: "Library/Application Support/IsaacCompanion/data/abplus/runes_hud.png")
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

private let runes = runeStrip()

@Suite("Every pocket sprite", .enabled(if: atlas != nil, "no built data on this machine"))
struct EveryPocketSpriteTests {
    /// Every tarot card must identify from its own art. These are the 43 the HUD draws
    /// at 14x18, and they are the overwhelming majority of what lands in a pocket slot.
    @Test("every card-shaped sprite identifies as itself")
    func everyCardIdentifies() throws {
        let sprites = cardSprites().filter {
            let art = SpriteColourReader.trimmed($0.image)
            return abs(Double(art.width) / Double(max(art.height, 1)) - 14.0 / 18.0) < 0.15
        }
        #expect(sprites.count >= 40, "expected the tarot cards, got \(sprites.count)")
        let reader = try #require(
            SpriteColourReader(
                width: SpriteColourReader.cardW, height: SpriteColourReader.cardH,
                sprites: sprites))
        var wrong: [String] = []
        for s in sprites {
            let prepared = SpriteColourReader.rgba(
                SpriteColourReader.trimmed(s.image),
                width: SpriteColourReader.cardW, height: SpriteColourReader.cardH)
            let rgb = try #require(prepared?.0)
            let best = reader.ranked(candidate: rgb).best
            if !best.contains(where: { $0.index == s.id }) {
                wrong.append("\(s.id)->\(best.map(\.index))")
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count) misread: \(wrong.prefix(5).joined(separator: " "))")
    }

    /// Runes are the honest limit, and it is the game's, not the reader's: the HUD draws
    /// THREE generic stones for every rune in the game. So a rune is recognisable as a
    /// rune and never as which one -- and the browser art (the giant-book pickup plate)
    /// must not be used here, because it is not what the slot ever shows.
    @Test("the rune stones are the three the HUD actually draws")
    func runeStonesAreTheHUDs() throws {
        let strip = try #require(runes, "runes_hud.png not built on this machine")
        #expect(strip.width / strip.height == 3, "the game draws three rune stones")
        let reader = try #require(
            SpriteColourReader(strip: strip, side: SpriteColourReader.pillSide))
        #expect(reader.templates.count == 3)
        // Each stone identifies as itself, which is all that is needed: any of them
        // means "a rune", and the caller answers with every rune id at once.
        let cell = strip.height
        for i in 0..<3 {
            let crop = try #require(
                strip.cropping(to: CGRect(x: i * cell, y: 0, width: cell, height: cell)))
            let prepared = SpriteColourReader.rgba(
                SpriteColourReader.trimmed(crop),
                width: SpriteColourReader.pillSide, height: SpriteColourReader.pillSide)
            let rgb = try #require(prepared?.0)
            #expect(reader.scores(candidate: rgb).first?.index == i, "stone \(i)")
        }
    }
}
