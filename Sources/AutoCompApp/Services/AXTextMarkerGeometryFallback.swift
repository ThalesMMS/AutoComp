import ApplicationServices
import AutoCompCore
import CoreGraphics
import Foundation

enum AXTextMarkerFallbackGate: Equatable {
    case attempt
    case rejected(reason: String)
}

struct AXTextMarkerGeometryFallback {
    let isEnabled: Bool

    init(isEnabled: Bool = AXTextMarkerGeometryFallback.defaultEnabled) {
        self.isEnabled = isEnabled
    }

    static var defaultEnabled: Bool {
        isEnabledByDefault()
    }

    static func isEnabledByDefault(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        environment["AUTOCOMP_AX_TEXT_MARKER_FALLBACK"] != "0"
            && !SafeOverlayMode.isEnabled(environment: environment, arguments: arguments)
    }

    static func isEligibleBrowser(bundleID: String) -> Bool {
        [
            "com.apple.Safari",
            "com.google.Chrome",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "company.thebrowser.Browser",
            "company.thebrowser.dia"
        ].contains(bundleID)
    }

    static func gate(
        bundleID: String,
        geometry: AXTextGeometrySnapshot,
        isEnabled: Bool,
        isSafeOverlayModeEnabled: Bool = SafeOverlayMode.isEnabled
    ) -> AXTextMarkerFallbackGate {
        guard !isSafeOverlayModeEnabled else {
            return .rejected(reason: "safe-overlay-mode")
        }

        guard isEnabled else {
            return .rejected(reason: "disabled")
        }

        guard isEligibleBrowser(bundleID: bundleID) else {
            return .rejected(reason: "ineligible-bundle")
        }

        guard hasWeakGeometry(geometry) else {
            return .rejected(reason: "strong-geometry")
        }

        return .attempt
    }

    static func hasWeakGeometry(_ geometry: AXTextGeometrySnapshot) -> Bool {
        guard geometry.caretGeometryQuality == .directCaret,
              let caretRect = geometry.caretRect else {
            return true
        }

        return !isPlausibleBrowserTextMetric(caretRect)
    }

    private static func isPlausibleBrowserTextMetric(_ rect: CGRect) -> Bool {
        rect.minX.isFinite
            && rect.minY.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.minX >= 0
            && rect.minY >= 0
            && rect.width > 0
            && rect.width <= 160
            && rect.height >= 8
            && rect.height <= 120
    }

    func resolve(snapshot: AXFocusSnapshot, geometry: AXTextGeometrySnapshot) -> CGRect? {
        let gate = Self.gate(
            bundleID: snapshot.bundleID,
            geometry: geometry,
            isEnabled: isEnabled
        )
        GeometryDebug.log("ax-text-marker considered bundle=\(snapshot.bundleID) quality=\(geometry.caretGeometryQuality.rawValue) gate=\(gate.debugDescription)")

        guard case .attempt = gate else {
            GeometryDebug.log("ax-text-marker rejected bundle=\(snapshot.bundleID) reason=\(gate.rejectionReason ?? "unknown")")
            return nil
        }

        guard let markerRange = selectedTextMarkerRange(from: snapshot.focusedElement) else {
            GeometryDebug.log("ax-text-marker failed bundle=\(snapshot.bundleID) reason=missing-selected-marker-range")
            return nil
        }

        guard let rect = boundsForTextMarkerRange(markerRange, in: snapshot.focusedElement) else {
            GeometryDebug.log("ax-text-marker failed bundle=\(snapshot.bundleID) reason=missing-marker-bounds")
            return nil
        }

        guard rect.isUsableTextMarkerRect else {
            GeometryDebug.log("ax-text-marker failed bundle=\(snapshot.bundleID) reason=invalid-marker-rect rect=\(rect)")
            return nil
        }

        GeometryDebug.log("ax-text-marker used bundle=\(snapshot.bundleID) rect=\(rect)")
        return rect
    }

    private func selectedTextMarkerRange(from element: AXUIElement) -> CFTypeRef? {
        var markerRangeValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            "AXSelectedTextMarkerRange" as CFString,
            &markerRangeValue
        )
        guard status == .success, let markerRangeValue else {
            return nil
        }
        return markerRangeValue
    }

    private func boundsForTextMarkerRange(_ markerRange: CFTypeRef, in element: AXUIElement) -> CGRect? {
        var boundsValue: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXBoundsForTextMarkerRange" as CFString,
            markerRange,
            &boundsValue
        )

        guard status == .success, let boundsValue else {
            return nil
        }

        let axValue = (boundsValue as! AXValue)
        guard AXValueGetType(axValue) == .cgRect else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else {
            return nil
        }
        return rect
    }
}

private extension AXTextMarkerFallbackGate {
    var rejectionReason: String? {
        switch self {
        case .attempt:
            return nil
        case .rejected(let reason):
            return reason
        }
    }

    var debugDescription: String {
        switch self {
        case .attempt:
            return "attempt"
        case .rejected(let reason):
            return "rejected-\(reason)"
        }
    }
}

private extension CGRect {
    var isUsableTextMarkerRect: Bool {
        minX.isFinite
            && minY.isFinite
            && width.isFinite
            && height.isFinite
            && width >= 0
            && height > 0
            && !(abs(minX) < 0.5 && abs(minY) < 0.5 && width == 0 && height == 0)
    }
}
