#if os(iOS)
import SwiftUI
import UIKit

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
    // Start phone users on the artwork. Phone quick controls are opened with
    // an intentional edge swipe; iPad keeps its visible side panel.
    @State private var isShowingControls = UIDevice.current.userInterfaceIdiom != .phone
    @State private var isAnimationEditorPresented = false
    @State private var isFormulaEditorPresented = false
    @State private var restoreControlsAfterFormulaEditor = false
    @State private var radialMenu = RadialMenuModel(interactionProfile: .touch)
    @State private var radialCurvature = 0.72
    @State private var isStartupCoverVisible = true
    private let controlsAnimation = MenuChrome.panelSpring

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    var body: some View {
        rootViewport
            .overlay {
                if isFormulaEditorPresented {
                    FormulaEditorWindowView(onClose: dismissFormulaEditor)
                        .environment(appModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .overlay {
                if isStartupCoverVisible {
                    startupCover
                        .transition(.opacity)
                        .zIndex(100)
                }
            }
            .task(id: appModel.rendererStartupWarmupComplete) {
                guard appModel.rendererStartupWarmupComplete else {
                    isStartupCoverVisible = true
                    return
                }

                // Pipeline readiness precedes the first visible Metal frame. Keep
                // the cover through that handoff so startup never flashes the
                // clear surface or a stale renderer snapshot.
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                    isStartupCoverVisible = false
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
                // Let AppModel.ensureWindowContentVisible() reveal it on iOS.
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

    private var rootViewport: some View {
        GeometryReader { proxy in
            let widths = inspectorColumnWidths(for: proxy.size)
            let safeAreaInsets = proxy.safeAreaInsets

            ThresholdiOSRenderView(
                appModel: appModel,
                prioritizesControlUpdates: isShowingControls
                    || radialMenu.isPresented
                    || isFormulaEditorPresented
                    || isAnimationEditorPresented,
                onRadialMenuRequest: { location in
                    toggleRadialMenu(at: location, viewportSize: proxy.size)
                }
            )
                .ignoresSafeArea()
                .background(Color.black)
                .overlay(alignment: .topTrailing) {
                    if !isFormulaEditorPresented && (isPhone || !isShowingControls) {
                        phoneAwareControls(
                            viewportSize: proxy.size,
                            safeAreaInsets: safeAreaInsets
                        )
                            // This overlay is already inside the window safe area.
                            .padding(.top, isPhone ? 4 : 8)
                            .padding(.trailing, isPhone ? 10 : 16)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottom) {
                    VStack(spacing: 8) {
                        if appModel.presetManager.isIndexingPresetFiles {
                            fileIndexingBanner
                                .transition(.opacity)
                        }
                        if !appModel.rendererStartupWarmupComplete && !isPhone {
                            shaderCompileBanner
                                .transition(.opacity)
                        }
                    }
                    .padding(.bottom, max(24, safeAreaInsets.bottom + 12))
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: appModel.rendererStartupWarmupComplete)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: appModel.presetManager.isIndexingPresetFiles)
                .modifier(ThresholdiOSControlsPresentation(
                    isShowingControls: $isShowingControls,
                    isPhone: isPhone,
                    widths: widths
                ))
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
                            layout: UIDevice.current.userInterfaceIdiom == .phone ? .straightEdge : .radial,
                            allowsPresentationSelection: false,
                            path: Binding(
                                get: { radialMenu.path },
                                set: { radialMenu.path = $0 }
                            ),
                            sceneAccent: RadialMenuSceneAccent.color(
                                from: appModel.renderSettings.gradientColorMap
                            ),
                            quickAccessShortcuts: RadialMenuProjectionFactory.quickAccessShortcuts(
                                pinnedRouteIDs: appModel.navigationStore.pinnedRouteIDs,
                                selectedRoute: appModel.navigationStore.currentRoute
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
                            onActivateQuickAccess: { route in
                                activateQuickAccessRoute(route)
                            },
                            onDismiss: dismissRadialMenu
                        )
                        .transition(.opacity)
                        .zIndex(10)
                    }
                }
                .onSceneLoadAutoHide {
                    // Auto-hide the controls inspector when a scene is selected.
                    // iOS has no pin concept, so it always collapses.
                    setControlsVisible(false)
                }
                .sceneNavigationFeedbackOverlay(
                    isObscured: radialMenu.isPresented
                        || isFormulaEditorPresented
                        || isAnimationEditorPresented,
                    instruction: "Three-finger swipe · Swipe card",
                    bottomPadding: max(24, safeAreaInsets.bottom + 12)
                )
                .onDisappear(perform: dismissRadialMenu)
        }
    }

    /// Keep AppModel's window-visibility model truthful on iOS so
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
        presentRadialMenu(at: location, viewportSize: viewportSize)
    }

    private func presentRadialMenu(at location: CGPoint, viewportSize: CGSize) {
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

    /// Pinned items are explicit section shortcuts, so unlike a radial leaf
    /// interaction they always reveal the inspector that contains the route.
    private func activateQuickAccessRoute(_ route: AppRoute) {
        appModel.navigationStore.select(route)
        dismissRadialMenu()
        setControlsVisible(true)
    }

    private func inspectorColumnWidths(for size: CGSize) -> (min: CGFloat, ideal: CGFloat, max: CGFloat) {
        let availableWidth = max(size.width, 1)
        // Keep the iPad panel readable without covering most of the artwork.
        // A narrow Stage Manager/Split View window can use its full width;
        // the phone inspector still leaves room for system sheet chrome.
        let widthCeiling = isPhone ? max(1, availableWidth - 32) : availableWidth
        // Give iPad's inspector enough room for its section controls and dense
        // parameter rows. The former 620pt cap made it feel like a narrow
        // floating drawer on larger iPads; keep a generous width while leaving
        // a useful slice of the canvas visible on either orientation.
        let preferredIdeal = isPhone ? max(460, availableWidth * 0.72) : min(760, max(560, availableWidth * 0.76))
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

    /// Shown while the renderer's generic pipeline is still compiling. On a
    /// cold GPU shader cache (first launch, OS update) this takes several
    /// seconds on iPad; without feedback the black viewport reads as a hang.
    private var shaderCompileBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Compiling shaders — first launch may take a moment…")
                .font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
    }

    private var fileIndexingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Indexing files…")
                .font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.cyan.opacity(0.35), lineWidth: 1))
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Indexing preset files")
    }

    /// App-owned half of the launch handoff. The system launch storyboard is
    /// necessarily brief; this cover remains visible while the first Metal
    /// pipeline and drawable become ready, which is the interval users
    /// perceive as the splash screen on a cold launch.
    private var startupCover: some View {
        ZStack {
            Color(red: 0.005, green: 0.006, blue: 0.008)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image("LaunchWindowIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 8)

                ProgressView()
                    .tint(.white.opacity(0.82))
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Threshold is starting")
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

    @ViewBuilder
    private func phoneAwareControls(
        viewportSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> some View {
        if isPhone {
            HStack(spacing: 8) {
                Button {
                    toggleRadialMenu(
                        at: CGPoint(
                            x: viewportSize.width,
                            y: max(safeAreaInsets.top + 88, viewportSize.height * 0.34)
                        ),
                        viewportSize: viewportSize
                    )
                } label: {
                    Image(systemName: "circle.grid.cross")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                        .foregroundStyle(.primary)
                        .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open radial controls")

                controlsToggle
            }
        } else {
            controlsToggle
        }
    }
}

/// iPad scene selection auto-hides the controls. Keeping its panel in the
/// SwiftUI hierarchy avoids a UIKit split-view dismissal while the scene load
/// updates the explorer and viewport. The native adaptive inspector remains
/// useful on phones, where it supplies sheet detents and dismissal gestures.
private struct ThresholdiOSControlsPresentation: ViewModifier {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var sliderPreview = ParameterSliderPreview()
    @Binding var isShowingControls: Bool
    let isPhone: Bool
    let widths: (min: CGFloat, ideal: CGFloat, max: CGFloat)

    @ViewBuilder
    func body(content: Content) -> some View {
        if isPhone {
            content.inspector(isPresented: $isShowingControls) {
                ThresholdiOSInspectorContent()
                    .inspectorColumnWidth(min: widths.min, ideal: widths.ideal, max: widths.max)
            }
        } else {
            content.overlay(alignment: .trailing) {
                if isShowingControls {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Controls")
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            Spacer()
                            Button {
                                withAnimation(reduceMotion ? nil : MenuChrome.panelSpring) {
                                    isShowingControls = false
                                }
                            } label: {
                                Image(systemName: "sidebar.right")
                                    .font(.system(size: 20, weight: .medium))
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Hide controls")
                            .help("Hide controls")
                        }
                        .padding(.leading, 20)
                        .padding(.trailing, 8)
                        .padding(.vertical, 4)
                        Divider()
                        ThresholdiOSInspectorContent()
                            .environment(\.parameterSliderPreview, sliderPreview)
                    }
                    .frame(width: widths.ideal)
                    .frame(maxHeight: .infinity)
                    .background {
                        Rectangle()
                            .fill(.regularMaterial)
                            // Extend only the surface under status/home chrome;
                            // the title and controls stay in the usable safe area.
                            .ignoresSafeArea(.container, edges: [.top, .bottom, .trailing])
                    }
                    .overlay(alignment: .leading) {
                        Divider()
                            .ignoresSafeArea(.container, edges: .vertical)
                            .allowsHitTesting(false)
                    }
                    // Keep the exact same controls and hit targets throughout
                    // the drag, including when previewing the artwork beneath.
                    .opacity(appModel.isAudioReactivityIsolationPreviewActive ? 0 :
                        (sliderPreview.isAdjusting && !reduceTransparency ? 0.12 : 1))
                    // SwiftUI can exclude low-opacity views from automatic hit
                    // testing. Keep touch-up delivery explicit during preview.
                    .allowsHitTesting(true)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18),
                               value: sliderPreview.isAdjusting)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }
}

private struct ThresholdiOSInspectorContent: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ContentView()
            .environment(appModel)
            // The controls live in a side panel or inspector column, even when
            // the enclosing iPad window has a regular size class. Mark the column
            // compact so ContentView selects its rail-free responsive shell.
            .environment(\.horizontalSizeClass, .compact)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // `inspector` adapts to a sheet on iPhone. Medium is useful for
            // quick adjustments while preserving the live canvas; large gives
            // dense editors the full available workspace.
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            // Keep the inspector mounted during a hold so its gesture receives
            // the release edge, but make its presentation transparent to show
            // the renderer beneath the Audio Reactivity preview.
            .presentationBackground(.clear)
            .opacity(appModel.isAudioReactivityIsolationPreviewActive ? 0 : 1)
    }
}
#endif
