import CoreGraphics
import Testing

@testable import IsaacVision

/// These used to live in IsaacCoreTests with a *private copy* of the arithmetic, because
/// the real code sat in the app's executable target and no test target can import one.
/// They therefore passed regardless of what the app actually did -- including if the real
/// function were deleted. They now call the real code.
@Suite("Room geometry")
struct RoomGeometryTests {
    // The user's display, a smaller window, and a Retina backing store.
    private let sizes = [
        CGSize(width: 960, height: 540),
        CGSize(width: 1512, height: 949),
        CGSize(width: 3024, height: 1897),
    ]

    @Test("The room's centre lands in the middle of the image")
    func centreMapsToCentre() throws {
        // (320, 280) is what the log reports for a lone treasure-room pedestal, so this
        // doubles as a check that the room bounds themselves are right.
        for size in sizes {
            let p = try #require(
                RoomGeometry.screenPoint(
                    forRoomPosition: CGPoint(x: 320, y: 280), in: size))
            #expect(abs(p.x - size.width / 2) < 0.5, "x off at \(size)")
            #expect(abs(p.y - size.height / 2) < 0.5, "y off at \(size)")
        }
    }

    @Test("The room's corners stay inside the image")
    func cornersStayInside() throws {
        let size = CGSize(width: 1512, height: 949)
        let corners = [
            CGPoint(x: 80, y: 160), CGPoint(x: 560, y: 160),
            CGPoint(x: 80, y: 400), CGPoint(x: 560, y: 400),
        ]
        for c in corners {
            let p = try #require(RoomGeometry.screenPoint(forRoomPosition: c, in: size))
            #expect(p.x >= -1 && p.x <= size.width + 1, "x out of bounds for \(c)")
            #expect(p.y >= -1 && p.y <= size.height + 1, "y out of bounds for \(c)")
        }
    }

    @Test("Two pedestals straddle the centre symmetrically")
    func twoPedestalsStraddleCentre() throws {
        let size = CGSize(width: 1512, height: 949)
        let left = try #require(
            RoomGeometry.screenPoint(forRoomPosition: CGPoint(x: 240, y: 280), in: size))
        let right = try #require(
            RoomGeometry.screenPoint(forRoomPosition: CGPoint(x: 400, y: 280), in: size))
        #expect(left.x < size.width / 2)
        #expect(right.x > size.width / 2)
        #expect(abs((size.width / 2 - left.x) - (right.x - size.width / 2)) < 0.5)
        #expect(abs(left.y - right.y) < 0.5)
    }

    @Test("An ultrawide window letterboxes on width, not height")
    func ultrawideIsLimitedByHeight() throws {
        // The room is 2:1. On anything WIDER than that the fit is limited by height, and
        // on anything narrower by width. Every ordinary window (1512x949 is 1.59:1) is in
        // the second case, where scaling by width and scaling by min() give the same
        // answer -- so a scale that simply used width passed every other test here while
        // being wrong on an ultrawide monitor.
        let ultrawide = CGSize(width: 2400, height: 900)      // 2.67:1
        let centre = try #require(
            RoomGeometry.screenPoint(forRoomPosition: CGPoint(x: 320, y: 280), in: ultrawide))
        #expect(abs(centre.x - 1200) < 0.5)
        #expect(abs(centre.y - 450) < 0.5)

        // Height-limited: 900/240 = 3.75, so the room draws 1800 wide with 300px bars
        // either side. A width-limited scale would be 5 and run off the bottom.
        let left = try #require(
            RoomGeometry.screenPoint(forRoomPosition: CGPoint(x: 80, y: 160), in: ultrawide))
        #expect(abs(left.x - 300) < 0.5, "expected 300px pillarbox, got x=\(left.x)")
        #expect(abs(left.y - 0) < 0.5, "the room should touch the top edge, got y=\(left.y)")

        // And every corner still lands inside the image, which is the property that
        // actually breaks when the scale is wrong.
        for corner in [CGPoint(x: 80, y: 160), CGPoint(x: 560, y: 400)] {
            let p = try #require(
                RoomGeometry.screenPoint(forRoomPosition: corner, in: ultrawide))
            #expect(p.x >= -1 && p.x <= ultrawide.width + 1)
            #expect(p.y >= -1 && p.y <= ultrawide.height + 1)
        }
    }

    @Test("Scale is uniform on both axes")
    func uniformScale() throws {
        // A non-2:1 window: the room is letterboxed, so 80 units right and 80 units down
        // must travel the same number of pixels. Scaling each axis to fill would stretch
        // the crop off the sprite.
        let size = CGSize(width: 1600, height: 900)
        let o = try #require(
            RoomGeometry.screenPoint(forRoomPosition: CGPoint(x: 320, y: 280), in: size))
        let right = try #require(
            RoomGeometry.screenPoint(forRoomPosition: CGPoint(x: 400, y: 280), in: size))
        let down = try #require(
            RoomGeometry.screenPoint(forRoomPosition: CGPoint(x: 320, y: 360), in: size))
        #expect(abs((right.x - o.x) - (down.y - o.y)) < 0.001)
    }

    // MARK: - the crop box, which nothing covered before

    @Test("The crop box is centred on the point and taller than it is wide")
    func cropBoxShape() throws {
        let size = CGSize(width: 1512, height: 949)
        let point = try #require(
            RoomGeometry.screenPoint(forRoomPosition: CGPoint(x: 320, y: 280), in: size))
        let rect = try #require(
            RoomGeometry.screenRect(forRoomPosition: CGPoint(x: 320, y: 280), in: size))

        #expect(abs(rect.midX - point.x) < 0.001)
        // Centred vertically too -- 0.75 of a tile above and below. Worth pinning
        // because it is easy to assume the box is offset upward to follow the floating
        // item, and it is not. Whether it SHOULD be is a question only a capture of a
        // real room can answer; see the golden-image fixture.
        #expect(abs(rect.midY - point.y) < 0.001)
        // One tile wide, one and a half tall: headroom for the sprite's bob.
        #expect(abs(rect.height / rect.width - 1.5) < 0.001)
    }

    @Test("Shop and Devil items sit a tile lower than treasure pedestals")
    func shopItemsAreLower() throws {
        // Regression. Collectible pedestals are at y=280 but shop and Devil-room items sit
        // at y=320, and the earlier code assumed 280 for both. The crop is only ~40 units
        // tall, so that mistake pointed it at empty floor and the item was never in frame.
        let size = CGSize(width: 1512, height: 949)
        let pedestal = try #require(
            RoomGeometry.screenRect(
                forRoomPosition: CGPoint(x: 320, y: RoomGeometry.pedestalY), in: size))
        let shop = try #require(
            RoomGeometry.screenRect(
                forRoomPosition: CGPoint(x: 320, y: RoomGeometry.shopItemY), in: size))
        #expect(shop.minY > pedestal.minY, "the shop crop is not lower at all")
        // And far enough apart that one box does not simply cover the other.
        #expect(shop.midY - pedestal.midY > pedestal.height * 0.5,
            "the two crops overlap so much that 280 would have worked by accident")
    }

    @Test("The box scales with the window")
    func boxScales() throws {
        let small = try #require(
            RoomGeometry.screenRect(
                forRoomPosition: CGPoint(x: 320, y: 280),
                in: CGSize(width: 960, height: 540)))
        let big = try #require(
            RoomGeometry.screenRect(
                forRoomPosition: CGPoint(x: 320, y: 280),
                in: CGSize(width: 1920, height: 1080)))
        #expect(abs(big.width / small.width - 2) < 0.01)
    }

    @Test("Degenerate and off-screen inputs return nil rather than a nonsense box")
    func rejectsImpossible() {
        #expect(
            RoomGeometry.screenRect(
                forRoomPosition: CGPoint(x: 320, y: 280), in: .zero) == nil)
        #expect(
            RoomGeometry.screenPoint(
                forRoomPosition: CGPoint(x: 320, y: 280),
                in: CGSize(width: 0, height: 100)) == nil)
        // Far outside the room: we were told about a pedestal we cannot see.
        #expect(
            RoomGeometry.screenRect(
                forRoomPosition: CGPoint(x: 99999, y: 280),
                in: CGSize(width: 1512, height: 949)) == nil)
    }
}
