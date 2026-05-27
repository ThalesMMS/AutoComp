import Foundation

@MainActor
final class SuggestionLifecycleController {
    private let refreshInterval: TimeInterval
    private var timer: Timer?

    init(refreshInterval: TimeInterval = 0.28) {
        self.refreshInterval = refreshInterval
    }

    var isRunning: Bool {
        timer != nil
    }

    func start(refresh: @escaping @MainActor () async -> Void) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { _ in
            Task { @MainActor in
                await refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
