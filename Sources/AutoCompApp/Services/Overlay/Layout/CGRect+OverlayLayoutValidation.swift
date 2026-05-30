import CoreGraphics

internal extension CGRect {
    var isFiniteAndNonEmpty: Bool {
        origin.x.isFinite
            && origin.y.isFinite
            && size.width.isFinite
            && size.height.isFinite
            && width > 0
            && height > 0
    }
}
