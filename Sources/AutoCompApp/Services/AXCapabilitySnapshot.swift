import AppKit
import AutoCompCore
import CryptoKit
import Foundation

struct AXElementCapabilityPresence: Codable, Equatable {
    let hasAXValue: Bool
    let hasAXSelectedTextRange: Bool
    let hasAXBoundsForRange: Bool
}

struct AXCapabilitySnapshot: Codable, Equatable {
    struct Geometry: Codable, Equatable {
        let focusedElementRect: SanitizedRect?
        let caretRect: SanitizedRect?
        let previousGlyphRect: SanitizedRect?
        let nextGlyphRect: SanitizedRect?
        let lineReferenceRect: SanitizedRect?
        let observedCharacterWidth: Double?
    }

    struct SanitizedRect: Codable, Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        static func make(_ rect: CGRect?) -> SanitizedRect? {
            guard let rect,
                  rect.origin.x.isFinite,
                  rect.origin.y.isFinite,
                  rect.width.isFinite,
                  rect.height.isFinite,
                  rect.width >= 0,
                  rect.height >= 0 else {
                return nil
            }

            return SanitizedRect(
                x: rounded(rect.origin.x),
                y: rounded(rect.origin.y),
                width: rounded(rect.width),
                height: rounded(rect.height)
            )
        }

        static func rounded(_ value: CGFloat) -> Double {
            (Double(value) * 100).rounded() / 100
        }
    }

    let schemaVersion: Int
    let bundleID: String
    let normalizedDomain: String?
    let role: String?
    let subrole: String?
    let capabilityPresence: AXElementCapabilityPresence
    let geometry: Geometry
    let captureSources: [String]
    let caretQuality: String

    static func make(
        focusSnapshot: AXFocusSnapshot,
        geometry: AXTextGeometrySnapshot,
        captureSources: Set<TextCaptureSource>,
        capabilityPresence: AXElementCapabilityPresence
    ) -> AXCapabilitySnapshot {
        AXCapabilitySnapshot(
            schemaVersion: 1,
            bundleID: focusSnapshot.bundleID,
            normalizedDomain: focusSnapshot.domain,
            role: focusSnapshot.role,
            subrole: focusSnapshot.subrole,
            capabilityPresence: capabilityPresence,
            geometry: Geometry(
                focusedElementRect: SanitizedRect.make(geometry.focusedElementRect),
                caretRect: SanitizedRect.make(geometry.caretRect),
                previousGlyphRect: SanitizedRect.make(geometry.previousGlyphRect),
                nextGlyphRect: SanitizedRect.make(geometry.nextGlyphRect),
                lineReferenceRect: SanitizedRect.make(geometry.lineReferenceRect),
                observedCharacterWidth: geometry.observedCharacterWidth.map { SanitizedRect.rounded($0) }
            ),
            captureSources: captureSources.map(\.rawValue).sorted(),
            caretQuality: geometry.caretGeometryQuality.rawValue
        )
    }

    func fixtureSeed() -> AXCapabilitySnapshotFixtureSeed {
        AXCapabilitySnapshotFixtureSeed(
            id: stableFixtureID(),
            bundleID: bundleID,
            normalizedDomain: normalizedDomain,
            role: role,
            subrole: subrole,
            geometry: geometry,
            captureSources: captureSources,
            caretQuality: caretQuality,
            textBeforeCursor: AXCapabilitySnapshotFixtureSeed.syntheticText
        )
    }

    private func stableFixtureID() -> String {
        let source = [
            bundleID,
            normalizedDomain ?? "none",
            role ?? "none",
            subrole ?? "none",
            caretQuality,
            captureSources.joined(separator: ",")
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(source.utf8))
        let suffix = digest.prefix(5).map { String(format: "%02x", $0) }.joined()
        return "ax-capability-\(sanitizedIDComponent(bundleID))-\(suffix)"
    }

    private func sanitizedIDComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "app" : collapsed.lowercased()
    }
}

struct AXCapabilitySnapshotFixtureSeed: Codable, Equatable {
    static let syntheticText = "synthetic fixture prefix"

    let id: String
    let bundleID: String
    let normalizedDomain: String?
    let role: String?
    let subrole: String?
    let geometry: AXCapabilitySnapshot.Geometry
    let captureSources: [String]
    let caretQuality: String
    let textBeforeCursor: String
}

protocol AXCapabilitySnapshotRecording {
    func record(
        focusSnapshot: AXFocusSnapshot,
        geometry: AXTextGeometrySnapshot,
        captureSources: Set<TextCaptureSource>,
        capabilityPresence: AXElementCapabilityPresence
    )
}

struct AXCapabilitySnapshotRecorder: AXCapabilitySnapshotRecording {
    private let artifactStore: DebugArtifactStore
    private let isEnabled: () -> Bool
    private let now: () -> Date
    private let logger = AutoCompLogger(category: "ax-capability-snapshot")

    init(
        artifactStore: DebugArtifactStore = DebugArtifactStore(),
        isEnabled: @escaping () -> Bool = {
            ProcessInfo.processInfo.environment["AUTOCOMP_CAPTURE_AX_CAPABILITY_SNAPSHOT"] == "1"
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.artifactStore = artifactStore
        self.isEnabled = isEnabled
        self.now = now
    }

    func record(
        focusSnapshot: AXFocusSnapshot,
        geometry: AXTextGeometrySnapshot,
        captureSources: Set<TextCaptureSource>,
        capabilityPresence: AXElementCapabilityPresence
    ) {
        guard isEnabled() else {
            return
        }

        let snapshot = AXCapabilitySnapshot.make(
            focusSnapshot: focusSnapshot,
            geometry: geometry,
            captureSources: captureSources,
            capabilityPresence: capabilityPresence
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(snapshot)
            let name = [
                "ax-capability-snapshot",
                snapshot.bundleID,
                snapshot.normalizedDomain ?? "no-domain"
            ].joined(separator: "-")
            _ = try artifactStore.saveRedactedArtifact(
                named: name,
                data: data,
                createdAt: now()
            )
        } catch {
            logger.error("ax-capability-snapshot-save-failed reason=\(String(describing: error))")
        }
    }
}
