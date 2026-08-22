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
            AppLifecycle.transition(to: newPhase, appModel: appModel)
        }
    }
}

private struct ThresholdiOSRootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("hasCompletedIntroOnboarding") private var hasCompletedIntroOnboarding = false
    @State private var isShowingControls = true
    @State private var isAnimationEditorPresented = false
    @State private var isFormulaEditorPresented = false
    @State private var restoreControlsAfterFormulaEditor = false
    @State private var radialMenu = RadialMenuModel(interactionProfile: .touch)
    @State private var radialCurvature = 0.72
    private let controlsAnimation = MenuChrome.panelSpring

    var body: some View {
        GeometryReader { proxy in
            let widths = inspectorColumnWidths(for: proxy.size)
            let safeAreaInsets = proxy.safeAreaInsets

            ThresholdiOSRenderView(appModel: appModel) { location in
                toggleRadialMenu(at: location, viewportSize: proxy.size)
            }
                .ignoresSafeArea()
                .background(Color.black)
                .overlay(alignment: .topTrailing) {
                    if !isFormulaEditorPresented {
                        controlsToggle
                            // The Metal surface stays edge-to-edge, but the control must
                            // clear the status bar and Stage Manager window chrome.
                            .padding(.top, max(16, safeAreaInsets.top + 8))
                            .padding(.trailing, max(16, safeAreaInsets.trailing + 8))
                    }
                }
                .inspector(isPresented: $isShowingControls) {
                    ThresholdiOSInspectorContent(isShowingControls: $isShowingControls)
                        .environment(appModel)
                        .inspectorColumnWidth(min: widths.min, ideal: widths.ideal, max: widths.max)
                }
                .accessibilityAction(named: Text("Open radial controls")) {
                    toggleRadialMenu(
                        at: CGPoint(x: proxy.size.width * 0.5, y: proxy.size.height * 0.5),
                        viewportSize: proxy.size
                    )
                }
                // The radial menu is a modal interaction surface. Keep the
                // covered Metal view, inspector, and controls button out of
                // VoiceOver traversal until the menu is dismissed.
                .accessibilityHidden(radialMenu.isPresented)
                .overlay {
                    if radialMenu.isPresented {
                        RadialMenu(
                            size: proxy.size,
                            pointerAnchor: radialMenu.anchor,
                            curvature: $radialCurvature,
                            projection: radialProjection,
                            interactionProfile: radialMenu.interactionProfile,
                            allowsPresentationSelection: false,
                            path: Binding(
                                get: { radialMenu.path },
                                set: { radialMenu.path = $0 }
                            ),
                            sceneAccent: RadialMenuSceneAccent.color(
                                from: appModel.renderSettings.gradientColorMap
                            ),
                            suspendsHoverNavigation: false,
                            hoveredSlider: Binding(
                                get: { radialMenu.hoveredSlider },
                                set: { radialMenu.hoveredSlider = $0 }
                            ),
                            onSliderEditingChanged: { editing in
                                if editing { appModel.beginMenuAdjustment() }
                                else { appModel.endMenuAdjustment() }
                            },
                            onSelectPresentation: { _ in },
                            onDismiss: dismissRadialMenu
                        )
                        .transition(.opacity)
                        .zIndex(10)
                    }
                }
                .onSceneLoadAutoHide {
                    // Auto-hide the controls inspector when a scene is selected.
                    // (iPad has no pin concept, so it always collapses.)
                    setControlsVisible(false)
                }
                .onDisappear(perform: dismissRadialMenu)
        }
        .overlay {
            if isFormulaEditorPresented {
                FormulaEditorWindowView(onClose: dismissFormulaEditor)
                    .environment(appModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Safety and privacy setup (photosensitivity acknowledgement, microphone,
        // analytics, storage). Mirrors the macOS/visionOS gate; the cover cannot
        // be swiped away and only `FirstLaunchWindowView` completes it.
        .fullScreenCover(isPresented: Binding(
            get: { !hasCompletedIntroOnboarding },
            set: { _ in }
        )) {
            FirstLaunchWindowView()
                .environment(appModel)
                .interactiveDismissDisabled()
        }
        .fullScreenCover(isPresented: $isAnimationEditorPresented) {
            AnimationEditorWindowView()
                .environment(appModel)
        }
        .onAppear {
            appModel.openFormulaEditorHandler = presentFormulaEditor
            appModel.openAnimationEditorHandler = presentAnimationEditor
            appModel.dismissAnimationEditorHandler = { isAnimationEditorPresented = false }
            // External-file imports (Files app, Share sheet) surface their
            // sheet, progress, and errors inside the inspector's ContentView.
            // Let AppModel.ensureWindowContentVisible() reveal it on iPad.
            appModel.openMenuWindowHandler = { setControlsVisible(true) }
            syncMenuWindowVisibility(isShowingControls)
            Task { @MainActor in
                await appModel.startMicrophoneAtLaunchIfEnabled()
            }
        }
        .onChange(of: isShowingControls) { _, isVisible in
            syncMenuWindowVisibility(isVisible)
        }
        .onDisappear {
            appModel.openFormulaEditorHandler = nil
            appModel.openAnimationEditorHandler = nil
            appModel.dismissAnimationEditorHandler = nil
            appModel.openMenuWindowHandler = nil
        }
    }

    /// Keep AppModel's window-visibility model truthful on iPad so
    /// `ensureWindowContentVisible()` re-presents the inspector instead of
    /// assuming its content is already on screen.
    private func syncMenuWindowVisibility(_ isVisible: Bool) {
        if isVisible {
            if !appModel.isMenuWindowVisible { appModel.markMenuWindowPresented() }
        } else if appModel.isMenuWindowVisible {
            appModel.markMenuWindowDismissed()
        }
    }

    private func presentAnimationEditor() {
        guard let animationManager = appModel.animationManager else { return }
        if animationManager.currentScene == nil {
            animationManager.currentScene = animationManager.scenes.first
        }
        dismissRadialMenu()
        isAnimationEditorPresented = true
    }

    private var radialProjection: RadialNavigationProjection {
        RadialMenuProjectionFactory.make(appModel: appModel) { target in
            activateRadialTarget(target)
        }
    }

    private func toggleRadialMenu(at location: CGPoint, viewportSize: CGSize) {
        if radialMenu.isPresented {
            dismissRadialMenu()
            return
        }
        guard appModel.inputOwnershipStore.claim(.radialMenu) else { return }
        setControlsVisible(false)
        appModel.controlStateStore.startSync(with: appModel.renderSettings, appModel: appModel)
        let anchor = CGPoint(
            x: min(max(location.x, 24), max(24, viewportSize.width - 24)),
            y: min(max(location.y, 32), max(32, viewportSize.height - 32))
        )
        let route = appModel.navigationStore.currentRoute
        let projection = radialProjection
        var preferredPath = route.workspaceRoot.map {
            [NavigationHierarchy.rootID(for: $0)]
        } ?? []
        // Route controls are flattened for touch, so opening directly to the
        // current route exposes its most useful controls with no traversal.
        // Reconciliation naturally falls back to the workspace (or root menu)
        // when the route has no quick-input branch.
        preferredPath.append(route.stableID)
        let initialPath = projection.reconciledPath(preferredPath)
        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)) {
            radialMenu.present(at: anchor, initialPath: initialPath)
        }
    }

    private func dismissRadialMenu() {
        guard radialMenu.isPresented else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
            radialMenu.dismiss()
        }
        appModel.controlStateStore.stopSync()
        appModel.inputOwnershipStore.release(.radialMenu)
    }

    private func presentFormulaEditor() {
        guard !isFormulaEditorPresented else { return }
        restoreControlsAfterFormulaEditor = isShowingControls
        dismissRadialMenu()
        // This must happen without animation: the transparent presentation
        // should reveal only the Metal viewport on its very first frame.
        isShowingControls = false
        isFormulaEditorPresented = true
    }

    private func dismissFormulaEditor() {
        isFormulaEditorPresented = false
        if restoreControlsAfterFormulaEditor {
            setControlsVisible(true)
        }
        restoreControlsAfterFormulaEditor = false
    }

    private func activateRadialTarget(_ target: AppNavigationTarget) {
        let command = appModel.navigationStore.activate(target)
        switch command {
        case .openAnimationEditor:
            presentAnimationEditor()
        case .resetViewport:
            appModel.viewportCommandHandler?(.resetViewport)
            dismissRadialMenu()
        case .dismissRadialMenu, .toggleRadialMenu:
            dismissRadialMenu()
        case .toggleAnimationPlayback, .selectRoute:
            dismissRadialMenu()
        case nil:
            dismissRadialMenu()
            setControlsVisible(true)
        }
    }

    private func inspectorColumnWidths(for size: CGSize) -> (min: CGFloat, ideal: CGFloat, max: CGFloat) {
        let availableWidth = max(size.width, 1)
        // Leave a little room for the system's window/inspector chrome and never
        // advertise a column wider than the current Stage Manager/Split View
        // window. The normal 340-point floor yields only when the window is
        // genuinely narrower than that.
        let widthCeiling = max(1, availableWidth - 32)
        let preferredIdeal = max(460, availableWidth * (size.width > size.height ? 0.66 : 0.72))
        let idealWidth = min(preferredIdeal, widthCeiling)
        let minWidth = min(340, idealWidth)
        let maxWidth = min(widthCeiling, max(idealWidth, availableWidth * 0.82))
        return (min: minWidth, ideal: idealWidth, max: maxWidth)
    }

    private func setControlsVisible(_ isVisible: Bool) {
        withAnimation(reduceMotion ? nil : controlsAnimation) {
            isShowingControls = isVisible
        }
    }

    private var controlsToggle: some View {
        Button {
            setControlsVisible(!isShowingControls)
        } label: {
            Label(
                isShowingControls ? "Hide Controls" : "Controls",
                systemImage: isShowingControls ? AppIcons.sliderHorizontal3 : AppIcons.sliderHorizontalBelowRectangle
            )
                .font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                .foregroundStyle(.primary)
                .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isShowingControls ? "Hide controls" : "Show controls")
    }
}

private struct ThresholdiOSInspectorContent: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isShowingControls: Bool

    private let swipeDismissThreshold: CGFloat = 90

    var body: some View {
        ContentView()
            .environment(appModel)
            // The controls always live in an inspector column, even when the
            // enclosing iPad window has a regular size class. Mark the column
            // compact so ContentView selects its rail-free responsive shell.
            .environment(\.horizontalSizeClass, .compact)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

                    withAnimation(reduceMotion ? nil : MenuChrome.panelSpring) {
                        isShowingControls = false
                    }
                }
        )
        .accessibilityLabel("Swipe right to dismiss controls")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Dismisses the control inspector")
        .accessibilityAction {
            withAnimation(reduceMotion ? nil : MenuChrome.panelSpring) {
                isShowingControls = false
            }
        }
    }
}
#endif
