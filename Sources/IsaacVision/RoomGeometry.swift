import CoreGraphics

/// Where a pedestal is on screen, given where the log said it is in the room.
///
/// This lives in its own library target rather than in the app for one reason: the app is
/// an executable target, and no test target can import an executable. The tests that
/// covered this previously kept their *own copy* of the arithmetic and asserted against
/// that -- so they passed whatever the real code did, including if it were deleted.
public enum RoomGeometry {
    /// Isaac's playable room area in the game's own position units. A 1x1 room spans this
    /// box, and its centre is (320, 280) -- which is exactly what the log reports for a
    /// lone treasure-room pedestal, so these bounds are self-checking.
    public static let origin = CGPoint(x: 80, y: 160)
    public static let size = CGSize(width: 480, height: 240)

    /// Collectible pedestals sit at y=280. Shop and Devil-room items sit at **y=320** --
    /// a full tile lower. Guessing 280 for those meant cropping empty floor, and since
    /// the crop is only about 40 units tall the right item was never in the picture.
    public static let pedestalY: CGFloat = 280
    public static let shopItemY: CGFloat = 320

    /// Where the room's own coordinates land in an image of the given size.
    ///
    /// The game letterboxes the room into the window, so this scales by the smaller axis
    /// and centres what it draws.
    public static func screenPoint(
        forRoomPosition position: CGPoint, in imageSize: CGSize
    ) -> CGPoint? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let scale = min(imageSize.width / size.width, imageSize.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        let offset = CGPoint(
            x: (imageSize.width - drawn.width) / 2,
            y: (imageSize.height - drawn.height) / 2)
        return CGPoint(
            x: (position.x - origin.x) * scale + offset.x,
            y: (position.y - origin.y) * scale + offset.y)
    }

    /// The pixel box a pedestal sprite should occupy.
    ///
    /// One tile wide, one and a half tall, **centred** on the reported point: 0.75 of a
    /// tile above it and 0.75 below. The extra height is headroom for the sprite's bob.
    ///
    /// Whether centred is right is genuinely open. The logged position is the pedestal,
    /// and the item floats above it, so the useful half of this box may be the top half
    /// and the bottom half may be floor. Nothing here can settle that -- it needs a
    /// capture of a real room, which is what the golden-image fixture is for. Until then
    /// this documents what the code does rather than asserting it is correct.
    public static func screenRect(
        forRoomPosition position: CGPoint, in imageSize: CGSize
    ) -> CGRect? {
        guard let local = screenPoint(forRoomPosition: position, in: imageSize) else {
            return nil
        }
        let scale = min(imageSize.width / size.width, imageSize.height / size.height)
        let side = 40 * scale                       // one tile, plus bob headroom
        let rect = CGRect(
            x: local.x - side / 2, y: local.y - side * 0.75,
            width: side, height: side * 1.5)
        // Entirely off-image means we were told about a pedestal we cannot see; say so
        // rather than handing back a rect that crops to nothing.
        return rect.intersection(CGRect(origin: .zero, size: imageSize)).isNull ? nil : rect
    }
}
