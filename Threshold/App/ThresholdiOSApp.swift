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
    @AppStorage("RadialMenu.enabled") private var radialMenuEnabled = false
    // Start phone users on the artwork; iPad keeps its visible side panel.
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
            .onChange(of: radialMenuEnabled) { _, isEnabled in
                if !isEnabled { dismissRadialMenu() }
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
                    guard radialMenuEnabled else { return }
                    toggleRadialMenu(at: location, viewportSize: proxy.size)
                }
            )
                .ignoresSafeArea()
                .background(Color.black)
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
                    widths: widths,
                    safeAreaInsets: safeAreaInsets
                ))
                // Keep the launch button inside the safe area. The canvas
                // ignores it, so adding the safe-area inset again pushed this
                // control too far down on iPhone.
                .overlay(alignment: .topTrailing) {
                    if !isFormulaEditorPresented && !isShowingControls {
                        controlsToggle
                            .padding(.top, isPhone ? 4 : 8)
                            .padding(.trailing, isPhone ? max(10, safeAreaInsets.trailing + 10) : 16)
                            .transition(.opacity)
                    }
                }
                .accessibilityAction(named: Text("Open controls")) { setControlsVisible(true) }
                // The radial menu is a modal interaction surface. Keep the
                // covered Metal view, inspector, and controls button out of
                // VoiceOver traversal until the menu is dismissed.
                .accessibilityHidden(radialMenu.isPresented)
                .overlay {
                    if radialMenuEnabled && radialMenu.isPresented {
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
        guard radialMenuEnabled else { return }
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
        if isVisible { dismissRadialMenu() }
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
            Image(systemName: AppIcons.sliderHorizontalBelowRectangle)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .foregroundStyle(.primary)
                .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show controls")
        .accessibilityHint("Opens the scene controls panel.")
    }

}

/// iPad scene selection auto-hides the controls. Keeping its panel in the
/// SwiftUI hierarchy avoids a UIKit split-view dismissal while the scene load
/// updates the explorer and viewport.
/// On phones, the same content sits in a bottom panel that can be dismissed
/// by dragging its handle down.
private struct ThresholdiOSControlsPresentation: ViewModifier {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sliderPreview = ParameterSliderPreview()
    @State private var phoneControlsExpanded = false
    @Binding var isShowingControls: Bool
    let isPhone: Bool
    let widths: (min: CGFloat, ideal: CGFloat, max: CGFloat)
    let safeAreaInsets: EdgeInsets

    @ViewBuilder
    func body(content: Content) -> some View {
        if isPhone {
            content
                // Keep the renderer visible and undimmed beneath the controls.
                .allowsHitTesting(!isShowingControls)
                .overlay {
                    GeometryReader { geometry in
                        if isShowingControls {
                            let availableHeight = max(0, geometry.size.height - safeAreaInsets.top)
                            let panelHeight = min(availableHeight,
                                                  max(320, availableHeight * (phoneControlsExpanded ? 0.94 : 0.78)))

                            VStack(spacing: 0) {
                                Button {
                                    withAnimation(reduceMotion ? nil : MenuChrome.panelSpring) {
                                        isShowingControls = false
                                        phoneControlsExpanded = false
                                    }
                                } label: {
                                    Capsule()
                                        .fill(Color.white.opacity(0.5))
                                        .frame(width: 36, height: 5)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 24)
                                        .padding(.top, 4)
                                }
                                .buttonStyle(.plain)
                                .contentShape(Rectangle())
                                .simultaneousGesture(DragGesture(minimumDistance: 12).onEnded { gesture in
                                    withAnimation(reduceMotion ? nil : MenuChrome.panelSpring) {
                                        if gesture.translation.height < -36 {
                                            phoneControlsExpanded = true
                                        } else if gesture.translation.height > 60 {
                                            if phoneControlsExpanded { phoneControlsExpanded = false }
                                            else { isShowingControls = false }
                                        }
                                    }
                                })
                                .accessibilityLabel("Hide controls")

                                ThresholdiOSInspectorContent()
                                    .environment(\.parameterSliderPreview, sliderPreview)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .opacity(appModel.isAudioReactivityIsolationPreviewActive ? 0 : 1)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: panelHeight, alignment: .top)
                            .padding(.bottom, safeAreaInsets.bottom)
                            .background {
                                UnevenRoundedRectangle(
                                    cornerRadii: RectangleCornerRadii(
                                        topLeading: 20,
                                        bottomLeading: 0,
                                        bottomTrailing: 0,
                                        topTrailing: 20
                                    ),
                                    style: .continuous
                                )
                                    .fill(.regularMaterial)
                                    .ignoresSafeArea(.container, edges: .bottom)
                            }
                            // The inspector overlay is aligned to the safe-area
                            // bottom. Continue its surface over the home-indicator
                            // inset so the artwork cannot show through below it.
                            .overlay(alignment: .bottom) {
                                if safeAreaInsets.bottom > 0 {
                                    Rectangle()
                                        .fill(.regularMaterial)
                                        .frame(height: safeAreaInsets.bottom)
                                        .offset(y: safeAreaInsets.bottom)
                                        .allowsHitTesting(false)
                                }
                            }
                            .environment(\.colorScheme, .dark)
                            .shadow(color: .black.opacity(0.18), radius: 16, y: -4)
                            .modifier(ThresholdSliderFocusPresentation(preview: sliderPreview))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
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
                                    .font(.system(size: 16, weight: .medium))
                                    .frame(width: 36, height: 36)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Hide controls")
                            .help("Hide controls")
                        }
                        .padding(.leading, 20)
                        .padding(.trailing, 8)
                        .padding(.top, max(8, safeAreaInsets.top + 8))
                        .padding(.bottom, 8)
                        Divider()
                        ThresholdiOSInspectorContent()
                            .environment(\.parameterSliderPreview, sliderPreview)
                    }
                    .frame(width: widths.ideal)
                    .frame(maxHeight: .infinity)
                    .padding(.bottom, safeAreaInsets.bottom)
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
                    .modifier(ThresholdSliderFocusPresentation(preview: sliderPreview))
                    .opacity(appModel.isAudioReactivityIsolationPreviewActive ? 0 : 1)
                    .ignoresSafeArea(.container, edges: [.top, .bottom])
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }
}

private struct ParameterSliderFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

/// Cut away the panel's chrome and other rows while keeping the original
/// active control in place. A mask changes drawing only, preserving layout,
/// scroll position, and native slider touch ownership through release.
struct ThresholdSliderFocusPresentation: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let preview: ParameterSliderPreview
    @State private var frames: [UUID: CGRect] = [:]
    @State private var lastFocusedFrames: [CGRect] = []

    private var focusedFrames: [CGRect] {
        frames.keys.sorted { $0.uuidString < $1.uuidString }
            .filter { preview.isEditing($0) }
            .compactMap { frames[$0] }
    }

    func body(content: Content) -> some View {
        let activeFrames = focusedFrames
        // Fail open until this control's current, scroll-resolved bounds arrive.
        let isFocused = !activeFrames.isEmpty
        content
            .overlayPreferenceValue(ParameterSliderBoundsKey.self) { bounds in
                GeometryReader { geometry in
                    Color.clear
                        .preference(key: ParameterSliderFramesKey.self,
                                    value: bounds.mapValues { geometry[$0] })
                }
                .allowsHitTesting(false)
            }
            .onPreferenceChange(ParameterSliderFramesKey.self) { frames = $0 }
            .onChange(of: activeFrames, initial: true) { _, updated in
                // Retain the last row during fade-in so it never blinks away
                // when the native slider reports the release edge.
                if !updated.isEmpty { lastFocusedFrames = updated }
            }
            .compositingGroup()
            .mask {
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.white).opacity(isFocused ? 0 : 1)
                    Path { path in
                        for frame in activeFrames.isEmpty ? lastFocusedFrames : activeFrames {
                            path.addRoundedRect(in: frame.insetBy(dx: -8, dy: -6),
                                                cornerSize: CGSize(width: 12, height: 12))
                        }
                    }
                    .fill(.white)
                }
            }
            // The transparent panel continues to own its hit targets; never
            // replace or disable the slider in the middle of a native drag.
            .allowsHitTesting(true)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isFocused)
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
            // Keep the inspector mounted during either kind of live preview.
            .opacity(appModel.isAudioReactivityIsolationPreviewActive ? 0 : 1)
    }
}
#endif
