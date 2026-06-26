//
//  AppModel.swift
//  MetalProject
//
//  Created by MU on 18/11/24.
//

import SwiftUI
import ARKit
import CoreGraphics

/// High-frequency render metrics isolated from AppModel to avoid
/// broad observation invalidation on every FPS update.
@MainActor
@Observable
final class RenderMetrics {
    var fps: Double = 0

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

@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    let menuWindowID = "MenuWindow"
    static let onboardingWindowID = "OnboardingWindow"
    static let fractalBrowserWindowID = "FractalBrowserWindow"
    static let animationEditorWindowID = "AnimationEditorWindow"
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

    enum RuntimeViewMode: String {
        case raymarch
        case buddhabrot
    }
    
    var immersiveSpaceState = ImmersiveSpaceState.closed
    var rendererStartupWarmupComplete = false
    var runtimeViewMode: RuntimeViewMode = .raymarch {
        didSet {
            runtimeViewModeForRenderer = runtimeViewMode
        }
    }

    @ObservationIgnored nonisolated(unsafe) var runtimeViewModeForRenderer: RuntimeViewMode = .raymarch

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
    
    // Audio analyzer for reactive lighting
    let audioAnalyzer = AudioAnalyzer()

    // Apple Music integration for music visualizer
    let appleMusicManager = AppleMusicManager()
    
    // Unified music service (wraps Apple Music)
    let musicService: MusicService

    #if os(macOS)
    /// Captures system audio output via Core Audio process taps (macOS 14.4+)
    /// and feeds it into `audioAnalyzer` for FFT-driven visuals.
    let systemAudioCapture: SystemAudioTapCapture
    #endif
    
    // Hand tracking state
    var handTrackingEnabled: Bool = {
        let key = "handTrackingEnabled"
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }() {
        didSet {
            UserDefaults.standard.set(handTrackingEnabled, forKey: "handTrackingEnabled")
            if !handTrackingEnabled {
                leftHandTracked = false
                rightHandTracked = false
                gestureController?.syncWithSettings()
            }
        }
    }
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
    var gestureController: GestureController?
    
    nonisolated let clock = AppClock()
    
    // Preset management
    let presetManager = PresetManager()

    // iCloud Drive backup/restore (presets, scenes, settings)
    let iCloudBackup = ICloudBackupManager()

    // Error reporting for transient banners
    let errorReporter = ErrorReporter()

    var pendingExternalImport: ExternalFileImportRequest?
    @ObservationIgnored private var externalPreviewRestorePreset: FractalPreset?
    @ObservationIgnored private var externalPreviewRestoreScene: AnimationScene?
    @ObservationIgnored private var externalPreviewRestoreEmbeddedFormula: EmbeddedFormula?
    @ObservationIgnored private var externalPreviewCapturedScene = false
    @ObservationIgnored private var externalPreviewCapturedEmbeddedFormula = false
    @ObservationIgnored private var activeExternalPreviewID: UUID?

    // Animation/Scene playback manager
    var animationManager: AnimationManager?
    
    // Menu window visibility (toggled by gesture).
    // The window is physically dismissed when closed; visionOS currently preserves
    // its placement when reopened, which keeps the user's chosen location intact.
    var isMenuWindowVisible: Bool = true
    var isMenuInteractionActive: Bool = false
    @ObservationIgnored private(set) var activeResetPreset: FractalPreset?

    @ObservationIgnored private let menuWindowRetoggleGuardInterval: CFTimeInterval = 0.45
    @ObservationIgnored private var lastMenuWindowOpenedAt: CFTimeInterval = 0

    /// Head height (metres, world-space Y) sampled from the device anchor.
    /// Updated at ~2 Hz by UIUpdateCoordinator. Zero means no world-tracking fix yet.
    var headHeightMeters: Float = 0

    @ObservationIgnored private var isMenuHovering: Bool = false
    @ObservationIgnored private var menuAdjustmentDepth: Int = 0
    
    // Screenshot capture (set by Renderer)
    var captureScreenshotHandler: (() async -> Data?)?

    @ObservationIgnored private var activeRenderLoopTask: Task<Void, Never>?
    @ObservationIgnored private var activeRenderLoopID: UUID?
    @ObservationIgnored nonisolated(unsafe) private var cloudFolderObserver: NSObjectProtocol?

    @discardableResult
    func beginRenderLoopRegistration() -> UUID {
        activeRenderLoopTask?.cancel()
        clearRendererHandlers()

        let id = UUID()
        activeRenderLoopID = id
        rendererStartupWarmupComplete = false
        return id
    }

    func setActiveRenderLoopTask(_ task: Task<Void, Never>, id: UUID) {
        guard activeRenderLoopID == id else {
            task.cancel()
            return
        }

        activeRenderLoopTask = task
    }

    func cancelActiveRenderLoop() {
        activeRenderLoopTask?.cancel()
        activeRenderLoopTask = nil
        activeRenderLoopID = nil
        clearRendererHandlers()
    }

    func clearRendererHandlers(renderLoopID: UUID) {
        guard activeRenderLoopID == renderLoopID else { return }

        activeRenderLoopTask = nil
        activeRenderLoopID = nil
        clearRendererHandlers()
    }

    private func clearRendererHandlers() {
        captureScreenshotHandler = nil
        preparePipelineHandler = nil
        preparePipelineForValuesHandler = nil
        triggerProfilerHandler = nil
        activateEmbeddedFormulaHandler = nil
        rendererStartupWarmupComplete = false
    }
    
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
            let queuedPreset = pendingPresetForActivation
            Task { @MainActor in
                do {
                    try await handler(formula)
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
                        pendingPresetForActivation = nil
                        await applyLoadedScene(queued, options: [])
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

    /// Animation-scene counterpart of `pendingPresetForActivation`: an external
    /// `.threshanim`/`.threshanimv` whose embedded formula couldn't activate in
    /// time (renderer not up). The apply closure runs from the activation
    /// handler's didSet once the formula is compiled, so the scene loads when
    /// the user eventually enters the immersive space instead of being
    /// silently dropped after the activation wait times out.
    @ObservationIgnored var pendingSceneApplyAfterActivation: (formulaHash: String, apply: @MainActor () -> Void)?

    /// Queue an animation-scene apply behind formula activation and nudge the
    /// immersive space open (same UX as the queued-preset path).
    func queueSceneApplyAfterFormulaActivation(formulaHash: String, apply: @escaping @MainActor () -> Void) {
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
    
    /// Run the pipeline profiler to analyze rendering costs
    func runProfiler() {
        triggerProfilerHandler?()
    }
    
    // SharePlay session for collaborative fractal exploration
    var shareSession: FractalShareSession?

    var parameterOperationDebugTrace: Bool = false {
        didSet {
            parameterPipeline.setDebugTraceEnabled(parameterOperationDebugTrace)
            gestureController?.setDebugTraceEnabled(parameterOperationDebugTrace)
        }
    }
    
    init() {
        ParameterRoutingValidation.validateStartupRouting()

        // Initialize unified music service first since it's a non-optional constant
        musicService = MusicService(appleMusic: appleMusicManager)

        #if os(macOS)
        systemAudioCapture = SystemAudioTapCapture(analyzer: audioAnalyzer)
        #endif

        // Publish the shared reference only after all stored properties are
        // initialized — `self` cannot escape an initializer before then.
        AppModel.shared = self

        // Initialize gesture controller with render settings
        gestureController = GestureController(renderSettings: renderSettings, parameterPipeline: parameterPipeline)
        parameterPipeline.setDebugTraceEnabled(parameterOperationDebugTrace)
        gestureController?.setDebugTraceEnabled(parameterOperationDebugTrace)
        
        // Initialize animation manager
        animationManager = AnimationManager(renderSettings: renderSettings)
        
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
        
        // Setup gesture callbacks
        gestureController?.onMenuToggle = { [weak self] in
            self?.toggleMenuWindow()
        }
        gestureController?.onAnimationPlayerToggle = { [weak self] in
            self?.toggleAnimationPlayback()
        }
        gestureController?.onOpenShapeMenu = { [weak self] in
            self?.openShapeMenuFromGesture()
        }
        gestureController?.onOpenRenderMenu = { [weak self] in
            self?.openRenderMenuFromGesture()
        }
        gestureController?.onMenuWindowPullTowardUser = { [weak self] in
            self?.pullMenuWindowTowardUser()
        }

        refreshMenuInteractionState()
        
        // Add built-in presets if this is first launch
        presetManager.addBuiltInPresetsIfNeeded()
        
        // Restore last state if available.
        // If the restored preset carries an embedded formula, install it so
        // custom scenes survive app relaunch.
        if let restoredPreset = presetManager.restoreLastState(to: renderSettings),
           let formula = restoredPreset.embeddedFormula {
            if formula.effectKind == .spaceWarp {
                installSpaceWarp(formula)
            } else {
                installEmbeddedFormulaIfNeeded(formula)
            }
        }
        
        // Restore domain config structs (new persistence format, overlays legacy per-key values)
        SettingsPersistence.restoreAll(into: renderSettings)
        migrateDistinctWindowGestureDefaultsIfNeeded()
        
        // Configure SharePlay session listener
        shareSession?.configureGroupSessions()

        // Start watching the iCloud Animations/ folder once the container resolves.
        // iCloudBackup.resolveContainer() runs async; we listen for the notification
        // it posts when the URL first becomes available, and also do a quick poll
        // in case resolution happened before we registered the observer.
        cloudFolderObserver = NotificationCenter.default.addObserver(
            forName: ICloudBackupManager.cloudFolderResolvedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let animDir = (notification.object as? URL)?
                .appendingPathComponent("Animations", isDirectory: true) else { return }

            Task { @MainActor [weak self, animDir] in
                self?.animationManager?.startWatchingiCloudAnimations(animDir: animDir)
            }
        }
        // Also try immediately in case the container was already resolved.
        if let animDir = iCloudBackup.cloudFolderURL?
            .appendingPathComponent("Animations", isDirectory: true) {
            animationManager?.startWatchingiCloudAnimations(animDir: animDir)
        }

    }
    
    /// Save current state for restore on next launch
    func saveLastState() {
        presetManager.saveLastState(from: renderSettings, embeddedFormula: activeEmbeddedFormula)
        SettingsPersistence.saveAll(from: renderSettings)
    }

    func openExternalFile(_ url: URL) {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        clearExternalPreview(restorePreviewedState: true)
        pendingExternalImport = nil

        switch url.pathExtension.lowercased() {
        case "threshscene", "threshmp":
            do {
                let preset = try presetManager.decodePreset(from: url)
                pendingExternalImport = ExternalFileImportRequest(
                    fileName: url.lastPathComponent,
                    fileExtension: url.pathExtension.lowercased(),
                    payload: .preset(preset)
                )
                ensureWindowContentVisible()
            } catch {
                errorReporter.report(.preset(.importFailed("Could not read \(url.lastPathComponent).")))
            }

        case "threshanim", "threshanimv":
            do {
                guard let scene = try animationManager?.decodeScene(from: url) else {
                    errorReporter.report(.animation(.importFailed("Animation manager is unavailable.")))
                    return
                }
                pendingExternalImport = ExternalFileImportRequest(
                    fileName: url.lastPathComponent,
                    fileExtension: url.pathExtension.lowercased(),
                    payload: .animation(scene)
                )
                ensureWindowContentVisible()
            } catch {
                errorReporter.report(.animation(.importFailed("Could not read \(url.lastPathComponent).")))
            }

        case "threshfx":
            do {
                let container = try EmbeddedFormulaContainer.decode(fromContainerAt: url)
                if container.formula.effectKind == .spaceWarp {
                    // A space-warp effect applies to the current fractal — install
                    // it directly rather than routing through the custom-fractal
                    // preset/preview path (which would force fractalType = .custom).
                    installSpaceWarp(container.formula)
                    ensureWindowContentVisible()
                    return
                }
                let preset = AppModel.makeCustomPreset(from: container.formula)
                pendingExternalImport = ExternalFileImportRequest(
                    fileName: url.lastPathComponent,
                    fileExtension: "threshfx",
                    payload: .preset(preset)
                )
                ensureWindowContentVisible()
            } catch {
                errorReporter.report(.preset(.importFailed("Could not read \(url.lastPathComponent): \(error.localizedDescription)")))
            }

        default:
            errorReporter.report(.preset(.importFailed("Unsupported Threshold file: \(url.lastPathComponent).")))
        }
    }

    func previewExternalImport(_ request: ExternalFileImportRequest) {
        customSceneDiagnostic("🔬 [CSDiag] previewExternalImport id=\(request.id) payload=\(request.payload)")
        if activeExternalPreviewID != request.id {
            clearExternalPreview(restorePreviewedState: true)
            activeExternalPreviewID = request.id
        }

        switch request.payload {
        case .preset(let preset):
            customSceneDiagnostic("🔬 [CSDiag] previewExternalImport .preset name='\(preset.name)' ft=\(preset.fractalType.rawValue) embeddedFormula=\(preset.embeddedFormula?.name ?? "nil")")
            if externalPreviewRestorePreset == nil {
                externalPreviewRestorePreset = FractalPreset.fromSettings(
                    renderSettings,
                    name: "__externalPreviewRestore__",
                    embeddedFormula: activeEmbeddedFormula
                )
            }
            if !externalPreviewCapturedEmbeddedFormula {
                externalPreviewRestoreEmbeddedFormula = activeEmbeddedFormula
                externalPreviewCapturedEmbeddedFormula = true
            }
            // Defer to the shared scene-load helper so external previews get
            // the same eased transition + gesture overrides as keyboard loads.
            // Guard against stale previews being applied if the user has already
            // moved on to a different import request.
            Task { @MainActor in
                guard activeExternalPreviewID == request.id else { return }
                loadStaticScene(preset, options: [])
            }

        case .animation(let scene):
            if !externalPreviewCapturedScene {
                externalPreviewRestoreScene = animationManager?.currentScene
                externalPreviewCapturedScene = true
            }
            if !externalPreviewCapturedEmbeddedFormula {
                externalPreviewRestoreEmbeddedFormula = activeEmbeddedFormula
                externalPreviewCapturedEmbeddedFormula = true
            }
            guard let formula = scene.embeddedFormula else {
                installEmbeddedFormulaIfNeeded(nil)
                animationManager?.currentScene = scene
                return
            }
            Task { @MainActor in
                let installResult = await activateEmbeddedFormulaForSceneLoad(formula)
                let ready: Bool
                switch installResult {
                case .ready:
                    ready = true
                case .deferred:
                    ready = await waitForRendererAndActivate(formula)
                    if !ready {
                        // Renderer never came up within the wait: queue the
                        // apply behind the activation handler instead of
                        // silently dropping the preview.
                        queueSceneApplyAfterFormulaActivation(formulaHash: formula.shortHash) { [weak self] in
                            guard let self, self.activeExternalPreviewID == request.id else { return }
                            self.animationManager?.currentScene = scene
                        }
                        return
                    }
                case .failed:
                    ready = false
                }
                guard ready, activeExternalPreviewID == request.id else { return }
                animationManager?.currentScene = scene
            }
        }
    }

    func importExternalFile(_ request: ExternalFileImportRequest) {
        customSceneDiagnostic("🔬 [CSDiag] importExternalFile id=\(request.id)")
        switch request.payload {
        case .preset(let preset):
            customSceneDiagnostic("🔬 [CSDiag] importExternalFile .preset name='\(preset.name)' ft=\(preset.fractalType.rawValue) embeddedFormula=\(preset.embeddedFormula?.name ?? "nil")")
            // External imports are the only path that needs to (a) persist the
            // preset to the user's library, (b) write the new state to
            // lastState.json, and (c) close the import sheet. The shared helper
            // handles all of those when asked, otherwise behaves like the
            // in-app scene load.
            loadStaticScene(preset, options: [.saveToLibrary, .persistLastState, .closeExternalSheet])
            return

        case .animation(let scene):
            guard let formula = scene.embeddedFormula else {
                uninstallEmbeddedFormula()
                let importedScene = animationManager?.importScene(scene)
                animationManager?.currentScene = importedScene
                clearExternalPreview(restorePreviewedState: false)
                pendingExternalImport = nil
                ensureWindowContentVisible()
                return
            }
            Task { @MainActor in
                let installResult = await activateEmbeddedFormulaForSceneLoad(formula)
                let ready: Bool
                switch installResult {
                case .ready:
                    ready = true
                case .deferred:
                    ready = await waitForRendererAndActivate(formula)
                    if !ready {
                        // Renderer never came up within the wait. Persist the
                        // import + close the sheet now (the user's intent is
                        // committed), and queue the scene apply behind the
                        // activation handler so it loads when they enter the
                        // immersive space instead of being silently dropped.
                        let importedScene = self.animationManager?.importScene(scene)
                        self.clearExternalPreview(restorePreviewedState: false)
                        self.pendingExternalImport = nil
                        self.ensureWindowContentVisible()
                        queueSceneApplyAfterFormulaActivation(formulaHash: formula.shortHash) { [weak self] in
                            self?.animationManager?.currentScene = importedScene
                        }
                        return
                    }
                case .failed:
                    ready = false
                }
                guard ready else { return }
                let importedScene = animationManager?.importScene(scene)
                animationManager?.currentScene = importedScene
                clearExternalPreview(restorePreviewedState: false)
                pendingExternalImport = nil
                ensureWindowContentVisible()
            }
            return
        }
    }

    func cancelExternalImport(_ request: ExternalFileImportRequest) {
        if activeExternalPreviewID == request.id {
            clearExternalPreview(restorePreviewedState: true)
        }
        if pendingExternalImport?.id == request.id {
            pendingExternalImport = nil
        }
    }

    private func clearExternalPreview(restorePreviewedState: Bool) {
        if restorePreviewedState {
            if externalPreviewCapturedEmbeddedFormula {
                if let formula = externalPreviewRestoreEmbeddedFormula {
                    installEmbeddedFormulaIfNeeded(formula)
                } else {
                    uninstallEmbeddedFormula()
                }
            }
            if let preset = externalPreviewRestorePreset {
                preset.apply(to: renderSettings, resetEnvironment: true)
                gestureController?.syncWithSettings()
                NotificationCenter.default.post(name: AppModel.fractalSettingsDidChangeNotification, object: nil)
            }
            if externalPreviewCapturedScene {
                animationManager?.currentScene = externalPreviewRestoreScene
            }
        }

        externalPreviewRestorePreset = nil
        externalPreviewRestoreScene = nil
        externalPreviewRestoreEmbeddedFormula = nil
        externalPreviewCapturedScene = false
        externalPreviewCapturedEmbeddedFormula = false
        activeExternalPreviewID = nil
    }
    
    /// Callback to open the menu window (set by App scene)
    var openMenuWindowHandler: (() -> Void)?
    
    /// Callback to dismiss the menu window (set by App scene)
    var dismissMenuWindowHandler: (() -> Void)?

    /// Callback to navigate directly to the Fractal > Shape tab.
    var openShapeMenuHandler: (() -> Void)?

    /// Returns true when the Fractal > Shape tab is already active.
    var isShapeMenuActiveHandler: (() -> Bool)?

    /// Callback to navigate directly to the Fractal > Render tab.
    var openRenderMenuHandler: (() -> Void)?

    /// Returns true when the Fractal > Render tab is already active.
    var isRenderMenuActiveHandler: (() -> Bool)?

    /// Callback to present the save preset sheet from the active content view.
    var openSavePresetMenuHandler: (() -> Void)?
    
    /// Toggle menu window visibility.
    /// Closing dismisses the actual window; opening reuses the system-restored placement.
    func toggleMenuWindow() {
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

    func pullMenuWindowTowardUser() {
        guard !isMenuWindowVisible else {
            refreshMenuInteractionState()
            return
        }
        showMenuWindow(reason: "pull gesture")
    }

    func openShapeMenuFromGesture() {
        toggleFractalMenuFromGesture(
            isRequestedTabAlreadyOpen: isShapeMenuActiveHandler?() ?? false,
            openRequestedTab: openShapeMenuHandler,
            label: "Shape"
        )
    }

    func openRenderMenuFromGesture() {
        toggleFractalMenuFromGesture(
            isRequestedTabAlreadyOpen: isRenderMenuActiveHandler?() ?? false,
            openRequestedTab: openRenderMenuHandler,
            label: "Render"
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
        guard isMenuWindowVisible else { return }
        closeMenuWindow(reason: "scene load", bypassGuard: true)
    }

    /// Load a space-warp `.threshfx` into the single active custom slot WITHOUT
    /// changing the fractal type — the warp applies to whatever fractal is active.
    /// Gated by `allowCustomScenes`; nudges `spaceWarpStrength` up so it's visible.
    @MainActor
    func installSpaceWarp(_ warp: EmbeddedFormula) {
        guard Self.allowCustomScenes else {
            errorReporter.report(.preset(.importFailed("Enable “Allow custom scenes” in Settings to load space warps.")))
            return
        }
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
        let interacting = isMenuWindowVisible && (isMenuHovering || menuAdjustmentDepth > 0)
        isMenuInteractionActive = interacting
        renderSettings.isMenuInteractionActive = interacting
        gestureController?.suppressParameterGestures = interacting
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

    /// Optional side-effects to run around a scene load. Defaults match the
    /// in-app / keyboard scene-switch path; external file imports opt in to
    /// persistence + sheet cleanup.
    struct StaticSceneLoadOptions: OptionSet {
        let rawValue: Int
        static let saveToLibrary = StaticSceneLoadOptions(rawValue: 1 << 0)
        static let persistLastState = StaticSceneLoadOptions(rawValue: 1 << 1)
        static let closeExternalSheet = StaticSceneLoadOptions(rawValue: 1 << 2)
    }

    /// Loads a jumping-off / static scene preset through the full pipeline:
    /// embedded-formula install, pipeline prep, eased parameter transition,
    /// gesture overrides, and a settings-changed notification so any live UI
    /// reloads its cache. Shared by the keyboard scene-switch shortcut, the
    /// in-app browse UI, and external file imports (`.threshscene`/`.threshfx`)
    /// so all entry points stay in lockstep.
    @MainActor
    func loadStaticScene(
        _ preset: FractalPreset,
        options: StaticSceneLoadOptions = []
    ) {
        let source = options.isEmpty ? "keyboard" : "external"
        Task { @MainActor in
            customSceneDiagnostic("🔬 [CSDiag] AppModel.loadStaticScene source=\(source) name='\(preset.name)' ft=\(preset.fractalType.rawValue) embeddedFormula=\(preset.embeddedFormula?.name ?? "nil")")
            if let formula = preset.embeddedFormula, formula.effectKind == .spaceWarp {
                // A space warp rides the preset's built-in fractalType — install it
                // and fall through to apply the rest of the scene normally.
                installSpaceWarp(formula)
            } else if let formula = preset.embeddedFormula {
                let installResult = await installEmbeddedFormulaIfNeededAndWait(formula)
                customSceneDiagnostic("🔬 [CSDiag] AppModel.loadStaticScene installEmbeddedFormula returned \(installResult)")
                if installResult == .failed { return }
                if installResult == .deferred {
                    // Renderer isn't up yet (typical: .threshfx opened from
                    // Finder before the user entered the immersive space).
                    // The formula is registered in the catalogs and
                    // `activeEmbeddedFormula` is set, but the renderer's
                    // activation handler is nil, so we can't compile the
                    // MTLLibrary yet. The renderer will pick this up the
                    // moment it starts (its startup reads
                    // `activeEmbeddedFormula` and calls the activation
                    // handler), so we just queue the preset-apply behind the
                    // handler and return immediately. The user can enter the
                    // scene at their own pace and the scene will load.
                    queuePresetApplyAfterFormulaActivation(preset, options: options)
                    return
                }
            } else {
                uninstallEmbeddedFormula()
            }
            // Direct (non-deferred) load: clear any leftover queued preset /
            // scene from a previous deferred import, so a stale queued apply
            // can't fire on the next handler binding.
            pendingPresetForActivation = nil
            pendingSceneApplyAfterActivation = nil
            await applyLoadedScene(preset, options: options)
        }
    }

    /// Wait for `activateEmbeddedFormulaHandler` to bind, then apply the
    /// supplied preset. Surfaces a clear status message in the meantime so
    /// the user knows the import succeeded and they need to enter the scene
    /// to see it. Used as the deferred-activation follow-up to
    /// `loadStaticScene`.
    @MainActor
    private func queuePresetApplyAfterFormulaActivation(
        _ preset: FractalPreset,
        options: StaticSceneLoadOptions,
        timeout: TimeInterval = 10
    ) {
        // Persist + close the import sheet immediately so the user gets
        // visual feedback that the import succeeded. The *visual* scene
        // application (parameters, gesture overrides, eased transition) is
        // what waits for the renderer to come up.
        if options.contains(.saveToLibrary) {
            _ = presetManager.importPreset(preset)
        }
        if options.contains(.persistLastState) {
            saveLastState()
        }
        if options.contains(.closeExternalSheet) {
            clearExternalPreview(restorePreviewedState: false)
            pendingExternalImport = nil
            ensureWindowContentVisible()
        }
        // Stash the preset so the activateEmbeddedFormulaHandler.didSet
        // (and the renderer's startup deferred-activation block) can apply
        // it once the formula has actually been compiled in the renderer.
        // This handles the case where the user enters the scene *after* our
        // 10s timeout has expired: the renderer's startup picks up
        // `activeEmbeddedFormula` and the didSet consumes the queued preset.
        pendingPresetForActivation = preset
        // Auto-open the immersive space if the user is on the menu (or in
        // any state other than already-open). The view that owns
        // @Environment(\.openImmersiveSpace) observes the notification and
        // triggers the open. This is the only way to bridge the import
        // sheet (AppModel-level) to the SwiftUI environment value.
        if immersiveSpaceState != .open {
            NotificationCenter.default.post(
                name: AppModel.requestOpenImmersiveSpaceNotification,
                object: nil,
                userInfo: ["presetID": preset.id.uuidString]
            )
        }
        Task { @MainActor in
            customSceneDiagnostic("🔬 [CSDiag] queuePresetApplyAfterFormulaActivation name='\(preset.name)' hash=\(preset.embeddedFormula?.shortHash ?? "nil")")
            let deadline = Date().addingTimeInterval(timeout)
            while activateEmbeddedFormulaHandler == nil {
                if Date() > deadline {
                    errorReporter.report(.preset(.importFailed(
                        "Custom scene is queued. Enter the immersive space to compile and render the custom shader."
                    )))
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
            // Handler is now bound. Activate the formula, then run the
            // standard preset-apply path. The renderer's startup also runs
            // its own one-shot activation on `activeEmbeddedFormula`; the
            // activation is a no-op when hash + library already match.
            if let handler = activateEmbeddedFormulaHandler,
               let formula = preset.embeddedFormula {
                do {
                    try await handler(formula)
                } catch {
                    errorReporter.report(.preset(.importFailed(
                        "Failed to compile custom shader: \(error.localizedDescription)"
                    )))
                    uninstallEmbeddedFormula()
                    pendingPresetForActivation = nil
                    return
                }
            }
            // If didSet hasn't already drained pendingPresetForActivation
            // (it may have, since it fires whenever the handler is bound),
            // apply the preset now and clear the slot.
            if pendingPresetForActivation != nil {
                pendingPresetForActivation = nil
                await applyLoadedScene(preset, options: [])
            }
        }
    }

    /// The shared tail of `loadStaticScene` and
    /// `queuePresetApplyAfterFormulaActivation`. Runs the eased preset
    /// transition, gesture overrides, and sheet/library/lastState cleanup
    /// exactly once per scene load. Caller is responsible for ensuring the
    /// formula is compiled before invoking this.
    @MainActor
    private func applyLoadedScene(
        _ preset: FractalPreset,
        options: StaticSceneLoadOptions
    ) async {
        if preset.embeddedFormula != nil {
            await preparePipelineHandler?(preset)
            customSceneDiagnostic("🔬 [CSDiag] applyLoadedScene preparePipelineHandler completed; loading preset NOW")
        } else {
            Task { await preparePipelineHandler?(preset) }
            customSceneDiagnostic("🔬 [CSDiag] applyLoadedScene preparePipelineHandler dispatched (fire-and-forget); loading preset NOW")
        }
        // Snapshot the currently displayed parameters so the load can ease
        // from them toward the new preset.
        renderSettings.beginSceneTransitionSnapshot()
        presetManager.loadPreset(
            preset,
            into: renderSettings,
            includePerformance: false,
            resetEnvironment: true
        )
        // Ease displayed parameters toward the new preset's values over the
        // configured "Same Scene Transition Time" instead of snapping.
        renderSettings.commitSceneTransition()
        applyPresetGestureOverridesIfNeeded(for: preset)
        gestureController?.syncWithSettings()
        rememberActiveResetPreset(preset)
        if options.contains(.saveToLibrary) {
            _ = presetManager.importPreset(preset)
        }
        if options.contains(.persistLastState) {
            saveLastState()
        }
        NotificationCenter.default.post(name: AppModel.fractalSettingsDidChangeNotification, object: nil)
        if options.contains(.closeExternalSheet) {
            clearExternalPreview(restorePreviewedState: false)
            pendingExternalImport = nil
            ensureWindowContentVisible()
        }
    }

    /// Wait for the renderer's custom-shader activation handler to bind, then
    /// ask it to compile and install the supplied formula's MTLLibrary.
    ///
    /// On visionOS the handler binds as soon as the user enters the immersive
    /// space (see `Renderer.startRenderLoop`); on iOS / macOS the renderer
    /// runs as soon as the main view appears, so the handler is usually
    /// already present by the time a user-driven import happens.
    ///
    /// We poll the handler — not `rendererStartupWarmupComplete` — because the
    /// handler is the *minimum* signal that "the renderer is alive and can
    /// accept activations." Warmup is a stronger signal (compute pipelines
    /// cached) but it can lag by several seconds; the handler binds first.
    ///
    /// If the user never enters the immersive space, we give up after
    /// `timeout` seconds and return `false` — the renderer-side deferred
    /// activation block will still pick up `activeEmbeddedFormula` if/when
    /// the user later enters the scene, so the formula is not lost.
    @MainActor
    func waitForRendererAndActivate(_ formula: EmbeddedFormula, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while activateEmbeddedFormulaHandler == nil {
            if Date() > deadline {
                errorReporter.report(.preset(.importFailed(
                    "Custom scene is queued. Enter the immersive space to compile and render the custom shader."
                )))
                return false
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        guard let handler = activateEmbeddedFormulaHandler else {
            // Lost the race: the renderer torn down between our poll and now.
            errorReporter.report(.preset(.importFailed(
                "Custom scene is queued. Enter the immersive space to compile and render the custom shader."
            )))
            return false
        }
        // The renderer's startup also re-reads activeEmbeddedFormula and
        // activates it the moment the handler binds, but call again here to
        // cover the case where our poll won the race. The activation is a
        // no-op when the hash + library already match.
        do {
            try await handler(formula)
            return true
        } catch {
            errorReporter.report(.preset(.importFailed(
                "Failed to compile custom shader: \(error.localizedDescription)"
            )))
            uninstallEmbeddedFormula()
            return false
        }
    }

    /// Applies preset-specific gesture binding overrides for known scenes.
    func applyPresetGestureOverridesIfNeeded(for preset: FractalPreset) {
        let normalizedName = preset.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard ["ring around the rosie", "a space ring odyssey"].contains(normalizedName),
              preset.fractalType == .kleinian else { return }

        let triplets = ParameterNodeRegistry.shared.gestureBindableTriplets(for: .kleinian)
        guard let minsTriplet = triplets.first(where: { $0.groupName == "Mins" }),
              let maxsTriplet = triplets.first(where: { $0.groupName == "Maxs" }) else { return }

        renderSettings.setBinding(
            .parameterTriplet(minsTriplet),
            for: GestureSlot(hand: .left, finger: .middle)
        )
        renderSettings.setBinding(
            .parameterTriplet(maxsTriplet),
            for: GestureSlot(hand: .right, finger: .middle)
        )
    }

    /// Loads the previous or next built-in static scene (Jumping Off or Music
    /// Reactive), wrapping around at the ends. Driven by the keyboard
    /// left/right shortcut.
    @MainActor
    func cycleJumpingOffScene(forward: Bool) {
        let scenes = presetManager.presets
            .filter { $0.name != "__lastState__" && $0.isKeyboardSwitchableStaticPreset }
        guard !scenes.isEmpty else { return }

        let currentIndex = activeResetPreset.flatMap { active in
            scenes.firstIndex(where: { $0.id == active.id })
        }

        let nextIndex: Int
        if let currentIndex {
            let count = scenes.count
            nextIndex = ((currentIndex + (forward ? 1 : -1)) % count + count) % count
        } else {
            nextIndex = forward ? 0 : scenes.count - 1
        }

        loadStaticScene(scenes[nextIndex])
    }


    private func canCloseMenuWindowNow() -> Bool {
        CACurrentMediaTime() - lastMenuWindowOpenedAt >= menuWindowRetoggleGuardInterval
    }

    private func showMenuWindow(reason: String) {
        isMenuWindowVisible = true
        lastMenuWindowOpenedAt = CACurrentMediaTime()
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

        isMenuWindowVisible = false
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
        // use, revert to the opacity-hide (drop this call, keep isMenuWindowVisible).
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
        let migrationKey = "gestureDistinctWindowMapping.v7"
        guard UserDefaults.standard.bool(forKey: migrationKey) == false else { return }

        // Ensure gesture toggle is enabled so menu recovery remains possible.
        renderSettings.menuToggleGestureEnabled = true

        // Keep menu recovery easy even for installs that persisted an older or
        // harder-to-perform mode before the current default existed.
        renderSettings.menuToggleGestureMode = .middleOrRingToPalm

        renderSettings.menuToggleHoldDuration = min(renderSettings.menuToggleHoldDuration, GestureDefaults.menuToggleHoldDuration)
        renderSettings.menuToggleActivateThreshold = min(renderSettings.menuToggleActivateThreshold, GestureDefaults.menuToggleActivateThreshold)
        renderSettings.menuToggleReleaseThreshold = min(renderSettings.menuToggleReleaseThreshold, GestureDefaults.menuToggleReleaseThreshold)

        let priorLeftDefault: [PerFingerTapAction] = [.none, .none, .none, .openShapeMenu, .none]
        if renderSettings.perFingerTapLeftActions == [.none, .none, .none, .none, .none]
            || renderSettings.perFingerTapLeftActions == priorLeftDefault {
            renderSettings.perFingerTapLeftActions = GestureDefaults.perFingerTapLeftActions
            GestureDefaults.savePerFingerTapActions(renderSettings.perFingerTapLeftActions, keyPrefix: "perFingerTapLeft")
        }

        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    deinit {
        if let token = cloudFolderObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

}
