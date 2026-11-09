import AppKit
import Sparkle

/// Checks for new betas without interrupting work. Installation is always a user choice.
@MainActor
final class AppUpdateController: NSObject, SPUUpdaterDelegate, NSMenuItemValidation {
    private var controller: SPUStandardUpdaterController?
    private let hasActiveWork: () -> Bool
    private var deferredInstall: Task<Void, Never>?

    init(hasActiveWork: @escaping () -> Bool) {
        self.hasActiveWork = hasActiveWork
        super.init()
        // swift test and standalone compile checks aren't installed app bundles.
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller?.startUpdater()
    }

    @objc func checkForUpdates(_ sender: Any?) { controller?.checkForUpdates(sender) }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { controller?.updater.canCheckForUpdates ?? false }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { ["beta"] }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard hasActiveWork() else { return false }
        deferredInstall?.cancel()
        deferredInstall = Task { @MainActor [weak self] in
            while let self, self.hasActiveWork() {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            installHandler()
        }
        return true
    }
}
