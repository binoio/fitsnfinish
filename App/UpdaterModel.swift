#if os(macOS) && canImport(Sparkle)
import Combine
import Foundation
import Sparkle

/// Sparkle updater wrapper for the Developer ID build. Started manually so
/// bare `swift run` binaries and tests (no Info.plist feed keys) never spin
/// up scheduled checks.
@MainActor
final class UpdaterModel: ObservableObject {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    )
    @Published var canCheckForUpdates = false

    init() {
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            controller.startUpdater()
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
#endif
