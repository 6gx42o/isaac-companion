import Testing
import CoreGraphics
@testable import IsaacCore

/// The room-position -> screen-pixel mapping, checked against the one anchor the game
/// gives us for free: a lone pedestal in a 1x1 room always logs at (320, 280), which
/// must land dead centre of the drawn room.
///
/// The mapping itself lives in the app target (RoomScanner) so it is duplicated here
/// deliberately -- if the two ever disagree, this test is the one that is right.
private enum RoomGeometry {
    static let origin = CGPoint(x: 80, y: 160)
    static let size = CGSize(width: 480, height: 240)

    static func screenPoint(for position: CGPoint, in image: CGSize) -> CGPoint {
        let scale = min(image.width / size.width, image.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        let offset = CGPoint(
            x: (image.width - drawn.width) / 2, y: (image.height - drawn.height) / 2)
        return CGPoint(
            x: (position.x - origin.x) * scale + offset.x,
            y: (position.y - origin.y) * scale + offset.y)
    }
}

@Suite("Room geometry")
struct RoomGeometryTests {

    @Test("A centre pedestal maps to the centre of the drawn room")
    func centreMapsToCentre() {
        // (320, 280) is what the real log reports for a single treasure-room pedestal.
        for image in [CGSize(width: 960, height: 540), CGSize(width: 1512, height: 949),
                      CGSize(width: 3024, height: 1897)] {
            let point = RoomGeometry.screenPoint(for: CGPoint(x: 320, y: 280), in: image)
            #expect(abs(point.x - image.width / 2) < 0.5, "x off centre at \(image)")
            #expect(abs(point.y - image.height / 2) < 0.5, "y off centre at \(image)")
        }
    }

    @Test("Room corners map inside the image, never outside it")
    func cornersStayInside() {
        let image = CGSize(width: 1512, height: 949)
        let corners = [
            CGPoint(x: 80, y: 160), CGPoint(x: 560, y: 160),
            CGPoint(x: 80, y: 400), CGPoint(x: 560, y: 400),
        ]
        for corner in corners {
            let p = RoomGeometry.screenPoint(for: corner, in: image)
            #expect(p.x >= -1 && p.x <= image.width + 1, "\(corner) -> \(p)")
            #expect(p.y >= -1 && p.y <= image.height + 1, "\(corner) -> \(p)")
        }
    }

    @Test("Left and right pedestals of a two-item Devil Room straddle the centre")
    func twoPedestalsStraddleCentre() {
        // Devil Rooms place two pedestals symmetrically about the room centre.
        let image = CGSize(width: 1512, height: 949)
        let left = RoomGeometry.screenPoint(for: CGPoint(x: 240, y: 280), in: image)
        let right = RoomGeometry.screenPoint(for: CGPoint(x: 400, y: 280), in: image)
        #expect(left.x < image.width / 2)
        #expect(right.x > image.width / 2)
        // Symmetric about the centre.
        #expect(abs((image.width / 2 - left.x) - (right.x - image.width / 2)) < 0.5)
        #expect(abs(left.y - right.y) < 0.5)
    }

    @Test("Scaling is uniform, so sprites stay square")
    func uniformScale() {
        let image = CGSize(width: 1600, height: 900)   // wider than the room's 2:1
        let a = RoomGeometry.screenPoint(for: CGPoint(x: 80, y: 160), in: image)
        let b = RoomGeometry.screenPoint(for: CGPoint(x: 160, y: 240), in: image)
        // 80 units right and 80 units down must travel the same pixel distance.
        #expect(abs((b.x - a.x) - (b.y - a.y)) < 0.001)
    }
}
