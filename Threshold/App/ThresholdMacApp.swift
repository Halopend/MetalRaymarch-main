#if os(macOS)
import AppKit
import SwiftUI

@main
struct ThresholdMacApp: App {
    @State private var appModel = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Headless offscreen perf sweep (THRESHOLD_BENCHMARK=1). Launched from
        // init because background benchmark runs do not materialize a window.
        if BenchmarkMode.isActive {
            let model = AppModel()
            _appModel = State(initialValue: model)
            Task { @MainActor in
                await MacBenchmarkHarness.run(appModel: model)
            }
        }
    }

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
                // In benchmark mode keep the render loop alive while unfocused so
                // an unattended profiler run captures a continuous workload.
                if !BenchmarkMode.isActive { appModel.isAppActive = false }
                appModel.saveLastState()
                Task { @MainActor in
                    await appModel.audioHub.stopTransientSources()
                    await UsageAnalytics.shared.endSession()
                }
            }
        }
        // Breakout controls window — the same control panel that slides over
        // the render view, hosted in its own window so it can live on another
        // screen (or beside the render window) without covering the fractal.
        Window("Threshold Controls", id: AppModel.controlsWindowID) {
            ContentView()
                .environment(appModel)
                .frame(minWidth: 980, minHeight: 576)
                .background(Color(white: 0.09))
                .onAppear { appModel.isControlsWindowOpen = true }
                .onDisappear { appModel.isControlsWindowOpen = false }
        }
        .defaultSize(width: 1040, height: 820)
        .windowResizability(.contentMinSize)

        // A real utility window backs every Animation Editor affordance in the
        // control panel. Previously those buttons called openWindow(id:) for an
        // id that was only registered by the visionOS app, so they silently did
        // nothing on macOS.
        Window("Animation Editor", id: AppModel.animationEditorWindowID) {
            AnimationEditorWindowView()
                .environment(appModel)
        }
        .defaultSize(width: 1120, height: 760)
        .windowResizability(.contentMinSize)

        Window("Welcome", id: AppModel.onboardingWindowID) {
            FirstLaunchWindowView()
                .environment(appModel)
        }
        .defaultSize(width: 980, height: 760)
        .windowResizability(.contentMinSize)

        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("Save Preset…") {
                    appModel.openSavePresetMenuHandler?()
                }
                .keyboardShortcut("s", modifiers: .command)
                    .disabled(appModel.openSavePresetMenuHandler == nil)
            }

            CommandMenu("Navigate") {
                Button("Find Controls…") {
                    appModel.openControlFinderHandler?()
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(appModel.openControlFinderHandler == nil)
            }
        }
    }
}

private struct ThresholdMacRootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var isControlsPinnedOpen = false
    @State private var isHoverVisible = false
    @State private var isPaneHovering = false
    @State private var isEdgeRevealHovering = false
    @State private var isRadialVisible = false
    @State private var isShiftPressed = false
    @State private var radialAnchor = CGPoint(x: 1400, y: 320)
    /// Selected node id per ring depth — the launcher's transient browsing
    /// state. Hover auto-select rewrites it; committed selection stays in the
    /// @AppStorage keys until a fallback leaf activates.
    @State private var radialPath: [String] = []
    /// Live parameter mirror backing the launcher's hierarchy sliders. Synced
    /// only while the launcher is visible (each live cache costs a 0.5s
    /// main-thread timer), following the ContentView start/stopSync pattern.
    @State private var radialCache = UISettingsCache()
    @State private var hoveredRadialSlider: RadialActiveSlider?
    @State private var activeMenuTrackingCount = 0
    @State private var pendingAutoHide: DispatchWorkItem?
    @State private var pendingRadialReveal: DispatchWorkItem?
    @State private var isControlFinderPresented = false
    /// Retained only to migrate the previous on/off launcher preference into the
    /// three explicit navigation modes.
    @AppStorage("MacTabLauncher.enabled") private var legacyLauncherEnabled = true
    @AppStorage("MacTabLauncher.navigationModeMigrated.v1") private var didMigrateNavigationMode = false
    @AppStorage("MacTabLauncher.style") private var launcherStyle: NavigationPresentationStyle = .radial
    @AppStorage("MacTabLauncher.curvature") private var launcherCurvature: Double = 0.82
    @AppStorage("ContentView.topDockTab") private var radialTopDockTab: TopDockTab = .explore
    @AppStorage("ContentView.exploreRailSection") private var radialExploreSection: ExploreRailSection = .jumpingOff
    @AppStorage("ContentView.shapeRailSection") private var radialShapeSection: ShapeRailSection = .parameters
    @AppStorage("ContentView.visualizationsRailSection") private var radialVisualizationsSection: VisualizationsRailSection = .color
    @AppStorage("ContentView.musicRailSection") private var radialMusicSection: MusicRailSection = .playback
    @AppStorage("ContentView.performanceRailSection.v3") private var radialPerformanceSection: PerformanceRailSection = .overview
    @AppStorage("ContentView.selectedTab") private var radialSelectedTab: SidebarTab = .fractal
    @AppStorage("FractalGridView.innerTab") private var radialBrowseTab: FractalBrowseTab = .jumpingOff
    @AppStorage("ContentView.fractalSubTab") private var radialFractalSubTab: FractalSubTab = .shape
    @AppStorage("ContentView.shapeInnerTab") private var radialShapeInnerTab: ShapeInnerTab = .parameters
    @AppStorage("ContentView.coloringSubTab") private var radialColoringSubTab: ColoringSubTab = .gradient
    @AppStorage("ContentView.effectsSubTab") private var radialEffectsSubTab: EffectsSubTab = .dynamic
    @AppStorage("MusicTabContent.innerTab") private var radialMusicPanelTab: MusicPanelTab = .music
    @AppStorage("ContentView.settingsSubTab") private var radialSettingsSubTab: SettingsSubTab = .display
    @AppStorage("allowCustomScenes") private var allowCustomScenes = false
    @AppStorage(TransformationExperienceMode.defaultsKey)
    private var radialTransformationModeRaw = TransformationExperienceMode.education.rawValue
    @AppStorage(TransformationUnlockProgress.defaultsKey)
    private var radialMappedLessonIDsRaw = ""
    @AppStorage(TransformationUnlockProgress.legacyDefaultsKey)
    private var radialLegacyMappedTransformationIDsRaw = ""

    private let contentMinimumSize = CGSize(width: 980, height: 576)
    private let minimumWindowSize = CGSize(width: 1440, height: 640)
    private let panelPreferredWidth: CGFloat = 1040
    private let radialContentPanelPreferredWidth: CGFloat = 840
    private let minimumVisibleViewportWidth: CGFloat = 360
    private let panelPadding: CGFloat = 14
    private let edgeRevealWidth: CGFloat = 46
    private let edgeRevealDelay: TimeInterval = 0.10
    private let autoHideDelay: TimeInterval = 0.22
    private let panelAnimation = MenuChrome.panelSpring

    private var shouldShowControls: Bool {
        // Separate Window mode never mounts a second copy over the viewport,
        // even during menu tracking or a stale pin state.
        guard launcherStyle != .separateWindow else { return false }
        // While the controls are broken out into their own window, never show
        // the slide-over sidebar — otherwise the panel appears twice. (The breakout
        // window hosts its own ContentView, so the import sheet below shows there.)
        guard !appModel.isControlsWindowOpen else { return false }
        // Force the panel open while an external-file import is pending. The import
        // confirmation sheet is hosted by ContentView *inside* this panel, so if the
        // panel auto-hides — or was never revealed when a file was opened from Finder —
        // ContentView unmounts and the sheet auto-dismisses before the user can act.
        if appModel.pendingExternalImport != nil { return true }
        // While the launcher is up the slide-over panel stays put: quick-input
        // drags mark menu interaction active, which must not summon the panel
        // over the rings mid-adjustment. An explicit pin still wins.
        if isRadialVisible { return isControlsPinnedOpen }
        return isControlsPinnedOpen || isHoverVisible || appModel.isMenuInteractionActive || activeMenuTrackingCount > 0
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

                if launcherStyle == .radial && isRadialVisible && !appModel.isControlsWindowOpen {
                    RadialMenu(
                        size: proxy.size,
                        pointerAnchor: radialAnchor,
                        curvature: $launcherCurvature,
                        projection: radialProjection,
                        path: $radialPath,
                        sceneAccent: RadialMenuSceneAccent.color(from: appModel.renderSettings.gradientColorMap),
                        suspendsHoverNavigation: isShiftPressed,
                        hoveredSlider: $hoveredRadialSlider,
                        onSliderEditingChanged: { editing in
                            if editing {
                                appModel.beginMenuAdjustment()
                            } else {
                                appModel.endMenuAdjustment()
                            }
                        },
                        onSelectPresentation: { style in
                            launcherStyle = style
                        },
                        onDismiss: {
                            hideRadialTabs(animated: true)
                        }
                    )
                    .opacity(isShiftPressed ? 0.16 : 1)
                    .allowsHitTesting(!isShiftPressed)
                    .animation(.easeOut(duration: 0.12), value: isShiftPressed)
                    .transition(.opacity)
                    .zIndex(2)
                }

                HStack(spacing: 0) {
                    Spacer(minLength: 0)

                    if shouldShowControls {
                        controlsHoverRegion(width: controlsWidth)
                            .padding(.vertical, panelPadding)
                            .opacity(isShiftPressed ? 0.16 : 1)
                            .animation(.easeOut(duration: 0.12), value: isShiftPressed)
                            .transition(panelTransition)
                    }
                }
                .animation(motionSensitivePanelAnimation, value: shouldShowControls)
                .allowsHitTesting(shouldShowControls)

                // The pin toggles the slide-over sidebar, which doesn't exist while the
                // controls are broken out — so hide the pin then. Its absence also reads
                // as "there's nothing to pin here; use Merge Into Window to bring it back."
                if !appModel.isControlsWindowOpen {
                    floatingToggle(windowSize: proxy.size)
                        .padding(.top, panelPadding)
                        .padding(.trailing, panelPadding)
                }

                // Always-on perf HUD (top-leading, opposite the pin button). Shows
                // FPS plus the continuous GPU-ms cost so acceleration tuning is
                // visible even when the frame rate is pinned by the display refresh.
                FPSIndicatorView()
                    .environment(appModel)
                    .padding(.top, panelPadding)
                    .padding(.leading, panelPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)

                MacRadialInputMonitor(
                    isPressed: $isShiftPressed,
                    isRadialVisible: isRadialVisible,
                    onMouseMoved: { location in
                        handleWindowMouseMoved(location, windowSize: proxy.size)
                    },
                    onTwoFingerSwipeUp: {
                        hideRadialTabs(animated: true)
                    },
                    onDoubleClick: {
                        hideRadialTabs(animated: true)
                    },
                    isPointerOverSlider: { locationInWindow in
                        // Geometric check: hover-exit events can be dropped, so a
                        // stale hovered id must not hijack scrolls window-wide.
                        // Shift-peek makes the faded pills inert.
                        guard !isShiftPressed, let hovered = hoveredRadialSlider else { return false }
                        let point = CGPoint(
                            x: locationInWindow.x,
                            y: proxy.size.height - locationInWindow.y
                        )
                        return hovered.frame.contains(point)
                    },
                    isPointerOverWindowDragHandle: { locationInWindow in
                        guard isRadialVisible, !isShiftPressed else { return false }
                        let point = CGPoint(
                            x: locationInWindow.x,
                            y: proxy.size.height - locationInWindow.y
                        )
                        return RadialMenu.windowDragHandleFrame(
                            size: proxy.size,
                            pointerAnchor: radialAnchor
                        ).contains(point)
                    },
                    onSliderScroll: { upwardDelta in
                        applyRadialSliderScroll(upwardDelta)
                    }
                )
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
            .frame(minWidth: minimumWindowSize.width, minHeight: minimumWindowSize.height)
            .onReceive(
                NotificationCenter.default.publisher(
                    for: ThresholdMacInteractiveView.didClickViewportNotification
                )
            ) { notification in
                guard let value = notification.userInfo?[ThresholdMacInteractiveView.clickLocationUserInfoKey] as? NSValue else {
                    return
                }
                handleViewportClick(
                    anchor: CGPoint(
                        x: value.pointValue.x,
                        y: proxy.size.height - value.pointValue.y
                    ),
                    windowSize: proxy.size
                )
            }
        }
        .frame(minWidth: minimumWindowSize.width, minHeight: minimumWindowSize.height)
        .sheet(isPresented: $isControlFinderPresented) {
            ControlFinderView(
                platform: .macOS,
                onSelect: navigateFromControlFinder,
                onDismiss: { isControlFinderPresented = false }
            )
        }
        .onAppear {
            migrateLegacyNavigationPreferenceIfNeeded()
            appModel.openControlFinderHandler = {
                isControlFinderPresented = true
            }
            if launcherStyle == .separateWindow {
                openWindow(id: AppModel.controlsWindowID)
            }
        }
        .onChange(of: appModel.isMenuInteractionActive) { _, _ in
            updateAutoHideState(animated: true)
        }
        .onChange(of: launcherStyle) { _, style in
            applyNavigationStyle(style)
        }
        .onSceneLoadAutoHide {
            // A scene chosen from the radial-launched browser has completed
            // the launcher interaction, so always remove its outer layers.
            // The full controls panel is a separate policy and still respects
            // an explicit pin.
            hideRadialTabs(animated: false)
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
        .onChange(of: appModel.isControlsWindowOpen) { _, isOpen in
            // The breakout window unmounts the launcher; without this the
            // session (cache sync timer, scroll-consuming monitor state, stale
            // browse path) would silently outlive it and ghost-remount later.
            if isOpen { hideRadialTabs(animated: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppModel.fractalSettingsDidChangeNotification)) { _ in
            // Scene/preset loads replace RenderSettings values wholesale; the
            // launcher's slider mirrors must resnapshot or they scrub stale bases.
            if isRadialVisible { radialCache.loadFromSettings() }
        }
        .onDisappear {
            appModel.openControlFinderHandler = nil
            pendingAutoHide?.cancel()
            pendingAutoHide = nil
            pendingRadialReveal?.cancel()
            pendingRadialReveal = nil
            endRadialSession()
        }
    }

    private var slideOverPanel: some View {
        ContentView(showsOuterNavigation: launcherStyle != .radial)
            .environment(appModel)
            .frame(maxHeight: .infinity)
            .background(
                ZStack {
                    // Opaque surface instead of an NSVisualEffectView `.withinWindow`
                    // blur. The blur re-sampled the live Metal fractal view every
                    // frame on the main thread — that compositing cost was what
                    // halved the frame rate while the menu was open. These static,
                    // opaque gradients keep the purple depth without sampling the
                    // live renderer underneath.
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.045, green: 0.010, blue: 0.075),
                                    Color(red: 0.095, green: 0.018, blue: 0.145),
                                    Color(red: 0.17, green: 0.035, blue: 0.25)
                                ],
                                startPoint: .bottomLeading,
                                endPoint: .topTrailing
                            )
                        )

                    RadialGradient(
                        colors: [
                            Color(red: 0.68, green: 0.16, blue: 0.94).opacity(0.22),
                            Color.clear
                        ],
                        center: .topTrailing,
                        startRadius: 0,
                        endRadius: 680
                    )
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

    private func floatingToggle(windowSize: CGSize) -> some View {
        let title: String = {
            switch launcherStyle {
            case .separateWindow:
                return "Open Controls"
            case .radial:
                return isRadialVisible ? "Hide Menu" : "Menu"
            case .controlPanel:
                return shouldShowControls ? "Hide Controls" : "Controls"
            }
        }()

        return Button {
            toggleSelectedNavigation(windowSize: windowSize)
        } label: {
            Label(title, systemImage: launcherStyle.systemImage)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .foregroundStyle(isRadialVisible ? Color.accentColor : Color.primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isRadialVisible ? "Hide radial menu (⌘.)" : "Open \(launcherStyle.displayName.lowercased()) (⌘.)")
        .keyboardShortcut(".", modifiers: .command)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .foregroundStyle(.primary)
        .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
        .accessibilityLabel(title)
        .accessibilityHint("Opens the Threshold control surface")
        .contextMenu {
            ForEach(NavigationPresentationStyle.allCases, id: \.self) { style in
                Button {
                    launcherStyle = style
                } label: {
                    Label(
                        style.displayName,
                        systemImage: launcherStyle == style ? "checkmark" : style.systemImage
                    )
                }
            }

            if launcherStyle != .separateWindow {
                Divider()

                Button(isControlsPinnedOpen ? "Unpin Control Panel" : "Pin Control Panel") {
                    toggleControlsPin()
                }
            }
        }
    }

    private func navigateFromControlFinder(_ destination: ControlFinderDestination) {
        guard let route = destination.route else { return }

        hideRadialTabs(animated: false)
        withAnimation(motionSensitivePanelAnimation) {
            isControlsPinnedOpen = true

            switch route {
            case .explore(let section):
                radialTopDockTab = .explore
                radialExploreSection = section
                radialSelectedTab = .fractal
                radialFractalSubTab = .browse
                radialBrowseTab = section.browseTab

            case .shape(let section):
                radialTopDockTab = .shape
                radialShapeSection = section
                radialSelectedTab = .fractal
                switch section {
                case .parameters:
                    radialFractalSubTab = .shape
                    radialShapeInnerTab = .parameters
                case .formula:
                    radialFractalSubTab = .shape
                    radialShapeInnerTab = .formula
                case .primitives:
                    radialFractalSubTab = .shape
                    radialShapeInnerTab = .primitives
                case .hands:
                    radialFractalSubTab = .shape
                    radialShapeInnerTab = .hands
                case .space:
                    radialFractalSubTab = .space
                case .transformations:
                    radialFractalSubTab = .transform
                case .bounding:
                    radialFractalSubTab = .bounding
                case .performance:
                    radialTopDockTab = .performance
                    radialPerformanceSection = .tuning
                    radialFractalSubTab = .render
                }

            case .visualizations(let section):
                radialTopDockTab = .visualizations
                radialVisualizationsSection = section
                switch section {
                case .color:
                    radialSelectedTab = .coloring
                    radialColoringSubTab = .gradient
                case .mapping:
                    radialSelectedTab = .coloring
                    radialColoringSubTab = .mapping
                case .grading:
                    radialSelectedTab = .coloring
                    radialColoringSubTab = .grading
                case .motion:
                    radialSelectedTab = .effects
                    radialEffectsSubTab = .dynamic
                case .atmosphere:
                    radialSelectedTab = .effects
                    radialEffectsSubTab = .static
                case .transition:
                    radialSelectedTab = .transition
                case .reactive:
                    radialTopDockTab = .music
                    radialMusicSection = .reactive
                    radialSelectedTab = .music
                    radialMusicPanelTab = .reactive
                }

            case .performance(let section):
                radialTopDockTab = .performance
                radialPerformanceSection = section
                radialSelectedTab = .fractal
                radialFractalSubTab = .render

            case .music(let section):
                let section = section.canonical
                radialTopDockTab = .music
                radialMusicSection = section
                radialSelectedTab = .music
                radialMusicPanelTab = section.musicPanelTab

            case .settings(let section):
                radialSelectedTab = .settings
                radialSettingsSubTab = section

            case .sidebar(let tab):
                radialSelectedTab = tab

            case .animationEditor:
                if appModel.animationManager?.currentScene == nil {
                    appModel.animationManager?.currentScene = appModel.animationManager?.scenes.first
                }
                openWindow(id: AppModel.animationEditorWindowID)
            }
        }
    }

    private func handlePaneHover(_ hovering: Bool) {
        isPaneHovering = hovering
        if hovering {
            showControls(animated: true)
        } else {
            updateAutoHideState(animated: true)
        }
    }

    private func handleWindowMouseMoved(_ location: CGPoint, windowSize: CGSize) {
        let isInsideRevealEdge = location.x >= windowSize.width - edgeRevealWidth
            && location.x <= windowSize.width + 2

        if isRadialVisible {
            // Keep the launcher fixed after it opens. If the anchor follows the
            // pointer, every button moves away while the user approaches it and
            // the eventual click falls through to the viewport instead.
            isEdgeRevealHovering = isInsideRevealEdge
            pendingRadialReveal?.cancel()
            pendingRadialReveal = nil
            return
        }

        guard isInsideRevealEdge else {
            if isEdgeRevealHovering {
                isEdgeRevealHovering = false
                pendingRadialReveal?.cancel()
                pendingRadialReveal = nil
                updateAutoHideState(animated: true)
            }
            return
        }

        isEdgeRevealHovering = true
        radialAnchor = clampedLauncherAnchor(
            CGPoint(x: location.x, y: windowSize.height - location.y),
            windowSize: windowSize
        )
        scheduleNavigationReveal()
    }

    /// A short dwell is enough to reveal navigation. The old implementation
    /// required additional rightward motion after the pointer had already
    /// reached the edge, which is impossible once the pointer is screen-clamped
    /// and made edge reveal feel intermittent.
    private func scheduleNavigationReveal() {
        guard launcherStyle != .separateWindow,
              !isRadialVisible,
              pendingRadialReveal == nil,
              !shouldShowControls else { return }

        let workItem = DispatchWorkItem {
            pendingRadialReveal = nil
            guard !isRadialVisible,
                  isEdgeRevealHovering,
                  !shouldShowControls else { return }

            if launcherStyle == .controlPanel {
                showControls(animated: true)
                return
            }

            guard launcherStyle == .radial else { return }

            beginRadialSession()
            if reduceMotion {
                isRadialVisible = true
            } else {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    isRadialVisible = true
                }
            }
        }
        pendingRadialReveal = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + edgeRevealDelay, execute: workItem)
    }

    private func hideRadialTabs(animated: Bool) {
        pendingRadialReveal?.cancel()
        pendingRadialReveal = nil
        guard isRadialVisible else { return }

        endRadialSession()
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.14)) {
                isRadialVisible = false
            }
        } else {
            isRadialVisible = false
        }
    }

    /// Prepares the launcher's transient state for a reveal: browsing path at
    /// the committed dock tab, and a live slider cache. startSync is only safe
    /// to call once per session, so both reveal paths route through here while
    /// the launcher is still hidden.
    private func beginRadialSession() {
        radialPath = [Self.rootNodeID(for: radialTopDockTab)]
        hoveredRadialSlider = nil
        radialCache.startSync(with: appModel.renderSettings, appModel: appModel)
    }

    private func endRadialSession() {
        radialCache.stopSync()
        hoveredRadialSlider = nil
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: Shared hierarchy → radial projection
    //
    // `NavigationHierarchy` owns the routes, labels, and ordering used by the
    // existing cross-platform grid. This host adapter supplies selection and
    // fallback actions; the radial model and renderer are shared with iPadOS.
    // ═══════════════════════════════════════════════════════════════════════

    static func rootNodeID(for tab: TopDockTab) -> String {
        NavigationHierarchy.rootID(for: tab)
    }

    private var sharedNavigationHierarchy: NavigationHierarchy {
        NavigationHierarchy.application(availability: .current(
            allowsCustomScenes: allowCustomScenes,
            includesGestureEditing: false
        ))
    }

    private var radialProjection: RadialNavigationProjection {
        RadialNavigationProjection(
            roots: sharedNavigationHierarchy.roots.compactMap(radialNode(for:))
        )
    }

    private func radialNode(for definition: NavigationHierarchy.Node) -> RadialNavigationNode? {
        switch definition.destination {
        case .workspace:
            return RadialNavigationNode(
                id: definition.id,
                title: definition.title,
                systemImage: definition.systemImage,
                isSelected: radialPath.first == definition.id,
                children: definition.children.compactMap(radialNode(for:))
            )

        case .explore(let section):
            return RadialNavigationNode(
                id: definition.id,
                title: definition.title,
                systemImage: definition.systemImage,
                isSelected: radialTopDockTab == .explore
                    && radialExploreSection == section
                    && radialSelectedTab == .fractal,
                fallbackAction: { activateExploreFromLauncher(section) }
            )

        case .shape(let section):
            let inputs = shapeSliderNodes(for: section)
            return radialSectionNode(
                definition,
                isSelected: radialTopDockTab == .shape
                    && radialShapeSection == section
                    && radialSelectedTab == .fractal,
                inputs: inputs,
                fallback: { activateShapeFromLauncher(section) }
            )

        case .visualizations(let section):
            let inputs = visualizationsSliderNodes(for: section)
            return radialSectionNode(
                definition,
                isSelected: radialTopDockTab == .visualizations
                    && radialVisualizationsSection == section,
                inputs: inputs,
                fallback: { activateVisualizationsFromLauncher(section) }
            )

        case .music(let section):
            return RadialNavigationNode(
                id: definition.id,
                title: definition.title,
                systemImage: definition.systemImage,
                isSelected: radialTopDockTab == .music
                    && radialMusicSection.canonical == section
                    && radialSelectedTab == .music,
                fallbackAction: { activateMusicFromLauncher(section) }
            )

        case .performance(let section):
            return RadialNavigationNode(
                id: definition.id,
                title: definition.title,
                systemImage: definition.systemImage,
                isSelected: radialTopDockTab == .performance
                    && radialPerformanceSection == section,
                fallbackAction: { activatePerformanceFromLauncher(section) }
            )

        case .animationEditor:
            return RadialNavigationNode(
                id: definition.id,
                title: definition.title,
                systemImage: definition.systemImage,
                fallbackAction: {
                    hideRadialTabs(animated: true)
                    if appModel.animationManager?.currentScene == nil {
                        appModel.animationManager?.currentScene = appModel.animationManager?.scenes.first
                    }
                    openWindow(id: AppModel.animationEditorWindowID)
                }
            )

        case .quickToggles:
            return RadialNavigationNode(
                id: definition.id,
                title: definition.title,
                systemImage: definition.systemImage,
                isSelected: radialSelectedTab == .quickToggles,
                fallbackAction: {
                    radialSelectedTab = .quickToggles
                    showControlsAfterLauncherSelection()
                }
            )

        case .settings:
            return RadialNavigationNode(
                id: definition.id,
                title: definition.title,
                systemImage: definition.systemImage,
                isSelected: radialSelectedTab == .settings,
                fallbackAction: {
                    radialSelectedTab = .settings
                    showControlsAfterLauncherSelection()
                }
            )

        case .gestures:
            // Gesture editing is not supported by ContentView on macOS.
            return nil
        }
    }

    private func radialSectionNode(
        _ definition: NavigationHierarchy.Node,
        isSelected: Bool,
        inputs: [RadialNavigationNode],
        fallback: @escaping () -> Void
    ) -> RadialNavigationNode {
        RadialNavigationNode(
            id: definition.id,
            title: definition.title,
            systemImage: definition.systemImage,
            isSelected: isSelected,
            children: inputs,
            fallbackAction: inputs.isEmpty ? fallback : nil,
            compactChildrenLimit: inputs.isEmpty ? nil : Self.maxSlidersPerRing,
            overflowFallback: inputs.isEmpty ? nil : RadialOverflowFallback(
                RadialNavigationNode(
                    id: "\(definition.id).more",
                    title: "More \(definition.title)",
                    systemImage: "ellipsis.circle",
                    fallbackAction: fallback
                )
            )
        )
    }

    // MARK: Quick-input leaves

    /// Terminal slider rings mirror where each control lives in the panel, so
    /// the radial route and the full controls window never disagree about a
    /// control's home. Sections without in-place controls stay pure fallback
    /// leaves. The hierarchy stays complete; compact projections enforce the
    /// fan budget through each section node's explicit overflow fallback.
    private static let maxSlidersPerRing = 8

    private func shapeSliderNodes(for section: ShapeRailSection) -> [RadialNavigationNode] {
        switch section {
        case .parameters:
            // Per-fractal formula params, exactly like FormulaParamsEditor —
            // plus the Mandelbox-only Scale row fractalShapeContent appends.
            let formulaNodes = ParameterNodeRegistry.shared
                .formulaBatch(for: radialCache.fractalType)
                .floatNodes
            var inputs = formulaNodes.map(formulaSliderNode(for:))
            if radialCache.fractalType == .mandelbox,
               let scale = catalogSliderNode(ParameterTargetID.Core.fractalScale) {
                inputs.append(scale)
            }
            return inputs
        case .space:
            // A disabled feature's slider would scrub a value the renderer
            // ignores; the section then behaves as a pure fallback leaf.
            guard radialCache.safetyBubble.enabled else { return [] }
            return [catalogSliderNode(ParameterTargetID.Effect.safetyBubbleRadius)].compactMap { $0 }
        case .primitives:
            return primitiveQuickControlNodes()
        case .transformations:
            return transformationQuickControlNodes()
        case .formula, .hands, .bounding, .performance:
            return []
        }
    }

    /// The radial surface keeps the analytic-solid picker one gesture away;
    /// compact overflow and shape-specific dimensions live in the full panel.
    private func primitiveQuickControlNodes() -> [RadialNavigationNode] {
        let selected: FractalPrimitiveKind? = {
            guard radialCache.fractalType == .constructionPrimitive else { return nil }
            // rawSelector: scene files carry slot 0 unclamped, and this runs on
            // every radial-menu mount — a plain Int(Float) here traps on a
            // corrupt/hand-edited file before the user navigates anywhere.
            return FractalPrimitiveKind(
                rawSelector: FormulaCatalog.getParam(radialCache.formulaParams, index: 0)
            )
        }()

        return FractalPrimitiveKind.analyticCases.map { primitive in
            RadialNavigationNode(
                id: "shape.primitives.\(primitive.id)",
                title: primitive.name,
                systemImage: primitive.icon,
                isSelected: selected == primitive,
                fallbackAction: {
                    radialCache.pushConstructionPrimitive(
                        primitive,
                        gestureController: appModel.gestureController
                    )
                }
            )
        }
    }

    /// Active space systems and composable stack instances exposed through
    /// the shared hierarchy's Transform destination. Structural
    /// editing (equation mapping/add/delete/reorder) remains in the full Transform panel;
    /// this surface is intentionally optimized for live tuning.
    private func transformationQuickControlNodes() -> [RadialNavigationNode] {
        var nodes: [RadialNavigationNode] = []

        if radialCache.display.sphericalInversionMode != .off {
            let cache = radialCache
            let spec = ControlCatalog.sphericalInversionRadius
            nodes.append(RadialNavigationNode(
                id: "transform.system.sphericalInversion",
                title: "Spherical Inversion",
                systemImage: AppIcons.circleDashedInsetFilled,
                children: [
                    RadialNavigationNode(
                        id: "slider.\(spec.id)",
                        title: spec.name,
                        systemImage: spec.icon,
                        slider: RadialSliderBinding(
                            range: spec.range,
                            read: { cache.display.sphericalInversionRadius },
                            write: {
                                cache.display.sphericalInversionRadius = spec.clamp($0)
                                cache.commitSphericalInversion()
                            },
                            format: Self.sliderValueFormat(for: spec.range)
                        )
                    )
                ]
            ))
        }

        if radialCache.display.sphereProjectionEnabled {
            let projectionControls = [
                catalogSliderNode(ParameterTargetID.Space.sphereProjectionBlend),
                catalogSliderNode(ParameterTargetID.Space.sphereProjectionRadius)
            ].compactMap { $0 }
            if !projectionControls.isEmpty {
                nodes.append(RadialNavigationNode(
                    id: "transform.system.sphereProjection",
                    title: "Sphere Projection",
                    systemImage: AppIcons.globeAsiaAustralia,
                    children: projectionControls
                ))
            }
        }

        let cache = radialCache
        let stack = cache.spaceWarpStack
        let mode = TransformationExperienceMode.decode(radialTransformationModeRaw)
        let mappedIDs = TransformationUnlockProgress.runtimeKindIDs(
            from: TransformationUnlockProgress.decode(
                radialMappedLessonIDsRaw,
                legacyEncoded: radialLegacyMappedTransformationIDsRaw
            )
        )
        let hasCurrentAccess: (SpaceWarpOpValue) -> Bool = { liveOp in
            let defaults = UserDefaults.standard
            let liveMode = TransformationExperienceMode.decode(
                defaults.string(forKey: TransformationExperienceMode.defaultsKey) ?? ""
            )
            let liveMappedIDs = TransformationUnlockProgress.runtimeKindIDs(
                from: TransformationUnlockProgress.decode(
                    defaults.string(forKey: TransformationUnlockProgress.defaultsKey) ?? "",
                    legacyEncoded: defaults.string(
                        forKey: TransformationUnlockProgress.legacyDefaultsKey
                    ) ?? ""
                )
            )
            return TransformationAccessPolicy.canInteract(
                withRawKindID: liveOp.type,
                mode: liveMode,
                mappedIDs: liveMappedIDs
            )
        }
        let opNodes: [RadialNavigationNode] = stack.enumerated().compactMap { position, op in
            guard TransformationAccessPolicy.canInteract(
                withRawKindID: op.type,
                mode: mode,
                mappedIDs: mappedIDs
            ) else { return nil }
            return RadialTransformNodeFactory.branch(
                for: op,
                position: position,
                read: { id in
                    guard let liveOp = cache.renderSettings?.spaceWarpStack.first(where: { $0.id == id }),
                          hasCurrentAccess(liveOp) else { return nil }
                    return liveOp
                },
                update: { id, mutate in
                    guard let liveOp = cache.renderSettings?.spaceWarpStack.first(where: { $0.id == id }),
                          hasCurrentAccess(liveOp) else { return }
                    cache.updateSpaceWarpOp(id: id, mutate)
                }
            )
        }

        return nodes + opNodes
    }

    private func visualizationsSliderNodes(for section: VisualizationsRailSection) -> [RadialNavigationNode] {
        switch section {
        case .mapping:
            return [
                catalogSliderNode(ParameterTargetID.Core.colorMix),
                catalogSliderNode(ParameterTargetID.Effect.gradientOffset)
            ].compactMap { $0 }
        case .grading:
            return gradingSliderNodes()
        case .atmosphere:
            return [
                catalogSliderNode(ParameterTargetID.Effect.glow),
                catalogSliderNode(ParameterTargetID.Effect.bloom),
                catalogSliderNode(ParameterTargetID.Effect.fog)
            ].compactMap { $0 }
        case .motion:
            return [catalogSliderNode(ParameterTargetID.Effect.hueSpeed)].compactMap { $0 }
        case .color, .transition, .reactive:
            return []
        }
    }

    /// Slider leaf for a catalog-routed control. descriptor.ui.write is the
    /// canonical UI write path: it updates the observable cache mirror AND
    /// commits/pushes into RenderSettings (routing through the parameter layer
    /// stack where the control is music/gesture-layered). Values are clamped
    /// here because some core writes deliberately do not clamp.
    private func catalogSliderNode(_ targetID: String) -> RadialNavigationNode? {
        guard let descriptor = ParameterCatalog.byID[targetID],
              descriptor.capability.isAvailable(radialCache.fractalType) else { return nil }
        let cache = radialCache
        let spec = descriptor.spec
        return RadialNavigationNode(
            id: "slider.\(spec.id)",
            title: spec.name,
            systemImage: spec.icon,
            slider: RadialSliderBinding(
                range: spec.range,
                read: { descriptor.ui.read(cache) },
                write: { descriptor.ui.write(cache, spec.clamp($0)) },
                format: Self.sliderValueFormat(for: spec.range)
            )
        )
    }

    /// Slider leaf for a per-fractal formula param. Reads through the live
    /// node; writes dispatch a .slider ParameterOperation so the layer stack
    /// recenters music/gesture modulation around the new base (writing
    /// cache.formulaParams directly would fight the automation layers).
    private func formulaSliderNode(for node: FloatParameterNode) -> RadialNavigationNode {
        let cache = radialCache
        return RadialNavigationNode(
            id: "slider.\(node.id)",
            title: node.name,
            systemImage: node.icon,
            slider: RadialSliderBinding(
                range: node.range,
                read: { node.readValue(cache) },
                write: { value in
                    // smoothingTime 0: the pill re-reads the mirror between
                    // scroll ticks, so default smoothing would eat most of each
                    // delta (read-modify-write against a lagging value).
                    cache.dispatchParameterOperation(ParameterOperation(
                        targetID: node.id,
                        source: .slider,
                        value: value,
                        frameIndex: UInt64(Date().timeIntervalSince1970 * 1000),
                        smoothing: ParameterOperationSmoothing(smoothingTime: 0)
                    ))
                },
                format: Self.sliderValueFormat(for: node.range)
            )
        )
    }

    /// Post-processing is grouped into one extra navigation level so related
    /// controls stay together and no radial ring exceeds the readability cap.
    /// Long-tail ranges come from ControlCatalog; the groups are also the first
    /// step toward a declarative post-effect catalog rather than another flat
    /// list of unrelated sliders.
    private func gradingSliderNodes() -> [RadialNavigationNode] {
        let cache = radialCache
        func node(
            _ spec: ControlSpec,
            title: String,
            read: @escaping () -> Float,
            write: @escaping (Float) -> Void,
            isEnabled: @escaping () -> Bool = { true },
            format: ((Float) -> String)? = nil
        ) -> RadialNavigationNode {
            let valueFormat = format ?? Self.sliderValueFormat(for: spec.range)
            return RadialNavigationNode(
                id: "slider.\(spec.id)",
                title: title,
                systemImage: spec.icon,
                slider: RadialSliderBinding(
                    range: spec.range,
                    read: read,
                    write: { write(spec.clamp($0)) },
                    isEnabled: isEnabled,
                    format: valueFormat
                )
            )
        }

        let colorGrade = [
            node(ControlCatalog.saturation, title: "Saturation",
                 read: { cache.color.colorSchemeSaturation },
                 write: { cache.color.colorSchemeSaturation = $0; cache.commitColorSchemeSaturation() }),
            node(ControlCatalog.colorSchemeContrast, title: "Contrast",
                 read: { cache.color.colorSchemeContrast },
                 write: { cache.color.colorSchemeContrast = $0; cache.push(\.colorSchemeContrast, value: $0) }),
            node(ControlCatalog.colorSchemeGamma, title: "Gamma",
                 read: { cache.color.colorSchemeGamma },
                 write: { cache.color.colorSchemeGamma = $0; cache.push(\.colorSchemeGamma, value: $0) }),
            node(ControlCatalog.colorSchemeVibrance, title: "Vibrance",
                 read: { cache.color.colorSchemeVibrance },
                 write: { cache.color.colorSchemeVibrance = $0; cache.push(\.colorSchemeVibrance, value: $0) }),
            node(ControlCatalog.colorSchemeCurve, title: "Midtone Curve",
                 read: { cache.color.colorSchemeCurve },
                 write: { cache.color.colorSchemeCurve = $0; cache.push(\.colorSchemeCurve, value: $0) }),
            node(ControlCatalog.colorSchemeShadows, title: "Shadows",
                 read: { cache.color.colorSchemeShadows },
                 write: { cache.color.colorSchemeShadows = $0; cache.push(\.colorSchemeShadows, value: $0) }),
            node(ControlCatalog.colorSchemeHighlights, title: "Highlights",
                 read: { cache.color.colorSchemeHighlights },
                 write: { cache.color.colorSchemeHighlights = $0; cache.push(\.colorSchemeHighlights, value: $0) })
        ]

        // Cell shading has a discrete useful range of 2...8, but radial sliders
        // need an off position. Map 0 -> off and 1...7 -> 2...8 bands while the
        // canonical stored band count remains governed by its ControlSpec.
        let cellShading = RadialNavigationNode(
            id: "slider.post.cellShading",
            title: "Cell Shading",
            systemImage: ControlCatalog.cellShadingLevels.icon,
            slider: RadialSliderBinding(
                range: 0...(ControlCatalog.cellShadingLevels.range.upperBound - 1),
                read: {
                    cache.color.cellShadingEnabled
                        ? max(1, cache.color.cellShadingLevels - 1)
                        : 0
                },
                write: { rawValue in
                    if rawValue <= EdgeDetectionEffect.activationEpsilon {
                        cache.color.cellShadingEnabled = false
                    } else {
                        cache.color.cellShadingEnabled = true
                        cache.color.cellShadingLevels = ControlCatalog.cellShadingLevels.clamp((rawValue + 1).rounded())
                    }
                    cache.push(\.cellShadingEnabled, value: cache.color.cellShadingEnabled)
                    cache.push(\.cellShadingLevels, value: cache.color.cellShadingLevels)
                },
                format: { $0 <= EdgeDetectionEffect.activationEpsilon ? "Off" : "\(Int(($0 + 1).rounded()))" }
            )
        )

        let lightingFinish = [
            node(ControlCatalog.lightingSoftness, title: "Lighting Softness",
                 read: { cache.color.lightingSoftness },
                 write: { cache.color.lightingSoftness = $0; cache.push(\.lightingSoftness, value: $0) }),
            cellShading,
            node(ControlCatalog.aoStrength, title: "Ambient Occlusion",
                 read: { cache.color.aoStrength },
                 write: { cache.color.aoStrength = $0; cache.push(\.aoStrength, value: $0) }),
            node(ControlCatalog.tonemapStrength, title: "Filmic Tonemap",
                 read: { cache.color.tonemapStrength },
                 write: { cache.color.tonemapStrength = $0; cache.push(\.tonemapStrength, value: $0) }),
            node(ControlCatalog.vignetteStrength, title: "Vignette",
                 read: { cache.color.vignetteStrength },
                 write: { cache.color.vignetteStrength = $0; cache.push(\.vignetteStrength, value: $0) },
                 format: { $0 <= EdgeDetectionEffect.activationEpsilon ? "Off" : String(format: "%.2f", $0) })
        ]

        let edgeIsActive = { cache.lighting.edgeDetectionEffect.isActive }
        let edgeDetection = [
            node(ControlCatalog.edgeStrength, title: "Strength",
                 read: { cache.lighting.edgeDetectionEffect.strength },
                 write: { value in
                     cache.lighting.edgeDetectionEffect.setStrength(value)
                     cache.commitEdgeDetectionEffect()
                 },
                 format: { $0 <= EdgeDetectionEffect.activationEpsilon ? "Off" : String(format: "%.2f", $0) }),
            node(ControlCatalog.edgeThreshold, title: "Threshold",
                 read: { cache.lighting.edgeDetectionEffect.threshold },
                 write: { cache.lighting.edgeDetectionEffect.threshold = $0; cache.commitEdgeDetectionEffect() },
                 isEnabled: edgeIsActive),
            node(ControlCatalog.edgeSoftness, title: "Softness",
                 read: { cache.lighting.edgeDetectionEffect.softness },
                 write: { cache.lighting.edgeDetectionEffect.softness = $0; cache.commitEdgeDetectionEffect() },
                 isEnabled: edgeIsActive),
            node(ControlCatalog.edgeWindowRadius, title: "Window Size",
                 read: { Float(cache.lighting.edgeDetectionEffect.windowRadius) },
                 write: {
                     cache.lighting.edgeDetectionEffect.windowRadius = Int($0.rounded())
                     cache.commitEdgeDetectionEffect()
                 },
                 isEnabled: edgeIsActive,
                 format: { String(Int($0.rounded())) })
        ]

        return [
            RadialNavigationNode(
                id: "post.colorGrade",
                title: "Color Grade",
                systemImage: "paintpalette.fill",
                children: colorGrade
            ),
            RadialNavigationNode(
                id: "post.lightingFinish",
                title: "Lighting Finish",
                systemImage: "camera.filters",
                children: lightingFinish
            ),
            RadialNavigationNode(
                id: "post.edgeDetection",
                title: "Edge Detection",
                systemImage: "circle.lefthalf.filled",
                children: edgeDetection
            )
        ]
    }

    private static func sliderValueFormat(for range: ClosedRange<Float>) -> (Float) -> String {
        let span = range.upperBound - range.lowerBound
        return span >= 8
            ? { String(format: "%.1f", $0) }
            : { String(format: "%.2f", $0) }
    }

    /// Trackpad scroll over a hovered slider pill, normalized so physical
    /// finger-up increases the value. 240pt of travel sweeps the full range —
    /// finer than the arc drag, for dialing in exact values.
    private func applyRadialSliderScroll(_ upwardDelta: CGFloat) {
        guard let hovered = hoveredRadialSlider,
              let slider = radialProjection.node(withID: hovered.id)?.slider,
              slider.isEnabled() else { return }
        let span = slider.range.upperBound - slider.range.lowerBound
        let value = (slider.read() + Float(upwardDelta / 240) * span).clamped(to: slider.range)
        slider.writeIfEnabled(value)
    }

    private func activateExploreFromLauncher(_ section: ExploreRailSection) {
        radialTopDockTab = .explore
        radialExploreSection = section
        radialBrowseTab = section.browseTab
        radialFractalSubTab = .browse
        radialSelectedTab = .fractal
        showControlsAfterLauncherSelection()
    }

    private func activateShapeFromLauncher(_ section: ShapeRailSection) {
        radialTopDockTab = .shape
        radialShapeSection = section
        switch section {
        case .parameters:
            radialShapeInnerTab = .parameters
            radialFractalSubTab = .shape
        case .formula:
            radialShapeInnerTab = .formula
            radialFractalSubTab = .shape
        case .primitives:
            radialShapeInnerTab = .primitives
            radialFractalSubTab = .shape
        case .hands:
            radialShapeInnerTab = .hands
            radialFractalSubTab = .shape
        case .space:
            radialFractalSubTab = .space
        case .transformations:
            radialFractalSubTab = .transform
        case .bounding:
            radialFractalSubTab = .bounding
        case .performance:
            radialFractalSubTab = .render
        }
        radialSelectedTab = .fractal
        showControlsAfterLauncherSelection()
    }

    private func activateVisualizationsFromLauncher(_ section: VisualizationsRailSection) {
        radialTopDockTab = .visualizations
        radialVisualizationsSection = section
        switch section {
        case .color:
            radialColoringSubTab = .gradient
            radialSelectedTab = .coloring
        case .mapping:
            radialColoringSubTab = .mapping
            radialSelectedTab = .coloring
        case .grading:
            radialColoringSubTab = .grading
            radialSelectedTab = .coloring
        case .motion:
            radialEffectsSubTab = .dynamic
            radialSelectedTab = .effects
        case .atmosphere:
            radialEffectsSubTab = .static
            radialSelectedTab = .effects
        case .transition:
            radialSelectedTab = .transition
        case .reactive:
            radialTopDockTab = .music
            radialMusicSection = .reactive
            radialMusicPanelTab = .reactive
            radialSelectedTab = .music
        }
        showControlsAfterLauncherSelection()
    }

    private func activateMusicFromLauncher(_ section: MusicRailSection) {
        let section = section.canonical
        radialTopDockTab = .music
        radialMusicSection = section
        radialMusicPanelTab = section.musicPanelTab
        radialSelectedTab = .music
        showControlsAfterLauncherSelection()
    }

    private func activatePerformanceFromLauncher(_ section: PerformanceRailSection) {
        radialTopDockTab = .performance
        radialPerformanceSection = section
        radialFractalSubTab = .render
        radialSelectedTab = .fractal
        showControlsAfterLauncherSelection()
    }

    private func showControlsAfterLauncherSelection() {
        hideRadialTabs(animated: true)
        showControls(animated: true)
    }

    private func toggleSelectedNavigation(windowSize: CGSize) {
        switch launcherStyle {
        case .separateWindow:
            openWindow(id: AppModel.controlsWindowID)

        case .controlPanel:
            guard !appModel.isControlsWindowOpen else { return }
            if shouldShowControls {
                isControlsPinnedOpen = false
                setHoverVisible(false, animated: true)
            } else {
                showControls(animated: true)
            }

        case .radial:
            guard !appModel.isControlsWindowOpen else { return }
            if isRadialVisible {
                hideRadialTabs(animated: true)
                return
            }

            showRadialLauncher(
                anchor: CGPoint(x: windowSize.width - 18, y: windowSize.height * 0.48),
                windowSize: windowSize
            )
        }
    }

    /// Viewport clicks are toggles. In particular, a click outside an already
    /// open radial menu dismisses it instead of moving its anchor and resetting
    /// the current path.
    private func handleViewportClick(anchor: CGPoint, windowSize: CGSize) {
        switch launcherStyle {
        case .separateWindow:
            openWindow(id: AppModel.controlsWindowID)

        case .controlPanel:
            if shouldShowControls {
                isControlsPinnedOpen = false
                setHoverVisible(false, animated: true)
            } else {
                showControls(animated: true)
            }

        case .radial:
            if isRadialVisible {
                hideRadialTabs(animated: true)
                return
            }
            showRadialLauncher(anchor: anchor, windowSize: windowSize)
        }
    }

    private func migrateLegacyNavigationPreferenceIfNeeded() {
        guard !didMigrateNavigationMode else { return }
        if !legacyLauncherEnabled {
            launcherStyle = .controlPanel
        }
        legacyLauncherEnabled = true
        didMigrateNavigationMode = true
    }

    private func applyNavigationStyle(_ style: NavigationPresentationStyle) {
        pendingRadialReveal?.cancel()
        pendingRadialReveal = nil
        isEdgeRevealHovering = false

        switch style {
        case .separateWindow:
            hideRadialTabs(animated: false)
            isControlsPinnedOpen = false
            setHoverVisible(false, animated: false)
            openWindow(id: AppModel.controlsWindowID)

        case .radial:
            hideRadialTabs(animated: false)
            isControlsPinnedOpen = false
            setHoverVisible(false, animated: false)
            if appModel.isControlsWindowOpen {
                dismissWindow(id: AppModel.controlsWindowID)
            }

        case .controlPanel:
            hideRadialTabs(animated: true)
            if appModel.isControlsWindowOpen {
                dismissWindow(id: AppModel.controlsWindowID)
            }
            showControls(animated: true)
        }
    }

    private func showRadialLauncher(anchor: CGPoint, windowSize: CGSize) {
        guard launcherStyle == .radial, !appModel.isControlsWindowOpen else { return }

        pendingAutoHide?.cancel()
        pendingAutoHide = nil
        pendingRadialReveal?.cancel()
        pendingRadialReveal = nil
        isControlsPinnedOpen = false
        setHoverVisible(false, animated: false)
        radialAnchor = clampedLauncherAnchor(anchor, windowSize: windowSize)

        // Re-anchoring while visible resets the browse path to the committed
        // tab but must not restart the already-running cache sync.
        guard !isRadialVisible else {
            radialPath = [Self.rootNodeID(for: radialTopDockTab)]
            return
        }

        beginRadialSession()
        if reduceMotion {
            isRadialVisible = true
        } else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                isRadialVisible = true
            }
        }
    }

    private func clampedLauncherAnchor(_ anchor: CGPoint, windowSize: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(anchor.x, 18), windowSize.width - 18),
            y: min(max(anchor.y, 30), windowSize.height - 30)
        )
    }

    private func toggleControlsPin() {
        hideRadialTabs(animated: true)
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
            // While the launcher is up the hover latch has no visual effect
            // (shouldShowControls ignores it), so latching would only leave
            // stale state that flashes the panel open after dismissal.
            if !isRadialVisible { setHoverVisible(true, animated: animated) }
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
        let preferredWidth = launcherStyle == .radial
            ? radialContentPanelPreferredWidth
            : panelPreferredWidth
        let minimumWidth: CGFloat = launcherStyle == .radial ? 720 : contentMinimumSize.width
        return min(
            preferredWidth,
            max(minimumWidth, size.width - minimumVisibleViewportWidth)
        )
    }
}
#endif
