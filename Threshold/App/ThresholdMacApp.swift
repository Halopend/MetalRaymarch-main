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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isControlsPinnedOpen = false
    @State private var isHoverVisible = true
    @State private var isPaneHovering = false
    @State private var isEdgeRevealHovering = false
    @State private var activeMenuTrackingCount = 0
    @State private var pendingAutoHide: DispatchWorkItem?

    private let contentMinimumSize = CGSize(width: 980, height: 576)
    private let minimumWindowSize = CGSize(width: 1440, height: 640)
    private let panelPreferredWidth: CGFloat = 1040
    private let minimumVisibleViewportWidth: CGFloat = 360
    private let panelPadding: CGFloat = 14
    private let edgeRevealWidth: CGFloat = 30
    private let panelMaterialOpacity: Double = 0.68
    private let autoHideDelay: TimeInterval = 0.22
    private let panelAnimation = Animation.spring(response: 0.35, dampingFraction: 0.85)

    private var shouldShowControls: Bool {
        isControlsPinnedOpen || isHoverVisible || appModel.isMenuInteractionActive || activeMenuTrackingCount > 0
    }

    private var motionSensitivePanelAnimation: Animation? {
        reduceMotion ? nil : panelAnimation
    }

    private var panelTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity)
    }

    var body: some View {
        GeometryReader { proxy in
            let controlsWidth = controlsPanelWidth(for: proxy.size)

            ZStack(alignment: .topTrailing) {
                ThresholdMacRenderView(appModel: appModel)
                    .frame(minWidth: minimumWindowSize.width, minHeight: minimumWindowSize.height)
                    .background(Color.black)
                    .ignoresSafeArea()

                edgeRevealZone

                HStack(spacing: 0) {
                    Spacer(minLength: 0)

                    if shouldShowControls {
                        controlsHoverRegion(width: controlsWidth)
                            .padding(.vertical, panelPadding)
                            .transition(panelTransition)
                    }
                }
                .animation(motionSensitivePanelAnimation, value: shouldShowControls)
                .allowsHitTesting(shouldShowControls)

                floatingToggle
                    .padding(.top, panelPadding)
                    .padding(.trailing, panelPadding)
            }
            .frame(minWidth: minimumWindowSize.width, minHeight: minimumWindowSize.height)
        }
        .frame(minWidth: minimumWindowSize.width, minHeight: minimumWindowSize.height)
        .onChange(of: appModel.isMenuInteractionActive) { _, _ in
            updateAutoHideState(animated: true)
        }
        .onChange(of: appModel.menuAutoHideRequestID) { _, _ in
            // Auto-hide the controls panel when a scene is selected — unless pinned.
            guard !isControlsPinnedOpen else { return }
            pendingAutoHide?.cancel()
            pendingAutoHide = nil
            setHoverVisible(false, animated: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            activeMenuTrackingCount += 1
            showControls(animated: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            activeMenuTrackingCount = max(0, activeMenuTrackingCount - 1)
            updateAutoHideState(animated: true)
        }
        .onDisappear {
            pendingAutoHide?.cancel()
            pendingAutoHide = nil
        }
    }

    private var slideOverPanel: some View {
        ContentView()
            .environment(appModel)
            .frame(maxHeight: .infinity)
            .background(
                ZStack {
                    MacWindowMaterialBackground(material: .sidebar)
                        .opacity(panelMaterialOpacity)

                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.white.opacity(0.035))
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.32), radius: 22, x: -6, y: 8)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func controlsHoverRegion(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            slideOverPanel
                .frame(width: width)

            Color.clear
                .frame(width: panelPadding)
        }
        .contentShape(Rectangle())
        .onHover(perform: handlePaneHover)
    }

    private var edgeRevealZone: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            Rectangle()
                .fill(Color.clear)
                .frame(width: edgeRevealWidth)
                .contentShape(Rectangle())
                .onHover(perform: handleEdgeRevealHover)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var floatingToggle: some View {
        Button {
            toggleControlsPin()
        } label: {
            Image(systemName: isControlsPinnedOpen ? AppIcons.pinFill : AppIcons.pin)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(isControlsPinnedOpen ? "Unpin controls (⌘.)" : "Pin controls open (⌘.)")
        .keyboardShortcut(".", modifiers: .command)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .foregroundStyle(.primary)
        .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
    }

    private func handlePaneHover(_ hovering: Bool) {
        isPaneHovering = hovering
        if hovering {
            showControls(animated: true)
        } else {
            updateAutoHideState(animated: true)
        }
    }

    private func handleEdgeRevealHover(_ hovering: Bool) {
        isEdgeRevealHovering = hovering
        if hovering {
            showControls(animated: true)
        } else {
            updateAutoHideState(animated: true)
        }
    }

    private func toggleControlsPin() {
        pendingAutoHide?.cancel()
        pendingAutoHide = nil

        withMotionSensitivePanelAnimation {
            isControlsPinnedOpen.toggle()
            if isControlsPinnedOpen {
                isHoverVisible = true
            }
        }

        if !isControlsPinnedOpen {
            updateAutoHideState(animated: true)
        }
    }

    private func showControls(animated: Bool) {
        pendingAutoHide?.cancel()
        pendingAutoHide = nil
        setHoverVisible(true, animated: animated)
    }

    private func updateAutoHideState(animated: Bool) {
        pendingAutoHide?.cancel()
        pendingAutoHide = nil

        guard !isControlsPinnedOpen,
              !isPaneHovering,
              !isEdgeRevealHovering,
              !appModel.isMenuInteractionActive,
              activeMenuTrackingCount == 0 else {
            setHoverVisible(true, animated: animated)
            return
        }

        let workItem = DispatchWorkItem {
            guard !isControlsPinnedOpen,
                  !isPaneHovering,
                  !isEdgeRevealHovering,
                  !appModel.isMenuInteractionActive,
                  activeMenuTrackingCount == 0 else {
                return
            }

            setHoverVisible(false, animated: true)
        }

        pendingAutoHide = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + autoHideDelay, execute: workItem)
    }

    private func setHoverVisible(_ visible: Bool, animated: Bool) {
        guard isHoverVisible != visible else { return }

        if animated {
            withMotionSensitivePanelAnimation {
                isHoverVisible = visible
            }
        } else {
            isHoverVisible = visible
        }
    }

    private func withMotionSensitivePanelAnimation(_ updates: () -> Void) {
        if reduceMotion {
            updates()
        } else {
            withAnimation(panelAnimation, updates)
        }
    }

    private func controlsPanelWidth(for size: CGSize) -> CGFloat {
        min(
            panelPreferredWidth,
            max(contentMinimumSize.width, size.width - minimumVisibleViewportWidth)
        )
    }
}

private struct MacWindowMaterialBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = .withinWindow
        view.state = .active
        view.isEmphasized = false
    }
}
#endif