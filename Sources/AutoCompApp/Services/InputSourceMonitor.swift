import AutoCompCore
import Carbon
import Foundation

final class InputSourceMonitor: @unchecked Sendable {
    private static let inputSourceChangedNotification = CFNotificationName(
        kTISNotifySelectedKeyboardInputSourceChanged
    )

    private let lock = NSLock()
    private let notificationCenter: CFNotificationCenter?
    private var state: InputMethodState

    init(notificationCenter: CFNotificationCenter? = CFNotificationCenterGetDistributedCenter()) {
        self.notificationCenter = notificationCenter
        self.state = Self.readCurrentInputMethodState()

        if let notificationCenter {
            CFNotificationCenterAddObserver(
                notificationCenter,
                observer,
                Self.inputSourceChanged,
                Self.inputSourceChangedNotification.rawValue,
                nil,
                .deliverImmediately
            )
        }
    }

    deinit {
        if let notificationCenter {
            CFNotificationCenterRemoveObserver(
                notificationCenter,
                observer,
                Self.inputSourceChangedNotification,
                nil
            )
        }
    }

    var currentState: InputMethodState {
        withLock { state }
    }

    func refresh() {
        let updatedState = Self.readCurrentInputMethodState()
        withLock {
            state = updatedState
        }
        GeometryDebug.log("input-source state=\(updatedState.diagnosticSummary) id=\(updatedState.currentInputSourceID ?? "nil")")
    }

    private static let inputSourceChanged: CFNotificationCallback = { _, observer, _, _, _ in
        guard let observer else {
            return
        }

        let monitor = Unmanaged<InputSourceMonitor>.fromOpaque(observer).takeUnretainedValue()
        monitor.refresh()
    }

    private var observer: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    private static func readCurrentInputMethodState() -> InputMethodState {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return .asciiCompatible
        }

        let inputSourceID = stringProperty(kTISPropertyInputSourceID, source: source)
        let isASCIICompatible = boolProperty(
            kTISPropertyInputSourceIsASCIICapable,
            source: source
        ) ?? true

        return InputMethodState(
            isASCIICompatible: isASCIICompatible,
            isComposingText: false,
            currentInputSourceID: inputSourceID
        )
    }

    private static func stringProperty(_ key: CFString, source: TISInputSource) -> String? {
        guard let rawValue = TISGetInputSourceProperty(source, key) else {
            return nil
        }

        return Unmanaged<CFString>.fromOpaque(rawValue).takeUnretainedValue() as String
    }

    private static func boolProperty(_ key: CFString, source: TISInputSource) -> Bool? {
        guard let rawValue = TISGetInputSourceProperty(source, key) else {
            return nil
        }

        let value = Unmanaged<CFBoolean>.fromOpaque(rawValue).takeUnretainedValue()
        return CFBooleanGetValue(value)
    }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
