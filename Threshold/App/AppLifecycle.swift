import SwiftUI

/// Shared app lifecycle policy. Platform entry points retain only genuinely
/// platform-specific work such as PGO flushing or window restoration.
@MainActor
enum AppLifecycle {
    static func transition(
        to phase: ScenePhase,
        appModel: AppModel,
        keepActiveInBackground: Bool = false
    ) {
        switch phase {
        case .active:
            appModel.isAppActive = true
            appModel.presetManager.refreshBundledPresets()

        case .inactive, .background:
            if !keepActiveInBackground {
                appModel.isAppActive = false
            }
            appModel.saveLastState()
            Task { @MainActor in
                await appModel.audioHub.stopTransientSources()
                await UsageAnalytics.shared.endSession()
            }

        @unknown default:
            break
        }
    }
}
