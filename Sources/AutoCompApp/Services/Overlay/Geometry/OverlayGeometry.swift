import AppKit

enum OverlayGeometry {
    static func appKitPoint(accessibilityPoint: CGPoint, screenFrame: CGRect) -> CGPoint {
        CGPoint(x: accessibilityPoint.x, y: screenFrame.maxY - accessibilityPoint.y)
    }

    static func appKitRect(accessibilityRect rect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: screenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func screen(containingAccessibilityRect rect: CGRect) -> NSScreen {
        let mainScreenFrame = NSScreen.screens.first?.frame ?? .zero
        return NSScreen.screens.first { screen in
            let point = appKitPoint(
                accessibilityPoint: CGPoint(x: rect.midX, y: rect.midY),
                screenFrame: mainScreenFrame
            )
            return screen.frame.contains(point)
        } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func insertionPointX(for caretRect: CGRect) -> CGFloat {
        isFineCaret(caretRect) ? caretRect.maxX : caretRect.minX
    }

    static func isFineCaret(_ caretRect: CGRect) -> Bool {
        caretRect.width <= max(CGFloat(4), caretRect.height * 0.35)
    }
}
