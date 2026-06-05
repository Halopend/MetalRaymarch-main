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

    /// Inferred user posture. `.unknown` until world tracking provides a valid height reading.
    var detectedPosture: UserPosture { UserPosture.detect(headHeightMeters: headHeightMeters) }

    @ObservationIgnored private var isMenuHovering: Bool = false
    @ObservationIgnored private var menuAdjustmentDepth: Int = 0
    
    // Screenshot capture (set by Renderer)
    var captureScreenshotHandler: (() async -> Data?)?

    @ObservationIgnored private var activeRenderLoopTask: Task<Void, Never>?
    @ObservationIgnored private var activeRenderLoopID: UUID?

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
            Task { @MainActor in
                do {
                    try await handler(formula)
                } catch {
                    self.errorReporter.report(.preset(.importFailed(
                        "Failed to compile custom shader: \(error.localizedDescription)"
                    )))
                    self.uninstallEmbeddedFormula()
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
            print("📋 onMenuToggle callback fired!")
            self?.toggleMenuWindow()
        }
        gestureController?.onAnimationPlayerToggle = { [weak self] in
            self?.toggleAnimationPlayback()
        }
        gestureController?.onOpenShapeMenu = { [weak self] in
            print("🧭 onOpenShapeMenu callback fired!")
            self?.openShapeMenuFromGesture()
        }
        gestureController?.onOpenRenderMenu = { [weak self] in
            print("🎛️ onOpenRenderMenu callback fired!")
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
            installEmbeddedFormulaIfNeeded(formula)
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
        NotificationCenter.default.addObserver(
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
            guard let formula = preset.embeddedFormula else {
                customSceneDiagnostic("🔬 [CSDiag] previewExternalImport BUILT-IN preset path (no embeddedFormula) — dispatching prewarm Task + applying preset synchronously")
                installEmbeddedFormulaIfNeeded(nil)
                Task { await preparePipelineHandler?(preset) }
                preset.apply(to: renderSettings, resetEnvironment: true)
                gestureController?.syncWithSettings()
                NotificationCenter.default.post(name: AppModel.fractalSettingsDidChangeNotification, object: nil)
                return
            }
            customSceneDiagnostic("🔬 [CSDiag] previewExternalImport CUSTOM preset path — will activate formula then preparePipeline then apply")
            Task { @MainActor in
                let activated = await activateEmbeddedFormulaForSceneLoad(formula)
                customSceneDiagnostic("🔬 [CSDiag] previewExternalImport activateEmbeddedFormulaForSceneLoad returned \(activated)")
                guard activated, activeExternalPreviewID == request.id else { return }
                await preparePipelineHandler?(preset)
                customSceneDiagnostic("🔬 [CSDiag] previewExternalImport preparePipelineHandler completed; applying preset NOW")
                preset.apply(to: renderSettings, resetEnvironment: true)
                gestureController?.syncWithSettings()
                NotificationCenter.default.post(name: AppModel.fractalSettingsDidChangeNotification, object: nil)
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
                let activated = await activateEmbeddedFormulaForSceneLoad(formula)
                guard activated, activeExternalPreviewID == request.id else { return }
                animationManager?.currentScene = scene
            }
        }
    }

    func importExternalFile(_ request: ExternalFileImportRequest) {
        customSceneDiagnostic("🔬 [CSDiag] importExternalFile id=\(request.id)")
        switch request.payload {
        case .preset(let preset):
            customSceneDiagnostic("🔬 [CSDiag] importExternalFile .preset name='\(preset.name)' ft=\(preset.fractalType.rawValue) embeddedFormula=\(preset.embeddedFormula?.name ?? "nil")")
            guard let formula = preset.embeddedFormula else {
                uninstallEmbeddedFormula()
                let importedPreset = presetManager.importPreset(preset)
                Task { await preparePipelineHandler?(importedPreset) }
                presetManager.loadPreset(importedPreset, into: renderSettings, resetEnvironment: true)
                gestureController?.syncWithSettings()
                rememberActiveResetPreset(importedPreset)
                saveLastState()
                NotificationCenter.default.post(name: AppModel.fractalSettingsDidChangeNotification, object: nil)
                clearExternalPreview(restorePreviewedState: false)
                pendingExternalImport = nil
                ensureWindowContentVisible()
                return
            }
            Task { @MainActor in
                let activated = await activateEmbeddedFormulaForSceneLoad(formula)
                customSceneDiagnostic("🔬 [CSDiag] importExternalFile activateEmbeddedFormulaForSceneLoad returned \(activated)")
                guard activated else { return }
                let importedPreset = presetManager.importPreset(preset)
                await preparePipelineHandler?(importedPreset)
                customSceneDiagnostic("🔬 [CSDiag] importExternalFile preparePipelineHandler completed; loading preset NOW")
                presetManager.loadPreset(importedPreset, into: renderSettings, resetEnvironment: true)
                gestureController?.syncWithSettings()
                rememberActiveResetPreset(importedPreset)
                saveLastState()
                NotificationCenter.default.post(name: AppModel.fractalSettingsDidChangeNotification, object: nil)
                clearExternalPreview(restorePreviewedState: false)
                pendingExternalImport = nil
                ensureWindowContentVisible()
            }
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
                let activated = await activateEmbeddedFormulaForSceneLoad(formula)
                guard activated else { return }
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
                print("📋 Ignored immediate menu close after open")
                return
            }
            closeMenuWindow(reason: "toggle")
        } else {
            showMenuWindow(reason: "toggle")
        }
    }

    /// Show the menu window via gesture. Does not reposition the restored window.
    func openMenuWindowFromGesture() {
        guard !isMenuWindowVisible else {
            refreshMenuInteractionState()
            return
        }
        showMenuWindow(reason: "gesture")
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

    /// Dismiss the menu window during scene load so hand gestures are immediately available.
    func dismissMenuWindowForSceneLoad() {
        guard isMenuWindowVisible else { return }
        closeMenuWindow(reason: "scene load", bypassGuard: true)
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

    /// Legacy gesture hook retained so existing finger-tap mappings keep working.
    func toggleAnimationPlayerWindow() {
        toggleAnimationPlayback()
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
            print("🖐️ Auto-cleared stale hover state (no hover events for 3s)")
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

    func clearActiveResetPreset() {
        activeResetPreset = nil
    }

    private func canCloseMenuWindowNow() -> Bool {
        CACurrentMediaTime() - lastMenuWindowOpenedAt >= menuWindowRetoggleGuardInterval
    }

    private func showMenuWindow(reason: String) {
        isMenuWindowVisible = true
        lastMenuWindowOpenedAt = CACurrentMediaTime()
        openMenuWindowHandler?()
        refreshMenuInteractionState()
        print("📋 Menu window shown (\(reason))")
    }

    private func closeMenuWindow(reason: String, bypassGuard: Bool = false) {
        guard isMenuWindowVisible else {
            refreshMenuInteractionState()
            return
        }
        guard bypassGuard || canCloseMenuWindowNow() else {
            refreshMenuInteractionState()
            print("📋 Ignored immediate menu close after open")
            return
        }

        isMenuWindowVisible = false
        isMenuHovering = false
        menuAdjustmentDepth = 0
        dismissMenuWindowHandler?()
        refreshMenuInteractionState()
        print("📋 Menu window dismissed (\(reason))")
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
        print("🧭 \(label) menu shown (gesture)")
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

}
