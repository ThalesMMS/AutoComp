import CoreGraphics

internal struct OverlayOriginClampResult: Equatable {
    let origin: CGPoint
    let wasClamped: Bool
}

internal extension CGRect {
    var isFiniteAndNonEmpty: Bool {
        origin.x.isFinite
            && origin.y.isFinite
            && size.width.isFinite
            && size.height.isFinite
            && width > 0
            && height > 0
    }

    func clampingOrigin(_ desiredOrigin: CGPoint, panelSize: CGSize) -> OverlayOriginClampResult {
        let origin = CGPoint(
            x: min(max(desiredOrigin.x, minX), max(minX, maxX - panelSize.width)),
            y: min(max(desiredOrigin.y, minY), max(minY, maxY - panelSize.height))
        )
        return OverlayOriginClampResult(
            origin: origin,
            wasClamped: origin != desiredOrigin
        )
    }
}
