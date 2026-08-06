#if os(iOS)
import SwiftUI
import UIKit

@main
struct ThresholdiOSApp: App {
    var body: some Scene {
        WindowGroup {
            ThresholdiOSBootstrapView()
        }
    }
}

private enum ThresholdiOSStartupPhase {
    case preparing
    case sceneLibrary
    case renderer
    case finishing

    var title: String {
        switch self {
        case .preparing: "Preparing Threshold"
        case .sceneLibrary: "Loading scene library"
        case .renderer: "Preparing the renderer"
        case .finishing: "Opening your scene"
        }
    }

    var detail: String {
        switch self {
        case .preparing:
            "Getting the workspace ready."
        case .sceneLibrary:
            "Restoring your settings and installing included scenes. First launch can take a moment."
        case .renderer:
            "Compiling the Metal pipeline for this iPad."
        case .finishing:
            "The first frame is ready."
        }
    }
}

/// Presents a real frame before constructing the heavyweight app model. Cold
/// launch setup decodes and seeds the scene catalog, then creates several Metal
/// pipelines; doing that from `ThresholdiOSApp`'s stored-property initializer
/// left the launch window looking frozen until all of it completed.
private struct ThresholdiOSBootstrapView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var appModel: AppModel? = nil
    @State private var pendingOpenURL: URL? = nil
    @State private var isCreatingAppModel = false
    @State private var isStartupComplete = false

    private var startupPrerequisitesReady: Bool {
        guard let appModel else { return false }
        return appModel.presetManager.isInitialLoadComplete
            && appModel.rendererStartupWarmupComplete
    }

    private var phase: ThresholdiOSStartupPhase {
        guard let appModel else {
            return isCreatingAppModel ? .sceneLibrary : .preparing
        }
        if !appModel.presetManager.isInitialLoadComplete { return .sceneLibrary }
        if !appModel.rendererStartupWarmupComplete { return .renderer }
        return .finishing
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let appModel {
                ThresholdiOSRootView(startupComplete: isStartupComplete)
                    .environment(appModel)
            }

            if !isStartupComplete {
                ThresholdiOSLoadingView(phase: phase)
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .task {
            guard appModel == nil, !isCreatingAppModel else { return }
            isCreatingAppModel = true

            // Let SwiftUI commit the branded loading surface before any scene
            // catalog decoding, first-run seeding, or Metal setup begins.
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }

            let model = AppModel()
            appModel = model
            isCreatingAppModel = false

            if let pendingOpenURL {
                self.pendingOpenURL = nil
                model.openExternalFile(pendingOpenURL)
            }
        }
        .task(id: startupPrerequisitesReady) {
            guard startupPrerequisitesReady, !isStartupComplete else { return }

            // Keep the loader through at least one composited frame after the
            // renderer signals readiness; this avoids revealing a transient
            // black MTKView while the first drawable reaches the display.
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard startupPrerequisitesReady else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) {
                isStartupComplete = true
            }
        }
        .onOpenURL { url in
            if let appModel {
                appModel.openExternalFile(url)
            } else {
                pendingOpenURL = url
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard let appModel else { return }
            AppLifecycle.transition(to: newPhase, appModel: appModel)
        }
    }
}

private struct ThresholdiOSLoadingView: View {
    let phase: ThresholdiOSStartupPhase

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.005, green: 0.008, blue: 0.014),
                    Color(red: 0.018, green: 0.008, blue: 0.035),
                    Color.black,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color.purple.opacity(0.15))
                .frame(width: 430, height: 430)
                .blur(radius: 90)
                .scaleEffect(isPulsing ? 1.08 : 0.92)
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                Spacer(minLength: 32)

                Image("LaunchWindowIcon")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 156, height: 156)
                    .shadow(color: Color.pink.opacity(0.24), radius: 32)
                    .accessibilityHidden(true)

                Text("THRESHOLD")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .tracking(7)
                    .foregroundStyle(.white)
                    .padding(.top, 14)

                Text("REAL-TIME FRACTAL EXPLORATION")
                    .font(.caption2.weight(.semibold))
                    .tracking(2.2)
                    .foregroundStyle(.white.opacity(0.48))
                    .padding(.top, 8)

                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)

                    Text(phase.title)
                        .font(.headline)
                        .foregroundStyle(.white)

                    Text(phase.detail)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.62))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .contentTransition(.opacity)
                }
                .padding(.top, 42)

                Spacer(minLength: 32)

                Label("Swipe with three fingers to change scenes", systemImage: "hand.draw")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.06), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                    .padding(.bottom, 30)
            }
            .padding(.horizontal, 32)
        }
        .contentShape(Rectangle())
        .allowsHitTesting(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Threshold is loading")
        .accessibilityValue(phase.title)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}

/// Compact scene confirmation and one-finger browsing control. The canvas keeps
/// its three-finger gesture; this small card offers an easier rapid-step target
/// after the user has already changed scenes once.
private struct ThresholdiOSSceneNavigationFeedbackView: View {
    private enum NavigationButtonFocus: Hashable {
        case previous
        case next
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var focusedNavigationButton: NavigationButtonFocus?
    @GestureState private var dragTranslation: CGSize?

    let feedback: SceneNavigationFeedback
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onInteractionChanged: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            navigationButton(
                systemImage: "chevron.left",
                accessibilityLabel: "Previous scene",
                focus: .previous,
                action: onPrevious
            )

            VStack(spacing: 2) {
                Text(feedback.sceneName)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("Swipe card · 3-finger swipe on canvas")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(cardDragGesture)
            // The result is announced once by the root. Leave only the two
            // concrete navigation buttons in VoiceOver's traversal order.
            .accessibilityHidden(true)

            navigationButton(
                systemImage: "chevron.right",
                accessibilityLabel: "Next scene",
                focus: .next,
                action: onNext
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: 480)
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.orange.opacity(0.42), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.4), radius: 12, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .offset(x: cardDragOffset)
        .animation(
            reduceMotion ? nil : .interactiveSpring(response: 0.24, dampingFraction: 0.82),
            value: cardDragOffset
        )
        .onChange(of: isActivelyInteracting) { _, isInteracting in
            onInteractionChanged(isInteracting)
        }
        .onDisappear {
            onInteractionChanged(false)
        }
    }

    private var cardDragOffset: CGFloat {
        guard !reduceMotion, let dragTranslation else { return 0 }
        return min(max(dragTranslation.width * 0.22, -28), 28)
    }

    private var isActivelyInteracting: Bool {
        dragTranslation != nil || focusedNavigationButton != nil
    }

    private var cardDragGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let step = SceneSwipeGesturePolicy.sceneStep(
                    for: SIMD2(Float(value.translation.width), Float(value.translation.height))
                )
                switch step {
                case -1: onPrevious()
                case 1: onNext()
                default: break
                }
            }
    }

    private func navigationButton(
        systemImage: String,
        accessibilityLabel: String,
        focus: NavigationButtonFocus,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.bold))
                .foregroundStyle(.orange)
                .frame(width: 44, height: 44)
                .background(Color.orange.opacity(0.16), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityFocused($focusedNavigationButton, equals: focus)
    }
}

private struct SceneNavigationFeedbackDismissalID: Equatable {
    let feedbackID: UUID?
    let interactionGeneration: UInt64
    let isInteracting: Bool
}

private struct ThresholdiOSRootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    let startupComplete: Bool
    @State private var isShowingControls = true
    @State private var radialMenu = RadialMenuModel(interactionProfile: .touch)
    @State private var radialCurvature = 0.72
    @State private var presentedSceneNavigationFeedback: SceneNavigationFeedback?
    @State private var sceneNavigationInteractionGeneration: UInt64 = 0
    @State private var isInteractingWithSceneNavigationFeedback = false
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
                    if startupComplete {
                        controlsToggle
                            // The Metal surface stays edge-to-edge, but the control must
                            // clear the status bar and Stage Manager window chrome.
                            .padding(.top, max(16, safeAreaInsets.top + 8))
                            .padding(.trailing, max(16, safeAreaInsets.trailing + 8))
                    }
                }
                .overlay(alignment: .bottom) {
                    if startupComplete,
                       !radialMenu.isPresented,
                       let feedback = presentedSceneNavigationFeedback {
                        ThresholdiOSSceneNavigationFeedbackView(
                            feedback: feedback,
                            onPrevious: { navigateToAdjacentScene(forward: false) },
                            onNext: { navigateToAdjacentScene(forward: true) },
                            onInteractionChanged: { isInteracting in
                                isInteractingWithSceneNavigationFeedback = isInteracting
                            }
                        )
                            .padding(.horizontal, 24)
                            .padding(.bottom, max(22, safeAreaInsets.bottom + 12))
                            .transition(sceneNavigationTransition(for: feedback))
                            .zIndex(8)
                    }
                }
                .inspector(isPresented: Binding(
                    get: { startupComplete && isShowingControls },
                    set: { if startupComplete { isShowingControls = $0 } }
                )) {
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
                .accessibilityAction(named: Text("Previous scene")) {
                    guard startupComplete else { return }
                    navigateToAdjacentScene(forward: false)
                }
                .accessibilityAction(named: Text("Next scene")) {
                    guard startupComplete else { return }
                    navigateToAdjacentScene(forward: true)
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
        .onAppear {
            Task { @MainActor in
                await appModel.startMicrophoneAtLaunchIfEnabled()
            }
        }
        .onChange(of: appModel.sceneNavigationFeedback) { _, feedback in
            guard let feedback else { return }
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.84)) {
                presentedSceneNavigationFeedback = feedback
            }
        }
        .task(id: SceneNavigationFeedbackDismissalID(
            feedbackID: presentedSceneNavigationFeedback?.id,
            interactionGeneration: sceneNavigationInteractionGeneration,
            isInteracting: isInteractingWithSceneNavigationFeedback
        )) {
            guard !isInteractingWithSceneNavigationFeedback else { return }
            guard let feedbackID = presentedSceneNavigationFeedback?.id else { return }
            do {
                try await Task.sleep(for: .milliseconds(voiceOverEnabled ? 8_000 : 2_800))
            } catch {
                return
            }
            guard presentedSceneNavigationFeedback?.id == feedbackID else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                presentedSceneNavigationFeedback = nil
            }
        }
        .task(id: appModel.sceneNavigationFeedback?.id) {
            guard let feedback = appModel.sceneNavigationFeedback else { return }
            do {
                // Coalesce speech when several fast scene loads complete.
                try await Task.sleep(for: .milliseconds(220))
            } catch {
                return
            }
            guard appModel.sceneNavigationFeedback?.id == feedback.id else { return }
            PlatformAccessibilityAdapter.announce("Scene loaded: \(feedback.sceneName)")
        }
    }

    private func sceneNavigationTransition(
        for feedback: SceneNavigationFeedback
    ) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let edge: Edge = feedback.direction == .next ? .trailing : .leading
        return .move(edge: edge).combined(with: .opacity)
    }

    private func navigateToAdjacentScene(forward: Bool) {
        guard startupComplete else { return }
        sceneNavigationInteractionGeneration &+= 1
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        appModel.cycleConfiguredSceneGroupOrStaticScene(forward: forward)
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

    private func activateRadialTarget(_ target: AppNavigationTarget) {
        let command = appModel.navigationStore.activate(target)
        switch command {
        case .openAnimationEditor:
            dismissRadialMenu()
            appModel.openAnimationEditorHandler?()
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
