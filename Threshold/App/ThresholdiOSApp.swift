#if os(iOS)
import SwiftUI

@main
struct ThresholdiOSApp: App {
    @State private var appModel = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        MetricKitReporter.shared.start()
    }

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
    private let controlsAnimation = MenuChrome.panelSpring

    var body: some View {
        GeometryReader { proxy in
            let widths = inspectorColumnWidths(for: proxy.size)

            ThresholdiOSRenderView(appModel: appModel)
                .ignoresSafeArea()
                .background(Color.black)
                .overlay(alignment: .topTrailing) {
                    controlsToggle
                        .padding(16)
                }
                .inspector(isPresented: $isShowingControls) {
                    ThresholdiOSInspectorContent(isShowingControls: $isShowingControls)
                        .environment(appModel)
                        .inspectorColumnWidth(min: widths.min, ideal: widths.ideal, max: widths.max)
                }
                .onSceneLoadAutoHide {
                    // Auto-hide the controls inspector when a scene is selected.
                    // (iPad has no pin concept, so it always collapses.)
                    setControlsVisible(false)
                }
        }
    }

    private func inspectorColumnWidths(for size: CGSize) -> (min: CGFloat, ideal: CGFloat, max: CGFloat) {
        let availableWidth = max(size.width, 1)
        let idealWidth = max(460, availableWidth * (size.width > size.height ? 0.66 : 0.72))
        let minWidth = max(340, idealWidth * 0.72)
        let maxWidth = max(idealWidth, availableWidth * 0.82)
        return (min: minWidth, ideal: idealWidth, max: maxWidth)
    }

    private func setControlsVisible(_ isVisible: Bool) {
        withAnimation(controlsAnimation) {
            isShowingControls = isVisible
        }
    }

    private var controlsToggle: some View {
        Button {
            setControlsVisible(!isShowingControls)
        } label: {
            Image(systemName: isShowingControls ? AppIcons.sliderHorizontal3 : AppIcons.sliderHorizontalBelowRectangle)
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

private struct ThresholdiOSInspectorContent: View {
    @Environment(AppModel.self) private var appModel
    @Binding var isShowingControls: Bool

    private let swipeDismissThreshold: CGFloat = 90

    var body: some View {
        ContentView()
            .environment(appModel)
            .overlay(alignment: .leading) {
                swipeDismissHandle
            }
    }

    private var swipeDismissHandle: some View {
        ZStack {
            LinearGradient(
                colors: [Color.white.opacity(0.14), Color.clear],
                startPoint: .leading,
                endPoint: .trailing
            )

            Capsule()
                .fill(Color.white.opacity(0.32))
                .frame(width: 4, height: 52)
        }
        .frame(width: 26)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 10)
                .onEnded { value in
                    let horizontalDistance = value.translation.width
                    let verticalDistance = abs(value.translation.height)
                    guard horizontalDistance > swipeDismissThreshold,
                          horizontalDistance > verticalDistance * 1.25 else { return }

                    withAnimation(MenuChrome.panelSpring) {
                        isShowingControls = false
                    }
                }
        )
        .accessibilityLabel("Swipe right to dismiss controls")
        .accessibilityAddTraits(.isButton)
    }
}
#endif
