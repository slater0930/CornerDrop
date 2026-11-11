import AppKit
import Combine
import Sparkle

/// Wraps Sparkle. The feed URL and public signing key live in Info.plist
/// (SUFeedURL / SUPublicEDKey); updates are published with scripts/release.sh.
@MainActor
final class Updater: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    @Published private(set) var canCheckForUpdates = false

    private var controller: SPUStandardUpdaterController!
    private var updater: SPUUpdater { controller.updater }

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                  userDriverDelegate: self)
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyDownloads: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyDownloadsUpdates = newValue
        }
    }

    var lastCheck: Date? { updater.lastUpdateCheckDate }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    // Menu bar apps have no Dock icon, so bring the update window to the front
    // when Sparkle finds an update on its scheduled check.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                              forUpdate update: SUAppcastItem,
                                                              state: SPUUserUpdateState) {
        MainActor.assumeIsolated {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
