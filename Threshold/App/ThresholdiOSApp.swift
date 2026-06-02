#if os(iOS)
import SwiftUI

@main
struct ThresholdiOSApp: App {
    @State private var appModel = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ThresholdiOSRootView()
                .environment(appModel)
                .onOpenURL { url in
                    appModel.openExternalFile(url)
                }
        }
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

private struct ThresholdiOSRootView: View {
    @Environment(AppModel.self) private var appModel
    @State private var isShowingControls = true

    var body: some View {
        ThresholdiOSRenderView(appModel: appModel)
            .ignoresSafeArea()
            .background(Color.black)
            .overlay(alignment: .topTrailing) {
                controlsToggle
                    .padding(16)
            }
            .inspector(isPresented: $isShowingControls) {
                ContentView()
                    .environment(appModel)
                    .inspectorColumnWidth(min: 520, ideal: 700, max: .infinity)
            }
    }

    private var controlsToggle: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isShowingControls.toggle()
            }
        } label: {
            Image(systemName: isShowingControls ? "slider.horizontal.3" : "slider.horizontal.below.rectangle")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                .foregroundStyle(.primary)
                .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isShowingControls ? "Hide controls" : "Show controls")
    }
}
#endif
