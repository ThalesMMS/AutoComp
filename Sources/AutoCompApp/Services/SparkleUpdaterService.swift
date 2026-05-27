import Combine
import Foundation

final class SparkleUpdaterService: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    private var updaterController: AnyObject?

    init(bundle: Bundle = .main) {
        guard Self.hasUpdateConfiguration(in: bundle),
              Self.loadFramework(from: bundle),
              let controller = Self.makeUpdaterController()
        else {
            return
        }

        updaterController = controller
        canCheckForUpdates = true
    }

    func checkForUpdates() {
        _ = updaterController?.perform(NSSelectorFromString("checkForUpdates:"), with: nil)
    }

    private static func hasUpdateConfiguration(in bundle: Bundle) -> Bool {
        nonEmptyInfoValue("SUFeedURL", in: bundle)
            && nonEmptyInfoValue("SUPublicEDKey", in: bundle)
    }

    private static func nonEmptyInfoValue(_ key: String, in bundle: Bundle) -> Bool {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else {
            return false
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func loadFramework(from bundle: Bundle) -> Bool {
        if NSClassFromString("SPUStandardUpdaterController") != nil {
            return true
        }

        guard let frameworkURL = bundle.privateFrameworksURL?
            .appendingPathComponent("Sparkle.framework"),
              let framework = Bundle(url: frameworkURL)
        else {
            return false
        }

        return framework.load()
    }

    private static func makeUpdaterController() -> AnyObject? {
        guard let controllerClass = NSClassFromString("SPUStandardUpdaterController") else {
            return nil
        }

        let allocated = (controllerClass as AnyObject)
            .perform(NSSelectorFromString("alloc"))?
            .takeUnretainedValue()

        return allocated?
            .perform(
                NSSelectorFromString("initWithUpdaterDelegate:userDriverDelegate:"),
                with: nil,
                with: nil
            )?
            .takeUnretainedValue()
    }
}
