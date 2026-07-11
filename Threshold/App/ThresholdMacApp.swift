#if os(macOS)
import AppKit
import SwiftUI

@main
struct ThresholdMacApp: App {
    @State private var appModel = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        MetricKitReporter.shared.start()
    }

    var body: some Scene {
        Window("Threshold", id: appModel.menuWindowID) {
            ThresholdMacRootView()
                .environment(appModel)
                .onOpenURL { url in
                    appModel.openExternalFile(url)
                }
                .task {
                    // Headless offscreen perf sweep; runs and exits only when
                    // THRESHOLD_BENCHMARK=1 (see MacBenchmarkHarness).
                    if BenchmarkMode.isActive {
                        await MacBenchmarkHarness.run(appModel: appModel)
                    }
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
                Task { await UsageAnalytics.shared.endSession() }
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
    @State private var isHoverVisible = false
    @State private var isPaneHovering = false
    @State private var isEdgeRevealHovering = false
    @State private var isRadialVisible = false
    @State private var isShiftPressed = false
    @State private var radialAnchor = CGPoint(x: 1400, y: 320)
    @State private var radialCategory: TopDockTab = .explore
    @State private var lastPointerX: CGFloat?
    @State private var rightwardEdgeTravel: CGFloat = 0
    @State private var activeMenuTrackingCount = 0
    @State private var pendingAutoHide: DispatchWorkItem?
    @State private var pendingRadialReveal: DispatchWorkItem?

    @AppStorage("MacTabLauncher.style") private var launcherStyle: MacTabLauncherStyle = .radial
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
    @AppStorage("allowCustomScenes") private var allowCustomScenes = false

    private let contentMinimumSize = CGSize(width: 980, height: 576)
    private let minimumWindowSize = CGSize(width: 1440, height: 640)
    private let panelPreferredWidth: CGFloat = 1040
    private let minimumVisibleViewportWidth: CGFloat = 360
    private let panelPadding: CGFloat = 14
    private let edgeRevealWidth: CGFloat = 46
    private let edgeRevealTravel: CGFloat = 16
    private let radialRevealDelay: TimeInterval = 0.18
    private let autoHideDelay: TimeInterval = 0.22
    private let panelAnimation = MenuChrome.panelSpring

    private var shouldShowControls: Bool {
        // While the controls are broken out into their own window, never show
        // the slide-over sidebar — otherwise the panel appears twice. (The breakout
        // window hosts its own ContentView, so the import sheet below shows there.)
        guard !appModel.isControlsWindowOpen else { return false }
        // Force the panel open while an external-file import is pending. The import
        // confirmation sheet is hosted by ContentView *inside* this panel, so if the
        // panel auto-hides — or was never revealed when a file was opened from Finder —
        // ContentView unmounts and the sheet auto-dismisses before the user can act.
        if appModel.pendingExternalImport != nil { return true }
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

                if isRadialVisible && !appModel.isControlsWindowOpen {
                    MacRadialTabMenu(
                        size: proxy.size,
                        pointerAnchor: radialAnchor,
                        curvature: $launcherCurvature,
                        primaryItems: radialPrimaryItems,
                        childItems: radialChildItems,
                        layoutStyle: $launcherStyle,
                        sceneAccent: MacTabSceneAccent.color(from: appModel.renderSettings.gradientColorMap)
                    )
                    .opacity(isShiftPressed ? 0.16 : 1)
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

                MacTabInputMonitor(
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
                launcherStyle = .radial
                showRadialLauncher(
                    anchor: CGPoint(
                        x: value.pointValue.x,
                        y: proxy.size.height - value.pointValue.y
                    ),
                    windowSize: proxy.size
                )
            }
        }
        .frame(minWidth: minimumWindowSize.width, minHeight: minimumWindowSize.height)
        .onChange(of: appModel.isMenuInteractionActive) { _, _ in
            updateAutoHideState(animated: true)
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
        .onDisappear {
            pendingAutoHide?.cancel()
            pendingAutoHide = nil
            pendingRadialReveal?.cancel()
            pendingRadialReveal = nil
        }
    }

    private var slideOverPanel: some View {
        ContentView()
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
        Button {
            toggleRadialLauncher(windowSize: windowSize)
        } label: {
            Image(systemName: launcherStyle.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(isRadialVisible ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .help(isRadialVisible ? "Hide control tabs (⌘.)" : "Show control tabs (⌘.)")
        .keyboardShortcut(".", modifiers: .command)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .foregroundStyle(.primary)
        .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
        .contextMenu {
            Button(isControlsPinnedOpen ? "Unpin Full Controls" : "Pin Full Controls") {
                toggleControlsPin()
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
        let deltaX = location.x - (lastPointerX ?? location.x)
        lastPointerX = location.x

        let isInsideRevealEdge = location.x >= windowSize.width - edgeRevealWidth
            && location.x <= windowSize.width + 2

        if isRadialVisible {
            // Keep the launcher fixed after it opens. If the anchor follows the
            // pointer, every button moves away while the user approaches it and
            // the eventual click falls through to the viewport instead.
            isEdgeRevealHovering = isInsideRevealEdge
            rightwardEdgeTravel = 0
            pendingRadialReveal?.cancel()
            pendingRadialReveal = nil
            return
        }

        guard isInsideRevealEdge else {
            if isEdgeRevealHovering {
                isEdgeRevealHovering = false
                rightwardEdgeTravel = 0
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

        if deltaX > 0 {
            rightwardEdgeTravel += deltaX
        } else if deltaX < -3 {
            rightwardEdgeTravel = max(0, rightwardEdgeTravel + deltaX)
        }

        if rightwardEdgeTravel >= edgeRevealTravel {
            scheduleRadialReveal()
        }
    }

    private func scheduleRadialReveal() {
        guard !isRadialVisible, pendingRadialReveal == nil, !shouldShowControls else { return }

        let workItem = DispatchWorkItem {
            pendingRadialReveal = nil
            guard isEdgeRevealHovering,
                  rightwardEdgeTravel >= edgeRevealTravel,
                  !shouldShowControls else { return }

            radialCategory = radialTopDockTab
            if reduceMotion {
                isRadialVisible = true
            } else {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    isRadialVisible = true
                }
            }
        }
        pendingRadialReveal = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + radialRevealDelay, execute: workItem)
    }

    private func hideRadialTabs(animated: Bool) {
        pendingRadialReveal?.cancel()
        pendingRadialReveal = nil
        guard isRadialVisible else { return }

        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.14)) {
                isRadialVisible = false
            }
        } else {
            isRadialVisible = false
        }
    }

    private var radialPrimaryItems: [MacRadialTabItem] {
        let dockItems = TopDockTab.allCases.map { tab in
            MacRadialTabItem(
                id: "root.\(tab.rawValue)",
                title: tab.title,
                systemImage: tab.icon,
                isSelected: radialCategory == tab
            ) {
                if reduceMotion {
                    radialCategory = tab
                } else {
                    withAnimation(.easeOut(duration: 0.16)) {
                        radialCategory = tab
                    }
                }
            }
        }

        return dockItems + [
            MacRadialTabItem(
                id: "root.quickToggles",
                title: "Quick Toggles",
                systemImage: SidebarTab.quickToggles.icon,
                isSelected: radialSelectedTab == .quickToggles
            ) {
                radialSelectedTab = .quickToggles
                showControlsAfterLauncherSelection()
            },
            MacRadialTabItem(
                id: "root.settings",
                title: "Settings",
                systemImage: SidebarTab.settings.icon,
                isSelected: radialSelectedTab == .settings
            ) {
                radialSelectedTab = .settings
                showControlsAfterLauncherSelection()
            }
        ]
    }

    private var radialChildItems: [MacRadialTabItem] {
        switch radialCategory {
        case .explore:
            return ExploreRailSection.allCases
                .filter { $0 != .mixed && ($0 != .customScenes || allowCustomScenes) }
                .map { section in
                    MacRadialTabItem(
                        id: "explore.\(section.rawValue)",
                        title: section.rawValue,
                        systemImage: section.icon,
                        isSelected: radialTopDockTab == .explore && radialExploreSection == section && radialSelectedTab == .fractal
                    ) {
                        activateExploreFromLauncher(section)
                    }
                }

        case .shape:
            return ShapeRailSection.allCases.filter { $0 != .performance }.map { section in
                MacRadialTabItem(
                    id: "shape.\(section.rawValue)",
                    title: section.rawValue,
                    systemImage: section.icon,
                    isSelected: radialTopDockTab == .shape && radialShapeSection == section && radialSelectedTab == .fractal
                ) {
                    activateShapeFromLauncher(section)
                }
            }

        case .visualizations:
            return VisualizationsRailSection.allCases.map { section in
                MacRadialTabItem(
                    id: "visualizations.\(section.rawValue)",
                    title: section.title,
                    systemImage: section.icon,
                    isSelected: radialTopDockTab == .visualizations && radialVisualizationsSection == section
                ) {
                    activateVisualizationsFromLauncher(section)
                }
            }

        case .music:
            return MusicRailSection.availableCases.map { section in
                MacRadialTabItem(
                    id: "music.\(section.rawValue)",
                    title: section.title,
                    systemImage: section.icon,
                    isSelected: radialTopDockTab == .music && radialMusicSection == section && radialSelectedTab == .music
                ) {
                    activateMusicFromLauncher(section)
                }
            }

        case .performance:
            return PerformanceRailSection.allCases.map { section in
                MacRadialTabItem(
                    id: "performance.\(section.rawValue)",
                    title: section.rawValue,
                    systemImage: section.icon,
                    isSelected: radialTopDockTab == .performance && radialPerformanceSection == section
                ) {
                    activatePerformanceFromLauncher(section)
                }
            }
        }
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
            radialMusicPanelTab = .visualizations
            radialSelectedTab = .music
        }
        showControlsAfterLauncherSelection()
    }

    private func activateMusicFromLauncher(_ section: MusicRailSection) {
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

    private func toggleRadialLauncher(windowSize: CGSize) {
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

    private func showRadialLauncher(anchor: CGPoint, windowSize: CGSize) {
        guard !appModel.isControlsWindowOpen else { return }

        pendingAutoHide?.cancel()
        pendingAutoHide = nil
        isControlsPinnedOpen = false
        setHoverVisible(false, animated: false)
        radialCategory = radialTopDockTab
        radialAnchor = clampedLauncherAnchor(anchor, windowSize: windowSize)

        guard !isRadialVisible else { return }

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
#endif
