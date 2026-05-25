#if os(macOS)
import AppKit
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
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("Save Preset…") {
                    appModel.openSavePresetMenuHandler?()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(appModel.openSavePresetMenuHandler == nil)
            }
        }
    }
}

private struct ThresholdMacRootView: View {
    @Environment(AppModel.self) private var appModel

    @State private var areControlsVisible = true

    private let contentMinimumSize = CGSize(width: 980, height: 576)
    private let minimumWindowSize = CGSize(width: 1440, height: 640)
    private let panelPreferredWidth: CGFloat = 1040
    private let minimumVisibleViewportWidth: CGFloat = 360
    private let panelPadding: CGFloat = 14
    private let panelMaterialOpacity: Double = 0.68
    private let panelAnimation = Animation.spring(response: 0.35, dampingFraction: 0.85)

    var body: some View {
        GeometryReader { proxy in
            let controlsWidth = controlsPanelWidth(for: proxy.size)

            ZStack(alignment: .topTrailing) {
                ThresholdMacRenderView(appModel: appModel)
                    .frame(minWidth: minimumWindowSize.width, minHeight: minimumWindowSize.height)
                    .background(Color.black)
                    .ignoresSafeArea()

                HStack(spacing: 0) {
                    Spacer(minLength: 0)

                    if areControlsVisible {
                        slideOverPanel
                            .frame(width: controlsWidth)
                            .padding(.vertical, panelPadding)
                            .padding(.trailing, panelPadding)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(panelAnimation, value: areControlsVisible)
                .allowsHitTesting(areControlsVisible)

                floatingToggle
                    .padding(.top, panelPadding)
                    .padding(.trailing, panelPadding)
            }
            .frame(minWidth: minimumWindowSize.width, minHeight: minimumWindowSize.height)
        }
        .frame(minWidth: minimumWindowSize.width, minHeight: minimumWindowSize.height)
    }

    private var slideOverPanel: some View {
        ContentView()
            .environment(appModel)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial.opacity(panelMaterialOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.32), radius: 22, x: -6, y: 8)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var floatingToggle: some View {
        Button {
            toggleControls()
        } label: {
            Image(systemName: areControlsVisible ? "sidebar.trailing" : "sidebar.leading")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(areControlsVisible ? "Hide controls (⌘.)" : "Show controls (⌘.)")
        .keyboardShortcut(".", modifiers: .command)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .foregroundStyle(.primary)
        .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
    }

    private func toggleControls() {
        withAnimation(panelAnimation) {
            areControlsVisible.toggle()
        }
    }

    private func controlsPanelWidth(for size: CGSize) -> CGFloat {
        min(
            panelPreferredWidth,
            max(size.width - minimumVisibleViewportWidth - (panelPadding * 2), contentMinimumSize.width)
        )
    }
}
#endif