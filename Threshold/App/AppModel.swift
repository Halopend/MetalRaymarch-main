//
//  AppModel.swift
//  MetalProject
//
//  Created by MU on 18/11/24.
//

import SwiftUI
import ARKit
import CoreGraphics

struct FormulaEditorSeed {
    let formula: EmbeddedFormula
    let activatesImmediately: Bool
}

/// High-frequency render metrics isolated from AppModel to avoid
/// broad observation invalidation on every FPS update.
@MainActor
@Observable
final class RenderMetrics {
    var fps: Double = 0

    /// Rolling presentation-gap percentiles from CAMetalDrawable callbacks.
    /// These include CPU stalls, GPU overruns, and drawable starvation that a
    /// render-callback FPS average would hide.
    var frameGapP95Ms: Double = 0
    var frameGapP99Ms: Double = 0
    var maximumFrameGapMs: Double = 0
    var hitchCount: Int = 0

    /// Smoothed GPU time per frame in milliseconds (Mac fragment path). Unlike
    /// `fps`, which is quantized by vsync (60 → 30 → 20…), this is continuous, so
    /// it reveals whether an acceleration setting actually reduced GPU cost even
    /// when the frame rate is pinned to a refresh-rate step. 0 = not yet measured.
    var gpuFrameMs: Double = 0

    // In-headset render diagnostics, updated from the render loop only when a
    // value changes. Lets the user confirm the actual drawable resolution and
    // the runtime render quality the compositor granted (see
    // Renderer.publishRenderDiagnostics).
    var drawableWidth: Int = 0
    var drawableHeight: Int = 0
    var renderQuality: Float = 0      // current target, driven by the resolution slider
    var foveationEnabled: Bool = false
    var renderPath: String = "—"
    /// Active Mac presentation path. Updated only when the renderer switches
    /// between native rendering and a MetalFX scaler.
    var upscalerPath: String = "—"

    /// Compute-path foveation rate-map decode dimensions (eye 0): physical texture
    /// size, rate-map screen size, and the per-eye viewport (size@origin), plus
    /// whether physical == drawable (the rateMapValid gate). Surfaced in-app so the
    /// decode that drives the compute ray reconstruction can be read on-device
    /// (console print() isn't visible untethered). "—" until a compute frame runs.
    var foveationDecode: String = "—"

    /// Measured average raymarch steps taken to converge, per converged (hit)
    /// pixel — the headline cost metric the Performance dashboard tunes against
    /// (config "Ray Steps" is only the *budget*; this is what actually happened).
    /// Read back from a GPU atomic counter at ~2 Hz while step profiling is on.
    /// 0 = not currently measuring (UI shows "—").
    var avgStepsPerPixel: Double = 0

    /// User toggle for live step profiling. Mirrored to
    /// `BenchmarkManager.shared.liveStepMeasurement`, which arms the in-kernel
    /// counter. Off by default because the per-ray atomics add GPU cost.
    var stepProfilingEnabled: Bool = false
}

/// High-frequency hand tracking UI state isolated from AppModel so that
/// ~15 Hz updates (gestureStatus, leftHandTracked, rightHandTracked) only
/// invalidate HandTrackingStatusView, not every AppModel observer.
@MainActor
@Observable
final class HandTrackingState {
    var gestureStatus: String = "Waiting for immersive space…"
    var leftHandTracked: Bool = false
    var rightHandTracked: Bool = false
}

enum ExternalFileImportPayload {
    case preset(FractalPreset)
    case animation(AnimationScene)
}

struct ExternalFileImportRequest: Identifiable {
    let id = UUID()
    let fileName: String
    let fileExtension: String
    let payload: ExternalFileImportPayload
}

enum SceneNavigationDirection: Equatable {
    case previous
    case next
}

struct SceneNavigationFeedback: Identifiable, Equatable {
    let id: UUID
    let direction: SceneNavigationDirection
    let sceneName: String
}

struct ManualSceneNavigationRequest: Equatable {
    let id: UUID
    let direction: SceneNavigationDirection
}

struct ManualStaticSceneNavigationCursor: Equatable {
    let requestID: UUID
    let sceneID: UUID
}

@MainActor
@Observable
class AppModel {
    /// The sole support matrix consumed by shared navigation, controls, and
    /// input models. Native adapters are responsible for constructing it.
    nonisolated let platformProfile: PlatformProfile
    let navigationStore: NavigationStore
    let controlStateStore = ControlStateStore()
    let controlProjectionCache = ControlCatalogProjectionCache()
    let inputOwnershipStore = InputOwnershipStore()
    @ObservationIgnored lazy var controlAccessService = ControlAccessService(store: controlStateStore)
    let immersiveSpaceID = "ImmersiveSpace"
    let menuWindowID = "MenuWindow"
    static let onboardingWindowID = "OnboardingWindow"
    static let fractalBrowserWindowID = "FractalBrowserWindow"
    static let animationEditorWindowID = "AnimationEditorWindow"
    static let controlsWindowID = "ControlsWindow"
    static let formulaEditorWindowID = "FormulaEditorWindow"

    /// User-authored `.threshfx` files in the store's Formulas/ folder.
    @ObservationIgnored lazy var formulaLibrary = FormulaLibraryStore()
    /// Formula handed to the editor window on open (nil = start a new one).
    /// One-shot payload consumed by Metal DE Studio when its window appears.
    /// Built-in formulas are opened for inspection first; an edit or explicit
    /// compile turns the draft into a custom formula without changing the
    /// rendered fractal merely because the Studio window was opened.
    var formulaEditorSeed: FormulaEditorSeed?
    static let fractalSettingsDidChangeNotification = Notification.Name("AppModel.fractalSettingsDidChange")

    /// Posted by AppModel when an external-file import needs the immersive
    /// space to be opened (e.g. a `.threshfx` was imported while the user
    /// was on the menu, and the renderer needs to come up to compile the
    /// custom MTLLibrary). The view that owns
    /// `@Environment(\.openImmersiveSpace)` observes this and calls it.
    /// The user-info dict carries an optional `presetID` (UUID string) so
    /// a view that's about to navigate elsewhere can dedupe.
    static let requestOpenImmersiveSpaceNotification = Notification.Name("AppModel.requestOpenImmersiveSpace")

    /// Profiling/automation hook. When the process is launched with the
    /// `-ThresholdAutoOpenImmersive` argument — set ONLY in the Profile
    /// scheme's "Generate Optimization Profile" run — the
    /// `ImmersiveSpaceAutoOpener` brings the full immersive space up once on
    /// launch, so a PGO run exercises the GPU render path without a human
    /// tapping "Show Immersive Space" while wearing the headset. A normal Run
    /// never passes the flag, so the default windowed launch is unchanged.
    /// (The device still has to be worn for tracking — this only removes the
    /// manual tap once it's running.)
    static let autoOpenImmersiveOnLaunch: Bool =
        ProcessInfo.processInfo.arguments.contains("-ThresholdAutoOpenImmersive")

    static nonisolated(unsafe) var shared: AppModel?

    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }

    enum RuntimeViewMode: String, Codable {
        case raymarch
        case buddhabrot
    }

    private static let runtimeViewModeDefaultsKey = "AppModel.runtimeViewMode"
    private nonisolated static let immersionStyleDefaultsKey = "immersionStylePreference"

    var immersiveSpaceState = ImmersiveSpaceState.closed
    /// True while the controls are broken out into their own macOS window (via the
    /// "Detach" / "Merge" toggle). The main window's
    /// slide-over sidebar suppresses itself while this is set so the controls
    /// don't appear twice.
    var isControlsWindowOpen = false
    #if os(macOS)
    /// Transient presentation state for the macOS recording-view shortcut. This is
    /// deliberately separate from the persisted FPS preference so showing the
    /// interface again restores the user's previous HUD choice.
    var isViewportChromeHidden = false
    /// Desired controls-window state, updated synchronously before SwiftUI's
    /// asynchronous Window open/dismiss lifecycle begins.
    var isControlsWindowRequested = false
    private(set) var controlsWindowRequestGeneration: UInt = 0
    var shouldRestoreControlsWindowAfterRecording = false
    /// True while the main render window's root view is mounted. Recording mode
    /// is owned by that view (its H monitor, restore logic, and exit path all
    /// live there), so the detached controls window must not enter it — and
    /// must self-heal out of it — while no render viewport exists.
    var isRootRenderViewMounted = false
    #endif
    var rendererStartupWarmupComplete = false
    /// Identifies the viewport coordinator that currently owns the renderer
    /// handlers and `rendererStartupWarmupComplete`.
    ///
    /// A departing coordinator's teardown has to hop to the main actor, so it
    /// can land *after* a replacement view has already configured itself
    /// (SwiftUI rebuilds the Metal representable when the inspector, an editor,
    /// or a scene change re-parents it). Clearing unconditionally then stranded
    /// the new, live renderer with no handlers and the warm-up flag stuck
    /// false — the startup cover stays up over a viewport that renders and
    /// accepts nothing. Mirrors the visionOS `activeRenderLoopID` handshake in
    /// `AppModel+RendererActivation`.
    @ObservationIgnored var viewportCoordinatorID: ObjectIdentifier?
    /// True only while an Audio Reactivity mapping is being held in isolation.
    /// Presentation hosts use this transient flag to reveal the live renderer
    /// without changing the user's normal controls visibility.
    var isAudioReactivityIsolationPreviewActive = false
    var runtimeViewMode: RuntimeViewMode =
        RuntimeViewMode(rawValue: UserDefaults.standard.string(forKey: runtimeViewModeDefaultsKey) ?? "")
        ?? .raymarch {
        didSet {
            runtimeViewModeForRenderer = runtimeViewMode
            if !SettingsPersistence.benchmarkHermetic {
                UserDefaults.standard.set(runtimeViewMode.rawValue, forKey: Self.runtimeViewModeDefaultsKey)
            }
        }
    }
    @ObservationIgnored nonisolated(unsafe) var runtimeViewModeForRenderer: RuntimeViewMode = .raymarch

    /// Immersive-space presentation style.
    /// - `.immersive`: progressive style that starts fully immersed; the
    ///   Digital Crown continuously reduces it to the window-sized aperture.
    /// - `.window`: a persistent, crown-adjustable portal into the fractal.
    /// - `.mixed`: no portal — the fractal floats in the real room and the
    ///   background is fully transparent (passthrough).
    enum ImmersionStylePreference: String, CaseIterable {
        case immersive
        case window
        case mixed

        /// Decodes persisted values, mapping the legacy "full"/"progressive"
        /// styles onto `.immersive`.
        static func fromPersisted(_ raw: String?) -> ImmersionStylePreference {
            switch raw {
            case ImmersionStylePreference.window.rawValue: return .window
            case ImmersionStylePreference.mixed.rawValue: return .mixed
            default: return .immersive
            }
        }

        /// Scenes may opt into Mixed, but may not otherwise replace the user's
        /// selected presentation mode.
        static func resolvedForScene(
            userPreference: ImmersionStylePreference,
            isMixedScene: Bool
        ) -> ImmersionStylePreference {
            isMixedScene ? .mixed : userPreference
        }
    }

    /// Last mode chosen directly by the user. A Mixed-authored scene may
    /// temporarily override the effective style, but it must not replace this
    /// choice: the next ordinary scene returns to the user's mode.
    @ObservationIgnored private var userImmersionStylePreference: ImmersionStylePreference =
        .fromPersisted(UserDefaults.standard.string(forKey: immersionStyleDefaultsKey))

    var immersionStylePreference: ImmersionStylePreference =
        .fromPersisted(UserDefaults.standard.string(forKey: immersionStyleDefaultsKey)) {
        didSet {
            // A scene's explicit Mixed opt-in is a temporary presentation
            // override, not a new user default. Only a picker change updates the
            // sticky session/launch preference.
            if !immersionChangeIsSceneDriven {
                userImmersionStylePreference = immersionStylePreference
                if !SettingsPersistence.benchmarkHermetic {
                    UserDefaults.standard.set(
                        immersionStylePreference.rawValue,
                        forKey: Self.immersionStyleDefaultsKey
                    )
                }
            }
            immersionStyleForRenderer = immersionStylePreference
            // Containment follows immersion. Entering Mixed resets to the safe,
            // pre-gated default — Bounded (bounding shape on, Scrunch off) — so a
            // fractal doesn't dump unbounded into the room. Entering Immersive
            // means you're inside the fractal, so drop all containment (bounding
            // shape and Scrunch). This only flips
            // on a manual style change — the user can re-pick a containment mode
            // afterward, and scene loads set these authoritatively themselves so
            // they suppress the coupling via immersionChangeIsSceneDriven.
            if oldValue != immersionStylePreference && !immersionChangeIsSceneDriven {
                if immersionStylePreference != .immersive {
                    renderSettings.boundingSphereSkipEnabled = true
                    renderSettings.boundToSpaceEnabled = false
                    renderSettings.envScrunchEnabled = false
                } else {
                    renderSettings.boundingSphereSkipEnabled = false
                    renderSettings.boundToSpaceEnabled = false
                    renderSettings.envScrunchEnabled = false
                }
                // RenderSettings is intentionally lock-backed/non-observable.
                // Resync every ControlStateStore after this coupled write so the
                // next containment tap cannot push stale pre-immersion values
                // back into the renderer.
                NotificationCenter.default.post(
                    name: Self.fractalSettingsDidChangeNotification,
                    object: nil
                )
            }
        }
    }

    /// True while a scene load is applying its explicit Mixed override (or
    /// returning from one to the user's sticky preference), so didSet doesn't
    /// persist it or clobber the containment fields applied by the scene.
    @ObservationIgnored private var immersionChangeIsSceneDriven = false

    /// Applies the only presentation override a scene is allowed to carry.
    /// Ordinary scenes preserve/restore the user's last explicit picker choice;
    /// scenes marked Mixed temporarily request passthrough presentation.
    func applySceneImmersionPreference(isMixedScene: Bool) {
        let resolvedStyle = ImmersionStylePreference.resolvedForScene(
            userPreference: userImmersionStylePreference,
            isMixedScene: isMixedScene
        )
        guard immersionStylePreference != resolvedStyle else { return }

        immersionChangeIsSceneDriven = true
        defer { immersionChangeIsSceneDriven = false }
        immersionStylePreference = resolvedStyle
    }

    /// Mirror of `immersionStylePreference` readable from the render loop off
    /// the MainActor (same pattern as runtimeViewModeForRenderer).
    @ObservationIgnored nonisolated(unsafe) var immersionStyleForRenderer: ImmersionStylePreference =
        .fromPersisted(UserDefaults.standard.string(forKey: immersionStyleDefaultsKey))

    // App activity state (used to avoid submitting GPU work while backgrounded)
    // @ObservationIgnored + nonisolated(unsafe) allows cross-thread access without @Observable macro interference
    @ObservationIgnored nonisolated(unsafe) var isAppActive: Bool = true

    /// Isolated container for high-frequency render metrics.
    /// Reading renderMetrics.fps only invalidates views that subscribe to RenderMetrics,
    /// not all AppModel observers.
    let renderMetrics = RenderMetrics()

    /// Isolated container for high-frequency hand tracking UI state.
    /// Reading handTrackingState.gestureStatus only invalidates views that subscribe
    /// to HandTrackingState, not all AppModel observers.
    let handTrackingState = HandTrackingState()

    /// Whether the renderer is currently using a specialized (compiled) pipeline vs generic fallback
    @ObservationIgnored nonisolated(unsafe) var isUsingSpecializedPipeline: Bool = false
    
    nonisolated let renderSettings = RenderSettings()
    nonisolated let parameterPipeline = ParameterPipeline()

    // Buddhabrot volume renderer settings (shared between UI and render loop)
    nonisolated let buddhabrotSettings = BuddhabrotSettings()

    // Microphone FFT backend. `AudioHub` owns source selection and publishes
    // the coherent render-facing snapshot; this remains available during the
    // migration for the microphone capture adapter.
    let audioAnalyzer = AudioAnalyzer()

    // Apple Music integration for music visualizer
    let appleMusicManager = AppleMusicManager()
    
    // Unified music service (wraps Apple Music)
    let musicService: MusicService

    /// Central audio composition root. It owns a dedicated analyzer per PCM
    /// capture source, media-feature fallback policy, and the immutable
    /// snapshot read by every renderer.
    let audioHub: AudioHub
    
    // Hand tracking state
    var handTrackingEnabled: Bool = {
        let key = "handTrackingEnabled"
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }() {
        didSet {
            handTrackingEnabledForRenderer = handTrackingEnabled
            UserDefaults.standard.set(handTrackingEnabled, forKey: "handTrackingEnabled")
            if !handTrackingEnabled {
                leftHandTracked = false
                rightHandTracked = false
                syncGestureProcessor()
            }
        }
    }
    @ObservationIgnored nonisolated(unsafe) var handTrackingEnabledForRenderer = true
    /// Forwarding accessors for hand tracking UI state.
    /// Reads/writes route to the isolated `handTrackingState` container so that
    /// high-frequency updates don't invalidate all AppModel observers.
    var leftHandTracked: Bool {
        get { handTrackingState.leftHandTracked }
        set { handTrackingState.leftHandTracked = newValue }
    }
    var rightHandTracked: Bool {
        get { handTrackingState.rightHandTracked }
        set { handTrackingState.rightHandTracked = newValue }
    }
    var gestureStatus: String {
        get { handTrackingState.gestureStatus }
        set { handTrackingState.gestureStatus = newValue }
    }
    
    /// Whether the hand tracking ARKit provider is actively running.
    /// Only written by the render loop, never read by SwiftUI views — skip observation.
    @ObservationIgnored var handTrackingRunning: Bool = false

    
    // Gesture controller for mapping hand gestures to parameters
    nonisolated let gestureProcessor: GestureProcessor

    // Preset management
    let presetManager = PresetManager()
    /// Drives the on-device performance sweep that writes the per-build perf log.
    let perfSweepRunner = PerfSweepRunner()
    /// Receives OS-delivered MetricKit payloads without adding work to the
    /// render loop. The payloads stay bounded and local until a user chooses to
    /// share a performance report.
    let metricKitPerformanceReporter = MetricKitPerformanceReporter()

    // Error reporting for transient banners
    let errorReporter = ErrorReporter()

    var pendingExternalImport: ExternalFileImportRequest?
    /// Non-nil while an externally opened Threshold file is being read and
    /// decoded. External scenes can be large enough that synchronous parsing
    /// looks like an application hang, so ContentView presents a progress
    /// overlay while AppModel performs that work off the main actor.
    var externalImportLoadingFileName: String?
    @ObservationIgnored var externalImportDecodeTask: Task<Void, Never>?
    @ObservationIgnored var externalImportDecodeGeneration: UInt64 = 0
    @ObservationIgnored var externalPreviewRestorePreset: FractalPreset?
    @ObservationIgnored var externalPreviewRestoreScene: AnimationScene?
    @ObservationIgnored var externalPreviewRestoreEmbeddedFormula: EmbeddedFormula?
    @ObservationIgnored var externalPreviewCapturedScene = false
    @ObservationIgnored var externalPreviewCapturedEmbeddedFormula = false
    @ObservationIgnored var activeExternalPreviewID: UUID?

    // Animation/Scene playback manager
    var animationManager: AnimationManager?
    
    /// Feature gate for the planted spatial radial menu. Disabled for now —
    /// the direct-hand interaction still needs on-device tuning — so menu
    /// gestures route to the conventional controls window on every platform.
    /// The renderer skips installing the spatial presentation handlers when
    /// false, and every gesture entry point already falls back to the window
    /// path when those handlers are nil. Flip to re-enable.
    static let spatialRadialMenuEnabled = false

    // Menu window visibility acknowledged by the window scene lifecycle.
    // Gesture requests do not mutate this optimistically because openWindow and
    // dismissWindow provide no success result.
    var isMenuWindowVisible: Bool = true
    var isSpatialMenuVisible: Bool = false
    var isMenuInteractionActive: Bool = false
    #if os(macOS)
    /// True while the render viewport's acknowledgement shortcut is held.
    /// The renderer publishes only edge changes, so this remains UI-only state.
    var isAttributionShortcutHeld: Bool = false
    #endif
    /// Monotonic token shared by the MainActor presentation edge and Renderer.
    /// It makes rapid open/close/open requests last-writer-wins even though the
    /// renderer calls cross an actor boundary.
    @ObservationIgnored var spatialMenuPresentationGeneration: UInt64 = 0
    @ObservationIgnored private(set) var activeResetPreset: FractalPreset?

    @ObservationIgnored private let menuWindowRetoggleGuardInterval: CFTimeInterval = 0.45
    @ObservationIgnored private var lastMenuWindowOpenedAt: CFTimeInterval = 0

    @ObservationIgnored private var isMenuHovering: Bool = false
    @ObservationIgnored private var menuAdjustmentDepth: Int = 0
    
    // Screenshot capture (set by Renderer)
    var captureScreenshotHandler: (() async -> Data?)?

    @ObservationIgnored var activeRenderLoopTask: Task<Void, Never>?
    @ObservationIgnored var activeRenderLoopID: UUID?
    @ObservationIgnored nonisolated(unsafe) private var storageWatcherObservers: [NSObjectProtocol] = []

    // Render-loop lifecycle (begin/registration, active-task set/cancel,
    // renderer-handler clearing) lives in AppModel+RendererActivation.swift.

    // Pipeline preparation handler (set by Renderer)
    // Called when a preset is about to be loaded to ensure the pipeline is ready
    var preparePipelineHandler: ((FractalPreset) async -> Void)?
    
    // Pipeline preparation for specific iteration/ray step values (set by Renderer)
    // Called when sliders change to pre-compile the needed pipeline
    var preparePipelineForValuesHandler: ((Int, Int) async -> Void)?

    // Embedded-formula activation handler (set by Renderer).
    // When non-nil, AppModel can ask the renderer to compile + install a custom
    // MTLLibrary for a `.threshfx` formula. Pass `nil` to detach.
    var activateEmbeddedFormulaHandler: ((EmbeddedFormula?) async throws -> Void)? {
        didSet {
            guard let handler = activateEmbeddedFormulaHandler else { return }
            let formula = activeEmbeddedFormula
            let rendererFormula = formula?.isBundledConstructionPrimitive == true ? nil : formula
            let queuedPreset = pendingPresetForActivation
            Task { @MainActor in
                do {
                    try await handler(rendererFormula)
                    // If a preset was queued behind a deferred activation,
                    // apply it now. This is the late-binding path that
                    // handles imports that happened *before* the user
                    // entered the immersive space: the queued Task in
                    // `queuePresetApplyAfterFormulaActivation` may have
                    // already timed out, but the renderer's startup
                    // triggered this didSet, so the formula is now compiled
                    // and we can apply the preset.
                    if let queued = queuedPreset,
                       queued.embeddedFormula?.shortHash == formula?.shortHash {
                        let navigationRequest = pendingPresetSceneNavigationRequest
                        pendingPresetForActivation = nil
                        pendingPresetSceneNavigationRequest = nil
                        await applyLoadedScene(
                            queued,
                            options: [],
                            manualSceneNavigationRequest: navigationRequest
                        )
                    }
                    // Same late-binding drain for a queued animation scene.
                    if let queuedScene = pendingSceneApplyAfterActivation,
                       queuedScene.formulaHash == formula?.shortHash {
                        pendingSceneApplyAfterActivation = nil
                        queuedScene.apply()
                    }
                } catch {
                    self.errorReporter.report(.preset(.importFailed(
                        "Failed to compile custom shader: \(error.localizedDescription)"
                    )))
                    self.uninstallEmbeddedFormula()
                    self.pendingPresetForActivation = nil
                    self.pendingPresetSceneNavigationRequest = nil
                }
            }
        }
    }

    /// Full payload for the formula currently installed in the renderer.
    /// Stored so preview cancellation and save/export paths can restore the
    /// previous custom formula rather than only its hash.
    @ObservationIgnored var activeEmbeddedFormula: EmbeddedFormula?

    /// The formula currently installed in the renderer (if any). Used to avoid
    /// redundant recompilation when the same formula is referenced multiple times
    /// across previews/imports.
    @ObservationIgnored var activeEmbeddedFormulaHash: String?

    /// Preset that was queued behind a deferred formula activation (e.g. a
    /// `.threshfx` imported before the user entered the immersive space).
    /// Set by `loadStaticScene` when the install is `.deferred`, and
    /// consumed by the `activateEmbeddedFormulaHandler.didSet` once the
    /// renderer has compiled the formula. Cleared on success, on failure,
    /// and on every successful direct (non-deferred) load.
    @ObservationIgnored var pendingPresetForActivation: FractalPreset?
    @ObservationIgnored var pendingPresetSceneNavigationRequest: ManualSceneNavigationRequest?

    /// Animation-scene counterpart of `pendingPresetForActivation`: an external
    /// `.threshanim`/`.threshanimv` whose embedded formula couldn't activate in
    /// time (renderer not up). The apply closure runs from the activation
    /// handler's didSet once the formula is compiled, so the scene loads when
    /// the user eventually enters the immersive space instead of being
    /// silently dropped after the activation wait times out.
    @ObservationIgnored var pendingSceneApplyAfterActivation: (formulaHash: String, apply: @MainActor () -> Void)?

    /// Prevents an older asynchronous scene load from applying after a newer
    /// selection, which is especially easy to trigger in the iPad scene list.
    @ObservationIgnored var staticSceneLoadTask: Task<Void, Never>?
    @ObservationIgnored var staticSceneLoadGeneration: UInt64 = 0

    /// Latest successfully applied manual scene step, observed by the desktop
    /// scene-information overlay.
    var sceneNavigationFeedback: SceneNavigationFeedback?
    @ObservationIgnored var activeManualSceneNavigationRequest: ManualSceneNavigationRequest?
    @ObservationIgnored var manualStaticSceneNavigationCursor: ManualStaticSceneNavigationCursor?

    /// Queue an animation-scene apply behind formula activation and nudge the
    /// immersive space open (same UX as the queued-preset path).
    func queueSceneApplyAfterFormulaActivation(formulaHash: String, apply: @escaping @MainActor () -> Void) {
        // If the activation handler is already bound, the handler's didSet has
        // already fired and will NOT fire again — a closure stored now would
        // never drain. This happens on the narrow path where the renderer came
        // up (handler bound) but the formula activation threw during the wait.
        // Apply immediately instead of queuing into a slot nothing will read.
        if activateEmbeddedFormulaHandler != nil {
            apply()
            return
        }
        pendingSceneApplyAfterActivation = (formulaHash, apply)
        if immersiveSpaceState != .open {
            NotificationCenter.default.post(
                name: AppModel.requestOpenImmersiveSpaceNotification,
                object: nil
            )
        }
    }
    
    /// Prepare the shader pipeline for specific iteration and ray step values
    /// Call this when slider values change to avoid compilation hitches
    func preparePipeline(iterations: Int, raySteps: Int) {
        Task {
            await preparePipelineForValuesHandler?(iterations, raySteps)
        }
    }
    
    // Pipeline profiler trigger (set by Renderer)
    var triggerProfilerHandler: (() -> Void)?

    // Force shader/pipeline recompile (set by the live renderer — the visionOS
    // `Renderer` actor or the macOS/iOS `ViewportRenderer`). Clears the
    // specialized pipeline caches and recompiles the active custom `.threshfx`
    // library from source. Returns a short status summary for the UI.
    var forceShaderRecompileHandler: (() async -> String)?

    /// Force a full shader/pipeline recompile (debug). Drops cached pipeline
    /// states so they rebuild fresh, and recompiles any active custom formula
    /// from source. Returns a human-readable summary of what happened.
    func forceShaderRecompile() async -> String {
        await forceShaderRecompileHandler?() ?? "No renderer is active."
    }
    
    /// Run the pipeline profiler to analyze rendering costs
    func runProfiler() {
        triggerProfilerHandler?()
    }
    
    // SharePlay session for collaborative fractal exploration
    var shareSession: FractalShareSession?

    var parameterOperationDebugTrace: Bool = false {
        didSet {
            parameterPipeline.setDebugTraceEnabled(parameterOperationDebugTrace)
            Task { await gestureProcessor.setDebugTraceEnabled(parameterOperationDebugTrace) }
        }
    }
    
    init(platformProfile: PlatformProfile = .current) {
        self.platformProfile = platformProfile
        self.navigationStore = NavigationStore(profile: platformProfile)
        self.gestureProcessor = GestureProcessor(
            renderSettings: renderSettings,
            parameterPipeline: parameterPipeline
        )
        ParameterRoutingValidation.validateStartupRouting()

        // Initialize media control and the independent signal hub before any
        // renderer can observe `self`.
        musicService = MusicService(appleMusic: appleMusicManager)
        audioHub = AudioHub(microphoneAnalyzer: audioAnalyzer,
                            appleMusicManager: appleMusicManager)
        handTrackingEnabledForRenderer = handTrackingEnabled

        // Publish the shared reference only after all stored properties are
        // initialized — `self` cannot escape an initializer before then.
        synchronizeTransformationInteractionAccessFromDefaults()
        AppModel.shared = self
        runtimeViewModeForRenderer = runtimeViewMode

        // Serial off-main gesture processor. ARKit anchors never cross into it;
        // the Renderer supplies one Sendable pose snapshot per accepted frame.
        parameterPipeline.setDebugTraceEnabled(parameterOperationDebugTrace)
        Task { await gestureProcessor.setDebugTraceEnabled(parameterOperationDebugTrace) }
        
        // Initialize animation manager
        animationManager = AnimationManager(renderSettings: renderSettings)

        // The cue group can include both animations and saved static scenes.
        // Keep static-scene loading routed through AppModel so custom formulas,
        // gesture overrides, and the established scene-transition path remain
        // identical whether the switch comes from a cue or the scene browser.
        animationManager?.musicCueStaticSceneProvider = { [weak self] in
            self?.presetManager.sceneCatalogPresets ?? []
        }
        animationManager?.musicCueStaticSceneLoadHandler = { [weak self] preset in
            self?.loadStaticScene(
                preset,
                manualSceneNavigationRequest: self?.activeManualSceneNavigationRequest
            )
        }
        animationManager?.musicCueCurrentStaticSceneIDProvider = { [weak self] in
            self?.activeResetPreset?.id
        }

        // AudioHub publishes one coherent snapshot after each capture tick.
        // Feed it to the transition controller on the main actor so cue-driven
        // switches continue to work even when no other music-reactive visual
        // effect is enabled.
        audioHub.onFeatureSnapshotUpdated = { [weak self] snapshot in
            self?.animationManager?.consumeMusicCue(snapshot)
        }
        
        // Wire up animation manager's pipeline preparation callback
        animationManager?.preparePipelineHandler = { [weak self] iterations, raySteps in
            self?.preparePipeline(iterations: iterations, raySteps: raySteps)
        }
        
        // Wire up song playback for scene-attached songs via unified music service
        animationManager?.playSongHandler = { [weak self] song in
            self?.musicService.play(attachment: song)
        }
        animationManager?.stopSongHandler = { [weak self] in
            guard let self, self.musicService.isPlaying else { return }
            self.musicService.togglePlayPause()
        }

        // Stop looping music scenes when the attached track naturally ends,
        // and clear residual audio-reactive layers/state.
        appleMusicManager.onPlaybackFinished = { [weak self] in
            guard let self else { return }
            let didStopMusicScene = self.animationManager?.stopIfAttachedSongFinished() ?? false
            guard didStopMusicScene else { return }

            self.parameterPipeline.clearMusicLayers(settings: self.renderSettings)
            self.renderSettings.audioLevel = 0
            self.renderSettings.bassLevel = 0
            self.renderSettings.midLevel = 0
            self.renderSettings.trebleLevel = 0
            self.renderSettings.beatIntensity = 0
        }

        appleMusicManager.onPlaybackProgress = { [weak self] currentTime, duration, isPlaying in
            self?.animationManager?.updateAttachedSongFade(
                currentTime: currentTime,
                duration: duration,
                isSongPlaying: isPlaying
            )
        }
        
        // Initialize SharePlay session
        shareSession = FractalShareSession(renderSettings: renderSettings)
        
        refreshMenuInteractionState()
        
        // Add built-in presets if this is first launch
        presetManager.addBuiltInPresetsIfNeeded()
        
        // Device/user preferences are the base layer. Restore them BEFORE the
        // last scene so scene-owned values can be applied authoritatively without
        // a later domain restore stomping them. Scene/session apply suppresses
        // persistence, so startup cannot write a half-applied hybrid back into
        // these blobs.
        SettingsPersistence.restoreAll(into: renderSettings)
        if let buddhabrot = SettingsPersistence.load(BuddhabrotConfig.self, domain: .buddhabrot) {
            buddhabrotSettings.config = buddhabrot
        }

        // Restore last scene/session state if available. If it carries an
        // embedded formula, install it so custom scenes survive app relaunch.
        if let restoredPreset = presetManager.restoreLastState(to: renderSettings),
           let formula = restoredPreset.embeddedFormula {
            if formula.effectKind == .spaceWarp {
                installSpaceWarp(formula)
            } else {
                installEmbeddedFormulaIfNeeded(formula)
            }
        }
        
        migrateDistinctWindowGestureDefaultsIfNeeded()
        migrateMenuGestureOwnershipIfNeeded()
        
        // Configure SharePlay session listener
        shareSession?.configureGroupSessions()

        // Live-watch the active store folder so external adds/deletes in iCloud
        // Drive reflect without a relaunch. Re-evaluated when the store root
        // resolves (async iCloud discovery) or the user switches storage mode.
        refreshStorageWatcher()
        for name in [StorageLocation.rootResolvedNotification, StorageLocation.modeChangedNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshStorageWatcher() }
            }
            storageWatcherObservers.append(observer)
        }
        let transformationDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.synchronizeTransformationInteractionAccessFromDefaults()
            }
        }
        storageWatcherObservers.append(transformationDefaultsObserver)
    }

    /// Starts microphone capture once at application launch when the user has
    /// explicitly enabled that device-local preference.
    func startMicrophoneAtLaunchIfEnabled() async {
        await audioHub.startMicrophoneAtLaunchIfEnabled()
    }

    /// The learning mode is a user preference, not scene data, but render-side
    /// modulation still needs the same access boundary as SwiftUI. Seed the shared
    /// lock-backed settings before either renderer starts; the Transformations view
    /// keeps it synchronized when the user changes mode or maps an equation.
    private func synchronizeTransformationInteractionAccessFromDefaults() {
        if SettingsPersistence.benchmarkHermetic {
            renderSettings.setSpaceWarpInteractionAccess(
                allowsUnmapped: true,
                mappedKindIDs: []
            )
            return
        }
        let defaults = UserDefaults.standard
        let mode = TransformationExperienceMode.decode(
            defaults.string(forKey: TransformationExperienceMode.defaultsKey) ?? ""
        )
        let mappedLessonIDs = TransformationUnlockProgress.decode(
            defaults.string(forKey: TransformationUnlockProgress.defaultsKey) ?? "",
            legacyEncoded: defaults.string(
                forKey: TransformationUnlockProgress.legacyDefaultsKey
            ) ?? ""
        )
        let mappedIDs = TransformationUnlockProgress.runtimeKindIDs(
            from: mappedLessonIDs
        )
        renderSettings.setSpaceWarpInteractionAccess(
            allowsUnmapped: mode == .justUse,
            mappedKindIDs: mappedIDs
        )
    }
    
    /// Save current state for restore on next launch
    func saveLastState() {
        presetManager.saveLastState(from: renderSettings, embeddedFormula: activeEmbeddedFormula)
        // Scene/session state is already checkpointed above. Flush only
        // user-originated debounced writes; a blanket save of the live renderer
        // would undo the scene mutation boundary and overwrite device defaults.
        SettingsPersistence.flushPendingSaves()
        SettingsPersistence.save(buddhabrotSettings.config, domain: .buddhabrot)
    }

    // MARK: - Storage Location

    /// Switch the active storage location (On This Device ⇄ iCloud Drive), merging
    /// both stores newest-wins so nothing is lost either way. A safety backup of the
    /// current data is taken first. For iCloud the container resolves asynchronously,
    /// so the merge runs once the new root is ready.
    func switchStorageMode(to newMode: StorageMode) {
        guard newMode != StorageLocation.shared.mode else { return }

        // Snapshot the CURRENT store's data + take a safety backup before re-pointing.
        let oldPresets = presetManager.presets
        let oldScenes = animationManager?.userScenes ?? []
        presetManager.backupCurrentPresetsNow()
        animationManager?.backupCurrentScenesNow()

        StorageLocation.shared.setMode(newMode)

        // Explicitly reload the managers from the NEW store, then union the old
        // store's items in (newest-wins). Done here rather than relying on the
        // managers' own reload observers so ordering can't race the merge.
        let doMerge: @MainActor () async -> Void = { [weak self] in
            guard let self else { return }
            await self.presetManager.loadPresetsNow()
            await self.animationManager?.reloadUserScenesFromStoreNow()

            let mergedPresets = BackupMerge.newestWins(
                local: oldPresets, cloud: self.presetManager.presets, timestamp: { $0.updatedAt })
            self.presetManager.replaceAll(with: mergedPresets)

            let mergedScenes = BackupMerge.newestWins(
                local: oldScenes, cloud: self.animationManager?.userScenes ?? [], timestamp: { $0.modifiedAt })
            self.animationManager?.replaceUserScenes(with: mergedScenes)

            print("🔀 Storage → \(StorageLocation.shared.mode.displayName): merged \(mergedPresets.count) presets, \(mergedScenes.count) user scenes")
        }

        if StorageLocation.shared.activeRoot != nil {
            Task { @MainActor in await doMerge() }
        } else {
            // iCloud not resolved yet — merge once its root becomes available (one-shot).
            final class OneShotObserverBox: @unchecked Sendable {
                var token: NSObjectProtocol?
            }
            let observerBox = OneShotObserverBox()
            observerBox.token = NotificationCenter.default.addObserver(
                forName: StorageLocation.rootResolvedNotification, object: nil, queue: .main
            ) { [observerBox] _ in
                if let token = observerBox.token {
                    NotificationCenter.default.removeObserver(token)
                    observerBox.token = nil
                }
                Task { @MainActor in await doMerge() }
            }
        }
    }

    /// Start/stop live folder watching for the active store. iCloud mode watches
    /// the store subfolders via NSMetadataQuery so external adds/deletes reflect
    /// live; local mode relies on `reloadStoresFromDisk()` at foreground (an
    /// NSMetadataQuery only covers ubiquitous files).
    func refreshStorageWatcher() {
        guard StorageLocation.shared.mode == .iCloud, let root = StorageLocation.shared.activeRoot else {
            animationManager?.stopWatchingiCloudAnimations()
            presetManager.stopWatchingiCloudPresets()
            return
        }
        animationManager?.startWatchingiCloudAnimations(animDir: StorageLocation.animationsDir(root))
        presetManager.startWatchingiCloudPresets(scenesDir: StorageLocation.scenesDir(root),
                                                 musicDir: StorageLocation.musicPresetsDir(root))
    }

    /// Re-mirror both stores from disk (used on app foreground so a file deleted or
    /// added in the store folder while the app was backgrounded reflects on return).
    func reloadStoresFromDisk() {
        presetManager.loadPresets()
        animationManager?.reloadUserScenesFromStore()
    }

    // External-file import (open / preview / commit / cancel / restore) lives in
    // AppModel+ExternalImport.swift.

    /// Callback to open the menu window (set by App scene)
    var openMenuWindowHandler: (() -> Void)?
    
    /// Callback to dismiss the menu window (set by App scene)
    var dismissMenuWindowHandler: (() -> Void)?

    /// visionOS volumetric radial controls. Kept as closure seams so AppModel
    /// remains independent of SwiftUI's window environment and other platforms
    /// keep their existing menu behavior.
    var presentSpatialMenuHandler: ((String?) -> Void)?
    var dismissSpatialMenuHandler: (() -> Void)?

    /// Callback to navigate directly to the active parameter controls.
    var openShapeMenuHandler: (() -> Void)?

    /// Returns true when the active parameter controls or Shape workspace are
    /// already active.
    var isShapeMenuActiveHandler: (() -> Bool)?

    /// Callback to navigate directly to the Fractal > Render tab.
    var openRenderMenuHandler: (() -> Void)?

    /// Returns true when the Fractal > Render tab is already active.
    var isRenderMenuActiveHandler: (() -> Bool)?

    /// Callback to navigate directly to the Quick Toggles tab.
    var openQuickTogglesHandler: (() -> Void)?

    /// Returns true when the Quick Toggles tab is already active.
    var isQuickTogglesActiveHandler: (() -> Bool)?

    /// Callback to present the save preset sheet from the active content view.
    var openSavePresetMenuHandler: (() -> Void)?

    /// Native presentation edge for the typed animation-editor command.
    var openAnimationEditorHandler: (() -> Void)?

    /// iPadOS counterpart: the renderer root owns the full-screen cover, so
    /// controls inside the inspector dismiss it through this seam.
    var dismissAnimationEditorHandler: (() -> Void)?

    /// Native presentation edge for Metal DE Studio. On iPad this is owned by
    /// the renderer root so the underlying controls can be removed first.
    var openFormulaEditorHandler: (() -> Void)?

    /// Installed by the active viewport adapter. Semantic UI surfaces dispatch
    /// renderer commands without retaining a platform view or input controller.
    var viewportCommandHandler: ((AppCommand) -> Void)?

    /// Callback to present the global control finder. The macOS root installs
    /// this so Command-K works even while the slide-over control panel is hidden.
    var openControlFinderHandler: (() -> Void)?

    #if os(macOS)
    func toggleViewportChromeVisibility() {
        if !isViewportChromeHidden {
            shouldRestoreControlsWindowAfterRecording = isControlsWindowRequested || isControlsWindowOpen
        }
        isViewportChromeHidden.toggle()
    }

    /// Records intent before `openWindow` returns asynchronously. Repeated open
    /// requests share one generation so a later ordinary close is still
    /// recognized as belonging to the visible window.
    func requestControlsWindowPresentation() {
        guard !isControlsWindowRequested else { return }
        controlsWindowRequestGeneration &+= 1
        isControlsWindowRequested = true
    }

    /// Invalidates the visible window generation before requesting dismissal.
    /// This keeps a late `onDisappear` from cancelling a newer reopen request.
    func requestControlsWindowDismissal() {
        guard isControlsWindowRequested || isControlsWindowOpen else { return }
        controlsWindowRequestGeneration &+= 1
        isControlsWindowRequested = false
        isControlsWindowOpen = false
    }

    /// Returns the generation represented by this concrete Window instance.
    func controlsWindowDidAppear() -> UInt {
        if !isControlsWindowRequested {
            controlsWindowRequestGeneration &+= 1
            isControlsWindowRequested = true
        }
        isControlsWindowOpen = true
        return controlsWindowRequestGeneration
    }

    func controlsWindowDidDisappear(generation: UInt?) {
        guard generation == controlsWindowRequestGeneration else { return }
        isControlsWindowOpen = false
        guard !isViewportChromeHidden else { return }
        isControlsWindowRequested = false
    }
    #endif
    
    /// Toggle menu window visibility.
    /// Closing dismisses the actual window; opening reuses the system-restored placement.
    func toggleMenuWindow() {
        if immersiveSpaceState == .open, let presentSpatialMenuHandler {
            if isSpatialMenuVisible {
                setSpatialMenuVisible(false)
                dismissSpatialMenuHandler?()
            } else {
                presentSpatialMenuHandler(nil)
            }
            return
        }

        if isMenuWindowVisible {
            guard canCloseMenuWindowNow() else {
                refreshMenuInteractionState()
                return
            }
            closeMenuWindow(reason: "toggle")
        } else {
            showMenuWindow(reason: "toggle")
        }
    }

    func openShapeMenuFromGesture() {
        if immersiveSpaceState == .open, let presentSpatialMenuHandler {
            // Shape is its own workspace in the shared navigation hierarchy.
            // Routing this to Input made the gesture open the wrong branch only
            // while immersive mode was active.
            presentSpatialMenuHandler(NavigationHierarchy.rootID(for: .shape))
            return
        }
        toggleFractalMenuFromGesture(
            isRequestedTabAlreadyOpen: isShapeMenuActiveHandler?() ?? false,
            openRequestedTab: openShapeMenuHandler,
            label: "Shape"
        )
    }

    func openRenderMenuFromGesture() {
        if immersiveSpaceState == .open, let presentSpatialMenuHandler {
            presentSpatialMenuHandler(NavigationHierarchy.rootID(for: .quality))
            return
        }
        toggleFractalMenuFromGesture(
            isRequestedTabAlreadyOpen: isRenderMenuActiveHandler?() ?? false,
            openRequestedTab: openRenderMenuHandler,
            label: "Render"
        )
    }

    func openQuickTogglesFromGesture() {
        if immersiveSpaceState == .open, let presentSpatialMenuHandler {
            presentSpatialMenuHandler("utility.quickToggles")
            return
        }
        toggleFractalMenuFromGesture(
            isRequestedTabAlreadyOpen: isQuickTogglesActiveHandler?() ?? false,
            openRequestedTab: openQuickTogglesHandler,
            label: "Quick Toggles"
        )
    }

    /// Bumped whenever a scene is selected, to ask the Mac/iPad controls panels to
    /// auto-hide (Mac respects its pin; iPad always hides). Observed via `.onChange`.
    var menuAutoHideRequestID: Int = 0

    /// Dismiss the menu during scene load so the result is immediately visible
    /// (and, on visionOS, hand gestures are available). Cross-platform: bumps the
    /// auto-hide signal for the Mac/iPad panels, then closes the visionOS window.
    func dismissMenuWindowForSceneLoad() {
        menuAutoHideRequestID &+= 1
        if isSpatialMenuVisible {
            setSpatialMenuVisible(false)
            dismissSpatialMenuHandler?()
        }
        guard isMenuWindowVisible else { return }
        closeMenuWindow(reason: "scene load", bypassGuard: true)
    }

    /// Load a space-warp `.threshfx` into the single active custom slot WITHOUT
    /// changing the fractal type — the warp applies to whatever fractal is active.
    /// Nudge `spaceWarpStrength` up so the loaded warp is visible.
    @MainActor
    func installSpaceWarp(_ warp: EmbeddedFormula) {
        do { try warp.validate() } catch {
            errorReporter.report(.preset(.importFailed("Invalid space warp: \(error.localizedDescription)")))
            return
        }
        activeEmbeddedFormula = warp
        // Set the hash too, so `uninstallEmbeddedFormula()` (whose guard is
        // `activeEmbeddedFormulaHash != nil`) can detach the warp when a plain
        // scene is later loaded.
        activeEmbeddedFormulaHash = warp.shortHash
        if renderSettings.spaceWarpStrength <= 0 {
            renderSettings.spaceWarpStrength = 0.6
        }
        // Activate now if the renderer is up; otherwise the handler's didSet
        // re-activates `activeEmbeddedFormula` when it binds (cold-start opens).
        if let handler = activateEmbeddedFormulaHandler {
            Task { @MainActor in
                do { try await handler(warp) }
                catch {
                    self.errorReporter.report(.preset(.importFailed("Failed to compile space warp: \(error.localizedDescription)")))
                    // Clear stale state so a failed warp doesn't linger.
                    self.activeEmbeddedFormula = nil
                    self.activeEmbeddedFormulaHash = nil
                    self.renderSettings.spaceWarpStrength = 0
                }
            }
        }
    }

    /// Toggle scene playback without opening a separate player window.
    func toggleAnimationPlayback() {
        guard let manager = animationManager else { return }

        if manager.isPlaying {
            manager.stop()
            return
        }

        if manager.currentScene?.keyframes.count ?? 0 < 2 {
            manager.currentScene = manager.scenes.first { $0.keyframes.count >= 2 }
        }

        guard manager.currentScene != nil else { return }
        manager.play()
    }

    /// Ensure menu window content is visible — call when exiting immersive mode or on app launch.
    func ensureWindowContentVisible() {
        if !isMenuWindowVisible {
            showMenuWindow(reason: "ensure visible")
            return
        }
        refreshMenuInteractionState()
    }

    /// Window-scene lifecycle acknowledgement. An `openWindow` request has no
    /// success result, so visibility only becomes true when SwiftUI confirms
    /// that the scene's content actually appeared.
    func markMenuWindowPresented() {
        isMenuWindowVisible = true
        lastMenuWindowOpenedAt = CACurrentMediaTime()
        refreshMenuInteractionState()
    }

    /// Window-scene lifecycle acknowledgement for a completed dismissal.
    func markMenuWindowDismissed() {
        isMenuWindowVisible = false
        isMenuHovering = false
        menuAdjustmentDepth = 0
        refreshMenuInteractionState()
    }

    func setMenuHovering(_ hovering: Bool) {
        isMenuHovering = hovering
        lastHoverEventTime = CACurrentMediaTime()
        refreshMenuInteractionState()
    }

    func setSpatialMenuVisible(_ visible: Bool) {
        guard isSpatialMenuVisible != visible else { return }
        if visible {
            guard inputOwnershipStore.claim(.spatialControls) else { return }
        } else {
            inputOwnershipStore.release(.spatialControls)
        }
        isSpatialMenuVisible = visible
        refreshMenuInteractionState()
    }

    #if os(macOS)
    func setAttributionShortcutHeld(_ isHeld: Bool) {
        guard isAttributionShortcutHeld != isHeld else { return }
        isAttributionShortcutHeld = isHeld
    }
    #endif

    func beginSpatialMenuPresentationRequest() -> UInt64 {
        spatialMenuPresentationGeneration &+= 1
        return spatialMenuPresentationGeneration
    }

    func isCurrentSpatialMenuPresentationRequest(_ generation: UInt64) -> Bool {
        spatialMenuPresentationGeneration == generation
    }

    /// Resolves a terminal spatial-menu selection through the same canonical
    /// hierarchy and NavigationStore activation seam as the Mac radial menu.
    /// Renderer passes the target from its exact immutable hierarchy snapshot,
    /// so a runtime availability change cannot strand menu input ownership.
    @MainActor
    func activateSpatialNavigationTarget(_ target: AppNavigationTarget) {
        // Release hand-input ownership before any fallible route work.
        setSpatialMenuVisible(false)
        dismissSpatialMenuHandler?()

        switch navigationStore.activate(target) {
        case .openAnimationEditor:
            if animationManager?.currentScene == nil {
                animationManager?.currentScene = animationManager?.scenes.first
            }
            if let openAnimationEditorHandler {
                openAnimationEditorHandler()
            } else {
                // A missing native window seam must never strand the selection.
                revealMenuWindowForSpatialNavigation()
            }
        case .toggleAnimationPlayback:
            toggleAnimationPlayback()
        case .toggleRadialMenu, .dismissRadialMenu, .resetViewport,
             .selectRoute:
            revealMenuWindowForSpatialNavigation()
        case nil:
            // Route targets are reduced by NavigationStore and displayed in the
            // conventional controls window.
            revealMenuWindowForSpatialNavigation()
        }
    }

    /// Spatial leaves call this before routing to a dense destination. If the
    /// conventional menu was dismissed, reconstruct it; otherwise simply keep
    /// its interaction state current while the route is delivered.
    func revealMenuWindowForSpatialNavigation() {
        if !isMenuWindowVisible {
            showMenuWindow(reason: "spatial navigation")
        } else {
            refreshMenuInteractionState()
        }
    }
    
    /// Timestamp of the last `.onHover` event received.  Used to detect stuck hover state.
    @ObservationIgnored private var lastHoverEventTime: CFTimeInterval = 0
    
    /// Call periodically (e.g. from the render loop FPS update) to auto-clear hover if
    /// no hover event has been received for an extended period.
    /// This prevents `suppressParameterGestures` from getting permanently stuck when
    /// the `.onHover(false)` callback is dropped by the system.
    func clearStaleHoverIfNeeded() {
        guard isMenuHovering else { return }
        let now = CACurrentMediaTime()
        // If no hover event for 3 seconds, assume the user is no longer gazing at the window
        if lastHoverEventTime > 0, now - lastHoverEventTime > 3.0 {
            isMenuHovering = false
            refreshMenuInteractionState()
        }
    }

    func beginMenuAdjustment() {
        menuAdjustmentDepth += 1
        refreshMenuInteractionState()
    }

    func endMenuAdjustment() {
        menuAdjustmentDepth = max(0, menuAdjustmentDepth - 1)
        refreshMenuInteractionState()
    }

    private func refreshMenuInteractionState() {
        // `isMenuWindowVisible` tracks the dismissable visionOS ornament window and is
        // permanently latched to `false` by `dismissMenuWindowForSceneLoad()` the first
        // time any scene loads (Mac never calls `showMenuWindow()` to reset it — its
        // panel visibility is unconditional, per the comment on `closeMenuWindow`).
        // Gating on it here would silently and permanently disable this "hold the
        // panel open" signal on Mac after the first scene load, breaking every
        // control that relies on `beginMenuAdjustment()`/`endMenuAdjustment()`
        // (color pickers, popovers, sheets) for the rest of the session.
        #if os(macOS)
        let interacting = isSpatialMenuVisible || isMenuHovering || menuAdjustmentDepth > 0
        #else
        let interacting = isSpatialMenuVisible
            || (isMenuWindowVisible && (isMenuHovering || menuAdjustmentDepth > 0))
        #endif
        isMenuInteractionActive = interacting
        renderSettings.isMenuInteractionActive = interacting
        Task { await gestureProcessor.setParameterGesturesSuppressed(interacting) }
    }

    func syncGestureProcessor() {
        Task { await gestureProcessor.syncWithSettings() }
    }

    func applyFractalDefaults() {
        FractalDefaultsStore.applyFractalDefaults(for: renderSettings.fractalType, to: renderSettings)
        syncGestureProcessor()
    }

    @discardableResult
    func saveCurrentAsFractalDefaults() -> Bool {
        FractalDefaultsStore.saveCurrentAsFractalDefaults(from: renderSettings)
    }

    /// The sole MainActor application edge for off-main gesture output.
    func applyGestureOutput(_ output: GestureOutput, publishDiagnostics: Bool) {
        for command in output.commands {
            switch command {
            case .toggleRadialMenu:
                toggleMenuWindow()
            case .dismissRadialMenu:
                setSpatialMenuVisible(false)
                dismissSpatialMenuHandler?()
            case .toggleAnimationPlayback:
                toggleAnimationPlayback()
            case .selectRoute(let route):
                navigationStore.activate(.command(.selectRoute(route)))
                switch route {
                case .shape: openShapeMenuFromGesture()
                case .quality: openRenderMenuFromGesture()
                case .quickToggles: openQuickTogglesFromGesture()
                default: break
                }
            case .openAnimationEditor:
                openAnimationEditorHandler?()
            case .resetViewport:
                viewportCommandHandler?(.resetViewport)
            }
        }

        if output.didUseGesture {
            UsageAnalytics.shared.trackHandGestureUsed()
        }
        guard publishDiagnostics else { return }
        leftHandTracked = output.diagnostics.leftTracked
        rightHandTracked = output.diagnostics.rightTracked
        if output.diagnostics.parametersSuppressed {
            gestureStatus = "Suppressed (interacting with controls)"
        } else if !output.diagnostics.leftTracked && !output.diagnostics.rightTracked {
            gestureStatus = "No hands detected"
        } else if output.diagnostics.activeGestureIndex > 0 {
            let names = ["", "Index", "Middle", "Ring"]
            gestureStatus = "Active: \(names[min(output.diagnostics.activeGestureIndex, 3)])"
        } else {
            let hands = [output.diagnostics.leftTracked ? "L" : nil,
                         output.diagnostics.rightTracked ? "R" : nil]
                .compactMap { $0 }
                .joined(separator: "+")
            gestureStatus = "Ready (\(hands) tracked)"
        }
    }

    /// Switch to a built-in fractal through one canonical side-effect path.
    /// App Intents and the in-app picker both use this so formula layers,
    /// gesture defaults, reset state, and cached UI cannot drift apart.
    func switchFractalType(_ type: FractalModelType) {
        guard renderSettings.fractalType != type else { return }

        // A custom distance estimator is tied to `.custom`; detach it before
        // selecting a built-in type. Custom space warps intentionally survive
        // type changes because they apply to every fractal.
        if type != .custom, activeEmbeddedFormula?.effectKind == .fractal {
            uninstallEmbeddedFormula()
        }

        renderSettings.fractalType = type
        parameterPipeline.clearFormulaStacks()
        applyFractalDefaults()
        rememberActiveResetPresetFromCurrent()
        NotificationCenter.default.post(
            name: AppModel.fractalSettingsDidChangeNotification,
            object: nil
        )
    }

    func rememberActiveResetPreset(_ preset: FractalPreset) {
        var snapshot = FractalPreset.fromSettings(
            renderSettings,
            name: preset.name,
            id: preset.id,
            createdAt: preset.createdAt,
            embeddedFormula: activeEmbeddedFormula
        )
        snapshot.thumbnailData = nil
        activeResetPreset = snapshot
    }

    /// Capture the CURRENT settings as the reset target — used when the user
    /// manually switches fractal type (there is no source scene). A type switch
    /// applies that type's defaults, so snapshotting here makes Reset ease back
    /// to the freshly-selected type instead of the previously-loaded scene's
    /// type ("reset should also work for last fractal type selected").
    func rememberActiveResetPresetFromCurrent(name: String = "__typeDefault__") {
        var snapshot = FractalPreset.fromSettings(
            renderSettings,
            name: name,
            embeddedFormula: activeEmbeddedFormula
        )
        snapshot.thumbnailData = nil
        activeResetPreset = snapshot
    }

    /// Optional side-effects to run around a scene load. Defaults match the
    /// in-app / keyboard scene-switch path; external file imports opt in to
    /// persistence + sheet cleanup.
    struct StaticSceneLoadOptions: OptionSet {
        let rawValue: Int
        static let saveToLibrary = StaticSceneLoadOptions(rawValue: 1 << 0)
        static let persistLastState = StaticSceneLoadOptions(rawValue: 1 << 1)
        static let closeExternalSheet = StaticSceneLoadOptions(rawValue: 1 << 2)
    }

    // Static-scene / preset loading (loadStaticScene + the formula-activation
    // queue + applyLoadedScene + waitForRendererAndActivate + gesture overrides)
    // lives in AppModel+SceneLoading.swift.

    /// Handles the canvas left/right quick controls. A configured cue group
    /// takes priority so performers can step their chosen animation sequence
    /// instantly; without one, preserve the existing static-scene shortcut.
    @MainActor
    func cycleConfiguredSceneGroupOrStaticScene(forward: Bool) {
        let request = ManualSceneNavigationRequest(
            id: UUID(),
            direction: forward ? .next : .previous
        )

        if let animationManager,
           animationManager.canStepMusicCueSceneGroup {
            manualStaticSceneNavigationCursor = nil
            activeManualSceneNavigationRequest = request
            defer { activeManualSceneNavigationRequest = nil }

            guard let target = animationManager.stepMusicCueSceneGroup(by: forward ? 1 : -1) else {
                return
            }
            if target.kind == .animation {
                completeManualSceneNavigation(request, sceneName: target.name)
            }
            return
        }
        cycleJumpingOffScene(forward: forward, manualSceneNavigationRequest: request)
    }

    /// Loads the previous or next built-in static scene (Jumping Off or Music
    /// Reactive), wrapping around at the ends. Used by the canvas left/right
    /// shortcut when no playable cue group has been configured.
    @MainActor
    func cycleJumpingOffScene(
        forward: Bool,
        manualSceneNavigationRequest: ManualSceneNavigationRequest? = nil
    ) {
        let scenes = presetManager.sceneCatalogPresets
            .filter { $0.name != "__lastState__" && $0.isKeyboardSwitchableStaticPreset }
        guard !scenes.isEmpty else { return }

        let cursorIndex = manualStaticSceneNavigationCursor.flatMap { cursor in
            scenes.firstIndex(where: { $0.id == cursor.sceneID })
        }
        let appliedIndex = activeResetPreset.flatMap { active in
            scenes.firstIndex(where: { $0.id == active.id })
        }
        let currentIndex = cursorIndex ?? appliedIndex

        let nextIndex: Int
        if let currentIndex {
            let count = scenes.count
            nextIndex = ((currentIndex + (forward ? 1 : -1)) % count + count) % count
        } else {
            nextIndex = forward ? 0 : scenes.count - 1
        }

        let nextScene = scenes[nextIndex]
        if let manualSceneNavigationRequest {
            manualStaticSceneNavigationCursor = ManualStaticSceneNavigationCursor(
                requestID: manualSceneNavigationRequest.id,
                sceneID: nextScene.id
            )
        } else {
            manualStaticSceneNavigationCursor = nil
        }
        loadStaticScene(
            nextScene,
            manualSceneNavigationRequest: manualSceneNavigationRequest
        )
    }

    @MainActor
    func completeManualSceneNavigation(
        _ request: ManualSceneNavigationRequest,
        sceneName: String
    ) {
        if manualStaticSceneNavigationCursor?.requestID == request.id {
            manualStaticSceneNavigationCursor = nil
        }
        let trimmedName = sceneName.trimmingCharacters(in: .whitespacesAndNewlines)
        sceneNavigationFeedback = SceneNavigationFeedback(
            id: request.id,
            direction: request.direction,
            sceneName: trimmedName.isEmpty ? "Untitled Scene" : trimmedName
        )
    }


    private func canCloseMenuWindowNow() -> Bool {
        CACurrentMediaTime() - lastMenuWindowOpenedAt >= menuWindowRetoggleGuardInterval
    }

    private func showMenuWindow(reason: String) {
        // `openWindow` is a fire-and-forget request. Keep the lifecycle-backed
        // visibility false until the window scene's onAppear confirms presentation;
        // if the system declines or delays the request, the next gesture can
        // retry instead of taking the stale "close" branch.
        openMenuWindowHandler?()
        refreshMenuInteractionState()
    }

    private func closeMenuWindow(reason: String, bypassGuard: Bool = false) {
        guard isMenuWindowVisible else {
            refreshMenuInteractionState()
            return
        }
        guard bypassGuard || canCloseMenuWindowNow() else {
            refreshMenuInteractionState()
            return
        }

        isMenuHovering = false
        menuAdjustmentDepth = 0
        // Truly dismiss the window so it actually closes — no lingering, invisible
        // window scene (the old opacity-only hide left a "ghost" window in place).
        // On visionOS the system re-presents unlocked windows in front of the person on
        // reopen; there is no API to restore an exact prior floating position (see Apple's
        // "Adopting best practices for persistent UI"). On macOS this handler is nil, so
        // nothing is torn down there (menu content visibility is unconditional on Mac).
        //
        // Trade-off the prior opacity-hide avoided: dismiss tears down the heavy
        // ContentView and the reopen rebuilds it on the main thread, which can briefly
        // hitch the @MainActor hand-gesture task. If that reopen hitch is noticeable in
        // use, revert to the opacity-hide (drop this call).
        //
        // Visibility remains true until the window scene's onDisappear callback
        // confirms teardown. If dismissal is declined, the next gesture retries
        // the close request instead of assuming the window vanished.
        dismissMenuWindowHandler?()
        refreshMenuInteractionState()
    }

    private func toggleFractalMenuFromGesture(
        isRequestedTabAlreadyOpen: Bool,
        openRequestedTab: (() -> Void)?,
        label: String
    ) {
        guard let openRequestedTab else { return }

        if isMenuWindowVisible && isRequestedTabAlreadyOpen {
            closeMenuWindow(reason: "\(label) gesture")
            return
        }

        if !isMenuWindowVisible {
            showMenuWindow(reason: "\(label) gesture")
        }

        openRequestedTab()
        refreshMenuInteractionState()
    }

    /// Capture a screenshot for preset thumbnails
    func captureScreenshot() async -> Data? {
        return await captureScreenshotHandler?()
    }

    /// One-time migration to keep menu opening easy with either finger and
    /// normalize older menu sensitivity defaults to a faster/easier-open setup.
    private func migrateDistinctWindowGestureDefaultsIfNeeded() {
        let migrationKey = "gestureDistinctWindowMapping.v8"
        guard UserDefaults.standard.bool(forKey: migrationKey) == false else { return }

        // Ensure gesture toggle is enabled so menu recovery remains possible.
        renderSettings.menuToggleGestureEnabled = true

        // Keep menu recovery easy even for installs that persisted an older or
        // harder-to-perform mode before the current default existed.
        renderSettings.menuToggleGestureMode = .middleOrRingToPalm

        let priorLeftDefault: [PerFingerTapAction] = [.none, .none, .none, .openShapeMenu, .none]
        if renderSettings.perFingerTapLeftActions == [.none, .none, .none, .none, .none]
            || renderSettings.perFingerTapLeftActions == priorLeftDefault {
            renderSettings.perFingerTapLeftActions = GestureDefaults.perFingerTapLeftActions
            GestureDefaults.savePerFingerTapActions(renderSettings.perFingerTapLeftActions, keyPrefix: "perFingerTapLeft")
        }

        // Adopt the Open Quick Toggles gesture on the right ring finger for installs
        // that predate it, as long as that slot is still unassigned.
        var rightActions = renderSettings.perFingerTapRightActions
        if rightActions.count == 5, rightActions[3] == .none {
            rightActions[3] = .openQuickToggles
            renderSettings.perFingerTapRightActions = rightActions
            GestureDefaults.savePerFingerTapActions(rightActions, keyPrefix: "perFingerTapRight")
        }

        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    /// Keep menu open/close controlled by the explicit menu gesture picker.
    /// Earlier builds also mapped right-middle per-finger tap to Toggle Menu,
    /// which made changing "Open Menu With" look ineffective.
    private func migrateMenuGestureOwnershipIfNeeded() {
        let migrationKey = "gestureMenuToggleOwnership.v1"
        guard UserDefaults.standard.bool(forKey: migrationKey) == false else { return }

        let leftActions = renderSettings.perFingerTapLeftActions.removingMenuToggleActions
        if leftActions != renderSettings.perFingerTapLeftActions {
            renderSettings.perFingerTapLeftActions = leftActions
            GestureDefaults.savePerFingerTapActions(leftActions, keyPrefix: "perFingerTapLeft")
        }

        let rightActions = renderSettings.perFingerTapRightActions.removingMenuToggleActions
        if rightActions != renderSettings.perFingerTapRightActions {
            renderSettings.perFingerTapRightActions = rightActions
            GestureDefaults.savePerFingerTapActions(rightActions, keyPrefix: "perFingerTapRight")
        }

        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    deinit {
        externalImportDecodeTask?.cancel()
        storageWatcherObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

}
