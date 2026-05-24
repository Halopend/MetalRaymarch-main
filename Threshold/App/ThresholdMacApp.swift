#if os(macOS)
import SwiftUI

@main
struct ThresholdMacApp: App {
    @State private var appModel = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window("Threshold", id: appModel.menuWindowID) {
            ThresholdMacRootView()
                .environment(appModel)
                .onOpenURL { url in
                    appModel.openExternalFile(url)
                }
        }
        .defaultSize(width: 1780, height: 920)
        .windowResizability(.contentMinSize)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                appModel.isAppActive = true
                appModel.presetManager.refreshBundledPresets()
            } else if newPhase == .background || newPhase == .inactive {
                appModel.isAppActive = false
                appModel.saveLastState()
                Task { await UsageAnalytics.shared.endSession() }
            }
        }
    }
}

private struct ThresholdMacRootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        HStack(spacing: 0) {
            ThresholdMacRenderView(appModel: appModel)
                .frame(minWidth: 720, minHeight: 520)
                .background(Color.black)

            Divider()

            ContentView()
                .environment(appModel)
                .frame(minWidth: 980, idealWidth: 1040)
                .frame(maxHeight: .infinity)
        }
    }
}
#endif