#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct ThresholdMacApp: App {
    @State private var appModel = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Headless offscreen perf sweep (THRESHOLD_BENCHMARK=1). Launched from
        // init because background benchmark runs do not materialize a window.
        if BenchmarkMode.isActive {
            #if DEBUG || THRESHOLD_TESTING
            // Hermetic store root for benchmark runs. Unsigned debug builds
            // cannot resolve the iCloud ubiquity container, so an iCloud-mode
            // user store silently vanishes from the harness catalog. The gate
            // stages its benchmark scenes into a temp store and points the app
            // at it here — before AppModel/PresetManager first resolve a root.
            if let root = ProcessInfo.processInfo.environment["THRESHOLD_BENCHMARK_STORE_ROOT"] {
                StorageLocation.shared.testRootOverride = URL(fileURLWithPath: root, isDirectory: true)
            }
            #endif
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
            AppLifecycle.transition(
                to: newPhase,
                appModel: appModel,
                keepActiveInBackground: BenchmarkMode.isActive
            )
        }
        // Breakout controls window — the same control panel that slides over
        // the render view, hosted in its own window so it can live on another
        // screen (or beside the render window) without covering the fractal.
        Window("Threshold Controls", id: AppModel.controlsWindowID) {
            ThresholdControlsWindowView()
                .environment(appModel)
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
        .defaultSize(width: 880, height: 660)
        .windowResizability(.contentMinSize)

        // Live formula editor: its own window so the fractal viewport stays
        // visible while typing — sliders regenerate per keystroke, the shader
        // swaps in a debounce later.
        Window("Formula Editor", id: AppModel.formulaEditorWindowID) {
            FormulaEditorWindowView()
                .environment(appModel)
        }
        .defaultSize(width: 1180, height: 720)
        .windowResizability(.contentMinSize)

        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Scene…") {
                    openScene()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

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

    private func openScene() {
        let panel = NSOpenPanel()
        panel.title = "Open Scene"
        panel.message = "Choose a Threshold scene file."
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(exportedAs: "com.puppypower.threshold.scene")]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        appModel.openExternalFile(url)
    }
}

private struct ThresholdControlsWindowView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var appearanceGeneration: UInt?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ContentView(handlesStorageChoice: false)

            ViewportChromeShortcutMonitor {
                // Recording mode is owned by the render window's root view;
                // with no viewport mounted there is nothing to record and no
                // monitor left anywhere to toggle back out.
                guard appModel.isRootRenderViewMounted else { return }
                appModel.toggleViewportChromeVisibility()
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
        .frame(minWidth: 980, minHeight: 576)
        .background(Color(white: 0.09))
        .onAppear {
            // A Window-menu request (or an in-flight open request) must not
            // punch through recording mode after its hide transition has won.
            guard !appModel.isViewportChromeHidden else {
                guard appModel.isRootRenderViewMounted else {
                    // Recording mode outlived the render window (its owner).
                    // Self-heal instead of flash-dismissing every reopen of
                    // the only window the user can still summon.
                    appModel.isViewportChromeHidden = false
                    appearanceGeneration = appModel.controlsWindowDidAppear()
                    return
                }
                appModel.requestControlsWindowDismissal()
                dismissWindow(id: AppModel.controlsWindowID)
                return
            }
            appearanceGeneration = appModel.controlsWindowDidAppear()
        }
        .onDisappear {
            appModel.controlsWindowDidDisappear(generation: appearanceGeneration)
            appearanceGeneration = nil
        }
        .onChange(of: appModel.isViewportChromeHidden) { _, isHidden in
            if isHidden {
                appModel.requestControlsWindowDismissal()
                dismissWindow(id: AppModel.controlsWindowID)
            }
        }
    }
}

/// Window-local, single-key shortcut for recording mode. A local event monitor
/// reaches both the Metal viewport and the radial controls without registering
/// a menu command that would steal H from editors elsewhere in the app.
private struct ViewportChromeShortcutMonitor: NSViewRepresentable {
    let onToggle: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onToggle: onToggle)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.onToggle = onToggle
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        weak var hostView: NSView?
        var onToggle: () -> Void
        private var monitor: Any?

        init(onToggle: @escaping () -> Void) {
            self.onToggle = onToggle
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let hostWindow = hostView?.window,
                      event.window === hostWindow,
                      event.charactersIgnoringModifiers?.lowercased() == "h",
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                else { return event }

                // Text fields and source editors must receive literal H input.
                if hostWindow.firstResponder is NSTextView || hostWindow.firstResponder is NSTextField {
                    return event
                }

                // Consume repeat events without retriggering the toggle.
                guard !event.isARepeat else { return nil }
                onToggle()
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// Window-local, unmodified shortcuts for the three most-used control
/// destinations. Keeping these in a local monitor (instead of app menu key
/// equivalents) lets text fields and the formula source editor type P/F/R
/// normally.
private struct ImportantSceneShortcutMonitor: NSViewRepresentable {
    let onParameters: () -> Void
    let onFormula: () -> Void
    let onRadialMenu: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onParameters: onParameters,
            onFormula: onFormula,
            onRadialMenu: onRadialMenu
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.onParameters = onParameters
        context.coordinator.onFormula = onFormula
        context.coordinator.onRadialMenu = onRadialMenu
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        weak var hostView: NSView?
        var onParameters: () -> Void
        var onFormula: () -> Void
        var onRadialMenu: () -> Void
        private var monitor: Any?

        init(
            onParameters: @escaping () -> Void,
            onFormula: @escaping () -> Void,
            onRadialMenu: @escaping () -> Void
        ) {
            self.onParameters = onParameters
            self.onFormula = onFormula
            self.onRadialMenu = onRadialMenu
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let hostWindow = hostView?.window,
                      event.window === hostWindow,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                      let key = event.charactersIgnoringModifiers?.lowercased()
                else { return event }

                if hostWindow.firstResponder is NSTextView || hostWindow.firstResponder is NSTextField {
                    return event
                }

                guard !event.isARepeat else {
                    return ["p", "f", "r"].contains(key) ? nil : event
                }

                switch key {
                case "p": onParameters()
                case "f": onFormula()
                case "r": onRadialMenu()
                default: return event
                }
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
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
    @State private var radialMenu = RadialMenuModel(interactionProfile: .pointer)
    @State private var isShiftPressed = false
    /// Live parameter mirror backing the launcher's hierarchy sliders. Synced
    /// only while the launcher is visible (each live cache costs a 0.5s
    /// main-thread timer), following the ContentView start/stopSync pattern.
    private var radialCache: ControlStateStore { appModel.controlStateStore }
    @State private var activeMenuTrackingCount = 0
    @State private var pendingAutoHide: DispatchWorkItem?
    @State private var pendingRadialReveal: DispatchWorkItem?
    @State private var isViewportHUDVisible = true
    @State private var lastViewportHUDActivity = ProcessInfo.processInfo.systemUptime
    @State private var pendingViewportHUDHide: DispatchWorkItem?
    @State private var isControlFinderPresented = false
    @State private var radialRestoreAnchor: CGPoint?
    @State private var radialRestorePath: [String] = []
    /// Retained only to migrate the previous on/off launcher preference into the
    /// three explicit navigation modes.
    @AppStorage("MacTabLauncher.enabled") private var legacyLauncherEnabled = true
    @AppStorage("MacTabLauncher.navigationModeMigrated.v1") private var didMigrateNavigationMode = false
    @AppStorage("MacTabLauncher.style") private var launcherStyle: NavigationPresentationStyle = .radial
    @AppStorage("MacTabLauncher.curvature") private var launcherCurvature: Double = 0.82
    @AppStorage("hasCompletedIntroOnboarding") private var hasCompletedIntroOnboarding = false
    @State private var showStorageChoice = false

    private var radialActiveWorkspaceRoute: AppRoute {
        if appModel.navigationStore.currentRoute.workspaceRoot != nil {
            return appModel.navigationStore.currentRoute
        }
        return appModel.navigationStore.state.returnRoute ?? .explore(.jumpingOff)
    }

    private var radialWorkspaceRoot: WorkspaceRoot {
        radialActiveWorkspaceRoute.workspaceRoot ?? .explore
    }

    private let contentMinimumSize = CGSize(width: 980, height: 576)
    private let minimumWindowSize = CGSize(width: 1440, height: 640)
    private let panelPreferredWidth: CGFloat = 1040
    private let radialContentPanelPreferredWidth: CGFloat = 840
    private let minimumVisibleViewportWidth: CGFloat = 360
    private let panelPadding: CGFloat = 14
    private let edgeRevealWidth: CGFloat = 46
    private let edgeRevealDelay: TimeInterval = 0.10
    private let autoHideDelay: TimeInterval = 0.22
    private let viewportHUDIdleDelay: TimeInterval = 2.5
    private let panelAnimation = MenuChrome.panelSpring

    private var hasDetachedControls: Bool {
        appModel.isControlsWindowOpen || appModel.isControlsWindowRequested
    }

    private var shouldShowControls: Bool {
        guard !appModel.isViewportChromeHidden else { return false }
        // An import confirmation must stay reachable. If a
        // detached controls window is already hosting it, avoid mounting a
        // duplicate panel in the viewport.
        if appModel.pendingExternalImport != nil && !hasDetachedControls {
            return true
        }
        // Separate Window mode never mounts a second copy over the viewport,
        // even during menu tracking or a stale pin state.
        guard launcherStyle != .separateWindow else { return false }
        // While the controls are broken out into their own window, never show
        // the slide-over sidebar — otherwise the panel appears twice. (The breakout
        // window hosts its own ContentView, so the import sheet below shows there.)
        guard !hasDetachedControls else { return false }
        // While the launcher is up the slide-over panel stays put: quick-input
        // drags mark menu interaction active, which must not summon the panel
        // over the rings mid-adjustment. An explicit pin still wins.
        if radialMenu.isPresented { return isControlsPinnedOpen }
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
                ThresholdMacRenderView(
                    appModel: appModel,
                    allowsPointerRadialPassthrough: isShiftPressed
                )
                    .frame(minWidth: minimumWindowSize.width, minHeight: minimumWindowSize.height)
                    .background(Color.black)
                    .ignoresSafeArea()

                if launcherStyle == .radial && radialMenu.isPresented && !hasDetachedControls
                    && !appModel.isViewportChromeHidden {
                    RadialMenu(
                        size: proxy.size,
                        pointerAnchor: radialMenu.anchor,
                        curvature: $launcherCurvature,
                        projection: radialProjection,
                        interactionProfile: radialMenu.interactionProfile,
                        layout: .radial,
                        allowsPresentationSelection: true,
                        path: Binding(
                            get: { radialMenu.path },
                            set: { radialMenu.path = $0 }
                        ),
                        sceneAccent: RadialMenuSceneAccent.color(from: appModel.renderSettings.gradientColorMap),
                        quickAccessShortcuts: RadialMenuProjectionFactory.quickAccessShortcuts(
                            pinnedRouteIDs: appModel.navigationStore.pinnedRouteIDs,
                            selectedRoute: appModel.navigationStore.currentRoute
                        ),
                        suspendsHoverNavigation: isShiftPressed,
                        hoveredSlider: Binding(
                            get: { radialMenu.hoveredSlider },
                            set: { radialMenu.hoveredSlider = $0 }
                        ),
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
                        onActivateQuickAccess: { route in
                            activateRadialTarget(.route(route))
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

                // The pin toggles the slide-over sidebar, which doesn't exist while
                // the controls are broken out or recording mode is active.
                if !hasDetachedControls && !appModel.isViewportChromeHidden {
                    floatingToggle(windowSize: proxy.size)
                        .padding(.top, panelPadding)
                        .padding(.trailing, panelPadding)
                        .opacity(isViewportHUDVisible ? 1 : 0)
                        .allowsHitTesting(isViewportHUDVisible)
                        .animation(viewportHUDAnimation, value: isViewportHUDVisible)
                }

                // Always-on perf HUD (top-leading, opposite the pin button). Shows
                // FPS plus the continuous GPU-ms cost so acceleration tuning is
                // visible even when the frame rate is pinned by the display refresh.
                if !hasDetachedControls && !appModel.isViewportChromeHidden {
                    FPSIndicatorView()
                        .environment(appModel)
                        .padding(.top, panelPadding)
                        .padding(.leading, panelPadding)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .allowsHitTesting(false)
                        .opacity(isViewportHUDVisible ? 1 : 0)
                        .animation(viewportHUDAnimation, value: isViewportHUDVisible)
                }

                if appModel.isAttributionShortcutHeld && !appModel.isViewportChromeHidden {
                    AttributionOverlay()
                        .padding(24)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .bottomLeading
                        )
                        .allowsHitTesting(false)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .move(edge: .bottom).combined(with: .opacity)
                        )
                        .zIndex(10)
                }

                MacRadialInputMonitor(
                    isPressed: $isShiftPressed,
                    isRadialVisible: radialMenu.isPresented,
                    onMouseMoved: { location in
                        noteViewportHUDActivity()
                        handleWindowMouseMoved(location, windowSize: proxy.size)
                    },
                    onTwoFingerSwipeUp: {
                        hideRadialTabs(animated: true)
                    },
                    isPointerOverSlider: { locationInWindow in
                        // Geometric check: hover-exit events can be dropped, so a
                        // stale hovered id must not hijack scrolls window-wide.
                        // Shift-peek makes the faded pills inert.
                        guard !isShiftPressed, let hovered = radialMenu.hoveredSlider else { return false }
                        let point = CGPoint(
                            x: locationInWindow.x,
                            y: proxy.size.height - locationInWindow.y
                        )
                        return hovered.frame.contains(point)
                    },
                    isPointerOverWindowDragHandle: { locationInWindow in
                        guard radialMenu.isPresented, !isShiftPressed else { return false }
                        let point = CGPoint(
                            x: locationInWindow.x,
                            y: proxy.size.height - locationInWindow.y
                        )
                        return RadialMenu.windowDragHandleFrame(
                            size: proxy.size,
                            pointerAnchor: radialMenu.anchor
                        ).contains(point)
                    },
                    onSliderScroll: { upwardDelta in
                        applyRadialSliderScroll(upwardDelta)
                    }
                )
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)

                ViewportChromeShortcutMonitor {
                    appModel.toggleViewportChromeVisibility()
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)

                ImportantSceneShortcutMonitor(
                    onParameters: {
                        openImportantScene(.input(.parameters))
                    },
                    onFormula: {
                        openImportantScene(.shape(.formula))
                    },
                    onRadialMenu: {
                        toggleRadialShortcut(windowSize: proxy.size)
                    }
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
            .sceneNavigationFeedbackOverlay(
                isObscured: radialMenu.isPresented,
                instruction: "Arrow keys · Swipe card",
                bottomPadding: panelPadding
            )
            .frame(minWidth: minimumWindowSize.width, minHeight: minimumWindowSize.height)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.16),
                value: appModel.isAttributionShortcutHeld
            )
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
            .onChange(of: appModel.isViewportChromeHidden) { _, isHidden in
                // Inside the GeometryReader so the exit path can re-clamp the
                // stashed radial anchor against the size the window has NOW —
                // it may have been resized while the chrome was hidden.
                applyViewportChromeVisibility(isHidden: isHidden, windowSize: proxy.size)
            }
        }
        .frame(minWidth: minimumWindowSize.width, minHeight: minimumWindowSize.height)
        .sheet(isPresented: $isControlFinderPresented) {
            ControlFinderView(
                profile: appModel.platformProfile,
                onSelect: navigateFromControlFinder,
                onDismiss: { isControlFinderPresented = false }
            )
        }
        .sheet(isPresented: Binding(
            get: { !hasCompletedIntroOnboarding },
            set: { _ in }
        )) {
            FirstLaunchWindowView()
                .environment(appModel)
                .interactiveDismissDisabled()
        }
        .onAppear {
            appModel.isRootRenderViewMounted = true
            if hasCompletedIntroOnboarding && !StorageLocation.shared.hasChosenMode {
                showStorageChoice = true
            }
            migrateLegacyNavigationPreferenceIfNeeded()
            Task { @MainActor in
                await appModel.startMicrophoneAtLaunchIfEnabled()
            }
            appModel.openControlFinderHandler = {
                isControlFinderPresented = true
            }
            if launcherStyle == .separateWindow && !appModel.isViewportChromeHidden {
                presentControlsWindow()
            }
            noteViewportHUDActivity()
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
            if !isOpen,
               appModel.isControlsWindowRequested,
               !appModel.isViewportChromeHidden {
                // A late disappearance from an older hide transition must not
                // cancel a newer show request for this singleton Window scene.
                DispatchQueue.main.async {
                    guard appModel.isControlsWindowRequested,
                          !appModel.isViewportChromeHidden else { return }
                    openWindow(id: AppModel.controlsWindowID)
                }
            }
            // The breakout window unmounts the launcher; without this the
            // session (cache sync timer, scroll-consuming monitor state, stale
            // browse path) would silently outlive it and ghost-remount later.
            if isOpen { hideRadialTabs(animated: false) }
        }
        .onChange(of: appModel.pendingExternalImport != nil) { _, isPending in
            // Opening a file is an explicit interruption to recording. Leave
            // the clean view so its confirmation sheet has a mounted host.
            if isPending && appModel.isViewportChromeHidden {
                appModel.isViewportChromeHidden = false
            }
        }
        .onChange(of: hasCompletedIntroOnboarding) { _, completed in
            guard completed, !StorageLocation.shared.hasChosenMode else { return }
            Task { @MainActor in
                await Task.yield()
                showStorageChoice = true
            }
        }
        .sheet(isPresented: $showStorageChoice) {
            StorageModeChoiceSheet { chosen in
                if chosen != StorageLocation.shared.mode {
                    appModel.switchStorageMode(to: chosen)
                } else {
                    StorageLocation.shared.markModeChosen()
                }
                showStorageChoice = false
            }
            .interactiveDismissDisabled(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppModel.fractalSettingsDidChangeNotification)) { _ in
            // Scene/preset loads replace RenderSettings values wholesale; the
            // launcher's slider mirrors must resnapshot or they scrub stale bases.
            if radialMenu.isPresented { radialCache.loadFromSettings() }
        }
        .onDisappear {
            appModel.isRootRenderViewMounted = false
            // Recording mode must not outlive the viewport it records: with
            // this view unmounted there is no H monitor, restore logic, or
            // exit affordance left to leave it.
            appModel.isViewportChromeHidden = false
            appModel.openControlFinderHandler = nil
            pendingAutoHide?.cancel()
            pendingAutoHide = nil
            pendingRadialReveal?.cancel()
            pendingRadialReveal = nil
            pendingViewportHUDHide?.cancel()
            pendingViewportHUDHide = nil
            endRadialSession()
        }
    }

    private var viewportHUDAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.28)
    }

    /// Keeps the lightweight viewport affordances available while the pointer is
    /// active, then gets them out of the way once the user settles on the artwork.
    /// One pending work item re-checks the latest activity time instead of
    /// cancelling and allocating a new item for every high-frequency mouse event.
    private func noteViewportHUDActivity() {
        lastViewportHUDActivity = ProcessInfo.processInfo.systemUptime
        if !isViewportHUDVisible {
            withAnimation(viewportHUDAnimation) {
                isViewportHUDVisible = true
            }
        }
        scheduleViewportHUDHideIfNeeded()
    }

    private func scheduleViewportHUDHideIfNeeded(after delay: TimeInterval? = nil) {
        guard pendingViewportHUDHide == nil else { return }

        let workItem = DispatchWorkItem {
            pendingViewportHUDHide = nil
            let idleTime = ProcessInfo.processInfo.systemUptime - lastViewportHUDActivity
            guard idleTime >= viewportHUDIdleDelay else {
                scheduleViewportHUDHideIfNeeded(after: viewportHUDIdleDelay - idleTime)
                return
            }
            withAnimation(viewportHUDAnimation) {
                isViewportHUDVisible = false
            }
        }
        pendingViewportHUDHide = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (delay ?? viewportHUDIdleDelay),
            execute: workItem
        )
    }

    private var slideOverPanel: some View {
        ContentView(
            showsOuterNavigation: launcherStyle != .radial,
            handlesStorageChoice: false
        )
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
            // The panel stays mounted during the press so the isolate gesture
            // receives its release edge, while its visual chrome disappears.
            .opacity(appModel.isAudioReactivityIsolationPreviewActive ? 0 : 1)
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
                return radialMenu.isPresented ? "Hide Menu" : "Menu"
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
                .foregroundStyle(radialMenu.isPresented ? Color.accentColor : Color.primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(radialMenu.isPresented ? "Hide radial menu (⌘.)" : "Open \(launcherStyle.displayName.lowercased()) (⌘.)")
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
        // Choosing a destination is an explicit interruption to recording,
        // like an external import: otherwise the activation is invisible
        // (shouldShowControls stays false) and the pin latched below pops the
        // panel open only much later, on the next H press. Cancelling the
        // finder instead (Esc) keeps the clean recording view. The stashed
        // radial state is dropped so exiting recording here doesn't also
        // re-present the launcher over the destination panel.
        if appModel.isViewportChromeHidden {
            radialRestoreAnchor = nil
            radialRestorePath = []
            appModel.isViewportChromeHidden = false
        }
        hideRadialTabs(animated: false)
        withAnimation(motionSensitivePanelAnimation) {
            isControlsPinnedOpen = true
            switch appModel.navigationStore.activate(destination.target) {
            case .openAnimationEditor:
                if appModel.animationManager?.currentScene == nil {
                    appModel.animationManager?.currentScene = appModel.animationManager?.scenes.first
                }
                openWindow(id: AppModel.animationEditorWindowID)
            case nil, .toggleRadialMenu, .dismissRadialMenu, .resetViewport,
                 .toggleAnimationPlayback, .selectRoute: break
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
        guard !appModel.isViewportChromeHidden else { return }
        let isInsideRevealEdge = location.x >= windowSize.width - edgeRevealWidth
            && location.x <= windowSize.width + 2

        if radialMenu.isPresented {
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
        radialMenu.anchor = clampedLauncherAnchor(
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
              !radialMenu.isPresented,
              pendingRadialReveal == nil,
              !shouldShowControls else { return }

        let workItem = DispatchWorkItem {
            pendingRadialReveal = nil
            guard !radialMenu.isPresented,
                  isEdgeRevealHovering,
                  !shouldShowControls else { return }

            if launcherStyle == .controlPanel {
                showControls(animated: true)
                return
            }

            guard launcherStyle == .radial else { return }

            guard beginRadialSession() else { return }
            let path = [Self.rootNodeID(for: radialWorkspaceRoot)]
            if reduceMotion {
                radialMenu.present(at: radialMenu.anchor, initialPath: path)
            } else {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    radialMenu.present(at: radialMenu.anchor, initialPath: path)
                }
            }
        }
        pendingRadialReveal = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + edgeRevealDelay, execute: workItem)
    }

    private func hideRadialTabs(animated: Bool) {
        pendingRadialReveal?.cancel()
        pendingRadialReveal = nil
        guard radialMenu.isPresented else {
            // Also repair an interrupted presentation that claimed ownership
            // before its visible state was committed.
            endRadialSession()
            return
        }

        endRadialSession()
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.14)) {
                radialMenu.dismiss()
            }
        } else {
            radialMenu.dismiss()
        }
    }

    /// Prepares the launcher's transient state for a reveal: browsing path at
    /// the committed dock tab, and a live slider cache. startSync is only safe
    /// to call once per session, so both reveal paths route through here while
    /// the launcher is still hidden.
    private func beginRadialSession() -> Bool {
        // Presentation requests can converge in the same run-loop turn (edge,
        // keyboard, and button). Treat an existing claim as the same session
        // instead of incrementing the ownership store's re-entrant count.
        if appModel.inputOwnershipStore.owner == .radialMenu { return true }
        guard appModel.inputOwnershipStore.claim(.radialMenu) else { return false }
        radialCache.startSync(with: appModel.renderSettings, appModel: appModel)
        return true
    }

    private func endRadialSession() {
        guard appModel.inputOwnershipStore.owner == .radialMenu else { return }
        appModel.inputOwnershipStore.release(.radialMenu)
        radialCache.stopSync()
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: Shared hierarchy → radial projection
    //
    // `NavigationHierarchy` owns the routes, labels, and ordering used by the
    // existing cross-platform grid. This host adapter supplies selection and
    // fallback actions; the radial model and renderer are shared with iPadOS.
    // ═══════════════════════════════════════════════════════════════════════

    static func rootNodeID(for root: WorkspaceRoot) -> String {
        NavigationHierarchy.rootID(for: root)
    }

    private var radialProjection: RadialNavigationProjection {
        RadialMenuProjectionFactory.make(
            appModel: appModel,
            allowsCustomScenes: true,
            onActivate: activateRadialTarget
        )
    }

    private func activateRadialTarget(_ target: AppNavigationTarget) {
        let command = appModel.navigationStore.activate(target)
        switch command {
        case .openAnimationEditor:
            if appModel.animationManager?.currentScene == nil {
                appModel.animationManager?.currentScene = appModel.animationManager?.scenes.first
            }
            hideRadialTabs(animated: true)
            openWindow(id: AppModel.animationEditorWindowID)
        case .resetViewport:
            appModel.viewportCommandHandler?(.resetViewport)
            hideRadialTabs(animated: true)
        case .toggleAnimationPlayback:
            appModel.toggleAnimationPlayback()
        case .toggleRadialMenu, .dismissRadialMenu:
            hideRadialTabs(animated: true)
        case .selectRoute(let route):
            appModel.navigationStore.select(route)
            showControlsAfterLauncherSelection()
        case nil:
            showControlsAfterLauncherSelection()
        }
    }

    /// Trackpad scroll over a hovered slider pill, normalized so physical
    /// finger-up increases the value. 240pt of travel sweeps the full range —
    /// finer than the arc drag, for dialing in exact values.
    private func applyRadialSliderScroll(_ upwardDelta: CGFloat) {
        guard let hovered = radialMenu.hoveredSlider,
              let slider = radialProjection.node(withID: hovered.id)?.slider,
              slider.isEnabled() else { return }
        let span = slider.range.upperBound - slider.range.lowerBound
        let value = (slider.read() + Float(upwardDelta / 240) * span).clamped(to: slider.range)
        slider.writeIfEnabled(value)
    }

    private func showControlsAfterLauncherSelection() {
        hideRadialTabs(animated: true)
        showControls(animated: true)
    }

    private func toggleSelectedNavigation(windowSize: CGSize) {
        switch launcherStyle {
        case .separateWindow:
            presentControlsWindow()

        case .controlPanel:
            guard !hasDetachedControls else { return }
            if shouldShowControls {
                isControlsPinnedOpen = false
                setHoverVisible(false, animated: true)
            } else {
                showControls(animated: true)
            }

        case .radial:
            guard !hasDetachedControls else { return }
            if radialMenu.isPresented {
                hideRadialTabs(animated: true)
                return
            }

            showRadialLauncher(
                anchor: CGPoint(x: windowSize.width - 18, y: windowSize.height * 0.48),
                windowSize: windowSize
            )
        }
    }

    private func openImportantScene(_ route: AppRoute) {
        guard !appModel.isViewportChromeHidden else { return }
        hideRadialTabs(animated: false)
        appModel.navigationStore.select(route)

        switch launcherStyle {
        case .separateWindow:
            presentControlsWindow()
        case .radial, .controlPanel:
            showControls(animated: true)
        }
    }

    private func toggleRadialShortcut(windowSize: CGSize) {
        guard !appModel.isViewportChromeHidden, !hasDetachedControls else { return }

        let toggle = {
            toggleSelectedNavigation(windowSize: windowSize)
        }
        guard launcherStyle != .radial else {
            toggle()
            return
        }

        // applyNavigationStyle runs from onChange and clears the previous
        // presentation. Reveal on the next turn so that cleanup happens first.
        launcherStyle = .radial
        DispatchQueue.main.async {
            toggleSelectedNavigation(windowSize: windowSize)
        }
    }

    /// Viewport clicks are toggles. In particular, a click outside an already
    /// open radial menu dismisses it instead of moving its anchor and resetting
    /// the current path.
    private func handleViewportClick(anchor: CGPoint, windowSize: CGSize) {
        guard !appModel.isViewportChromeHidden else { return }
        switch launcherStyle {
        case .separateWindow:
            presentControlsWindow()

        case .controlPanel:
            if shouldShowControls {
                isControlsPinnedOpen = false
                setHoverVisible(false, animated: true)
            } else {
                showControls(animated: true)
            }

        case .radial:
            if radialMenu.isPresented {
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

    /// Applies the recording-mode state toggled by H. The persisted FPS
    /// preference and panel pin/hover state stay untouched, so leaving recording
    /// mode restores exactly the chrome that was visible beforehand.
    private func applyViewportChromeVisibility(isHidden: Bool, windowSize: CGSize) {
        if !isHidden {
            if appModel.shouldRestoreControlsWindowAfterRecording {
                presentControlsWindow()
            }

            if let anchor = radialRestoreAnchor {
                let path = radialRestorePath
                radialRestoreAnchor = nil
                radialRestorePath = []
                if beginRadialSession() {
                    // The window may have been resized while the chrome was
                    // hidden, leaving the stashed anchor out of bounds.
                    let clamped = clampedLauncherAnchor(anchor, windowSize: windowSize)
                    if reduceMotion {
                        radialMenu.present(at: clamped, initialPath: path)
                    } else {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            radialMenu.present(at: clamped, initialPath: path)
                        }
                    }
                }
            }
            return
        }

        if radialMenu.isPresented {
            radialRestoreAnchor = radialMenu.anchor
            radialRestorePath = radialMenu.path
            hideRadialTabs(animated: true)
        } else {
            radialRestoreAnchor = nil
            radialRestorePath = []
        }

        pendingAutoHide?.cancel()
        pendingAutoHide = nil
        pendingRadialReveal?.cancel()
        pendingRadialReveal = nil

        if appModel.isControlsWindowRequested || appModel.isControlsWindowOpen {
            dismissControlsWindow()
        }
    }

    private func presentControlsWindow() {
        appModel.requestControlsWindowPresentation()
        openWindow(id: AppModel.controlsWindowID)
    }

    private func dismissControlsWindow() {
        appModel.requestControlsWindowDismissal()
        dismissWindow(id: AppModel.controlsWindowID)
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
            presentControlsWindow()

        case .radial:
            hideRadialTabs(animated: false)
            isControlsPinnedOpen = false
            setHoverVisible(false, animated: false)
            if appModel.isControlsWindowRequested || appModel.isControlsWindowOpen {
                dismissControlsWindow()
            }

        case .controlPanel:
            hideRadialTabs(animated: true)
            if appModel.isControlsWindowRequested || appModel.isControlsWindowOpen {
                dismissControlsWindow()
            }
            showControls(animated: true)
        }
    }

    private func showRadialLauncher(anchor: CGPoint, windowSize: CGSize) {
        guard launcherStyle == .radial, !hasDetachedControls else { return }

        pendingAutoHide?.cancel()
        pendingAutoHide = nil
        pendingRadialReveal?.cancel()
        pendingRadialReveal = nil
        isControlsPinnedOpen = false
        setHoverVisible(false, animated: false)
        let clampedAnchor = clampedLauncherAnchor(anchor, windowSize: windowSize)

        // Re-anchoring while visible resets the browse path to the committed
        // tab but must not restart the already-running cache sync.
        guard !radialMenu.isPresented else {
            radialMenu.anchor = clampedAnchor
            radialMenu.path = [Self.rootNodeID(for: radialWorkspaceRoot)]
            return
        }

        guard beginRadialSession() else { return }
        let path = [Self.rootNodeID(for: radialWorkspaceRoot)]
        if reduceMotion {
            radialMenu.present(at: clampedAnchor, initialPath: path)
        } else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                radialMenu.present(at: clampedAnchor, initialPath: path)
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
            if !radialMenu.isPresented { setHoverVisible(true, animated: animated) }
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
