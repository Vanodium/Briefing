import AppKit
import Sparkle

/// Updates come from GitHub Releases through Sparkle: an appcast lists the versions,
/// every archive is signed with Briefing's EdDSA key (SUPublicEDKey in Info.plist).
/// Sparkle asks once, on the second launch, whether to check automatically.
@MainActor
final class Updates: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updates()

    private var controller: SPUStandardUpdaterController!

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
    }

    /// Outside an app bundle (swift run) there is nothing to update.
    var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func start() {
        guard isAvailable else { return }
        do { try controller.updater.start() } catch { Log.write("updates: \(error.localizedDescription)") }
    }

    func checkNow() {
        NSAppActivate()
        controller.checkForUpdates(nil)
    }

    var automaticChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var version: String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String) ?? "—"
    }

    // MARK: SPUStandardUserDriverDelegate

    /// Briefing lives in the menu bar: a found update is shown as a normal window, brought to the front.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate {
            DispatchQueue.main.async { NSAppActivate() }
        }
    }
}
