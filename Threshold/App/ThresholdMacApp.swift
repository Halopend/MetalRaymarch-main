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
    }
}

private enum ThresholdMacControlsOverride {
    case automatic
    case forcedVisible
    case forcedHiddenUntilReset
}

private struct ThresholdMacRootView: View {
    @Environment(AppModel.self) private var appModel

    @State private var controlsOverride: ThresholdMacControlsOverride = .automatic
    @State private var isAutoVisible = false

    private let contentMinimumSize = CGSize(width: 980, height: 576)
    private let minimumWindowSize = CGSize(width: 1440, height: 640)
    private let panelPreferredWidth: CGFloat = 1040
    private let minimumVisibleViewportWidth: CGFloat = 360
    private let panelPadding: CGFloat = 14
    private let revealHotZoneWidth: CGFloat = 28
    private let panelAnimation = Animation.spring(response: 0.35, dampingFraction: 0.85)

    private var isControlsVisible: Bool {
        switch controlsOverride {
        case .automatic:
            return isAutoVisible
        case .forcedVisible:
            return true
        case .forcedHiddenUntilReset:
            return false
        }
    }

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

                    if isControlsVisible {
                        slideOverPanel
                            .frame(width: controlsWidth)
                            .padding(.vertical, panelPadding)
                            .padding(.trailing, panelPadding)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(panelAnimation, value: isControlsVisible)
                .allowsHitTesting(isControlsVisible)

                floatingToggle
                    .padding(.top, panelPadding)
                    .padding(.trailing, panelPadding)

                ThresholdMacMouseTrackingView(
                    onMouseMoved: { point in
                        updateAutoVisibility(for: point, in: proxy.size, controlsWidth: controlsWidth)
                    },
                    onMouseExited: {
                        handleMouseExit()
                    }
                )
            }
            .frame(minWidth: minimumWindowSize.width, minHeight: minimumWindowSize.height)
        }
        .frame(minWidth: minimumWindowSize.width, minHeight: minimumWindowSize.height)
    }

    private var slideOverPanel: some View {
        ContentView()
            .environment(appModel)
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 22, x: -6, y: 8)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var floatingToggle: some View {
        Button {
            toggleControls()
        } label: {
            Image(systemName: isControlsVisible ? "sidebar.trailing" : "sidebar.leading")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(isControlsVisible ? "Hide controls (⌘.)" : "Show controls (⌘.)")
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
            if isControlsVisible {
                isAutoVisible = false
                controlsOverride = .forcedHiddenUntilReset
            } else {
                controlsOverride = .forcedVisible
            }
        }
    }

    private func updateAutoVisibility(for point: CGPoint, in size: CGSize, controlsWidth: CGFloat) {
        let revealFrame = CGRect(x: max(size.width - revealHotZoneWidth, 0), y: 0, width: revealHotZoneWidth, height: size.height)

        if controlsOverride == .forcedHiddenUntilReset, !revealFrame.contains(point) {
            controlsOverride = .automatic
        }

        guard controlsOverride == .automatic else { return }

        let panelFrame = controlsPanelFrame(in: size, controlsWidth: controlsWidth)
        let shouldShowControls: Bool

        if isAutoVisible {
            shouldShowControls = panelFrame.contains(point)
        } else {
            shouldShowControls = revealFrame.contains(point)
        }

        guard shouldShowControls != isAutoVisible else { return }

        withAnimation(panelAnimation) {
            isAutoVisible = shouldShowControls
        }
    }

    private func handleMouseExit() {
        withAnimation(panelAnimation) {
            if controlsOverride == .forcedHiddenUntilReset {
                controlsOverride = .automatic
            }

            if controlsOverride == .automatic {
                isAutoVisible = false
            }
        }
    }

    private func controlsPanelWidth(for size: CGSize) -> CGFloat {
        min(
            panelPreferredWidth,
            max(size.width - minimumVisibleViewportWidth - (panelPadding * 2), contentMinimumSize.width)
        )
    }

    private func controlsPanelFrame(in size: CGSize, controlsWidth: CGFloat) -> CGRect {
        CGRect(
            x: max(size.width - controlsWidth - panelPadding, 0),
            y: panelPadding,
            width: controlsWidth,
            height: max(size.height - (panelPadding * 2), 0)
        )
    }
}

private struct ThresholdMacMouseTrackingView: NSViewRepresentable {
    let onMouseMoved: (CGPoint) -> Void
    let onMouseExited: () -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMouseMoved = onMouseMoved
        view.onMouseExited = onMouseExited
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onMouseMoved = onMouseMoved
        nsView.onMouseExited = onMouseExited
    }
}

private final class TrackingView: NSView {
    var onMouseMoved: ((CGPoint) -> Void)?
    var onMouseExited: (() -> Void)?

    private var activeTrackingArea: NSTrackingArea?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let activeTrackingArea {
            removeTrackingArea(activeTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        )

        addTrackingArea(trackingArea)
        activeTrackingArea = trackingArea
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func mouseEntered(with event: NSEvent) {
        reportMousePosition(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        reportMousePosition(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }

    private func reportMousePosition(for event: NSEvent) {
        onMouseMoved?(convert(event.locationInWindow, from: nil))
    }
}
#endif