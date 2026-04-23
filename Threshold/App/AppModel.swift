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

    // Error reporting for transient banners
    let errorReporter = ErrorReporter()

    // Animation/Scene playback manager
    var animationManager: AnimationManager?
    
    // Menu window visibility (toggled by gesture)
    // We hide content and glass to simulate window close while preserving position/size
    var isMenuWindowVisible: Bool = true

    // Animation Player window visibility (toggled by gesture / UI button)
    var isAnimationPlayerWindowVisible: Bool = false

    @ObservationIgnored private var isMenuHovering: Bool = false
    @ObservationIgnored private var menuAdjustmentDepth: Int = 0
    
    // Screenshot capture (set by Renderer)
    var captureScreenshotHandler: (() async -> Data?)?
    
    // Pipeline preparation handler (set by Renderer)
    // Called when a preset is about to be loaded to ensure the pipeline is ready
    var preparePipelineHandler: ((FractalPreset) async -> Void)?
    
    // Pipeline preparation for specific iteration/ray step values (set by Renderer)
    // Called when sliders change to pre-compile the needed pipeline
    var preparePipelineForValuesHandler: ((Int, Int) async -> Void)?
    
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
            print("🎬 onAnimationPlayerToggle callback fired!")
            self?.toggleAnimationPlayerWindow()
        }

        refreshMenuInteractionState()
        
        // Add built-in presets if this is first launch
        presetManager.addBuiltInPresetsIfNeeded()
        
        // Restore last state if available
        presetManager.restoreLastState(to: renderSettings)
        
        // Restore domain config structs (new persistence format, overlays legacy per-key values)
        SettingsPersistence.restoreAll(into: renderSettings)
        
        // Configure SharePlay session listener
        shareSession?.configureGroupSessions()

    }
    
    /// Save current state for restore on next launch
    func saveLastState() {
        presetManager.saveLastState(from: renderSettings)
        SettingsPersistence.saveAll(from: renderSettings)
    }
    
    /// Callback to open the menu window (set by App scene)
    var openMenuWindowHandler: (() -> Void)?
    
    /// Callback to dismiss the menu window (set by App scene)
    var dismissMenuWindowHandler: (() -> Void)?

    /// Callback to open the animation player window (set by App scene)
    var openAnimationPlayerWindowHandler: (() -> Void)?

    /// Callback to dismiss the animation player window (set by App scene)
    var dismissAnimationPlayerWindowHandler: (() -> Void)?
    
    /// Toggle menu window visibility — dismisses or opens the window for real
    func toggleMenuWindow() {
        if isMenuWindowVisible {
            isMenuWindowVisible = false
            dismissMenuWindowHandler?()
            print("📋 Menu window dismissed")
        } else {
            isMenuWindowVisible = true
            openMenuWindowHandler?()
            print("📋 Menu window opened")
        }
        refreshMenuInteractionState()
    }

    /// Toggle the Animation Player window visibility (gesture- or UI-driven).
    func toggleAnimationPlayerWindow() {
        if isAnimationPlayerWindowVisible {
            isAnimationPlayerWindowVisible = false
            dismissAnimationPlayerWindowHandler?()
            print("🎬 Animation Player window dismissed")
        } else {
            // If no scene is selected, default to the first scene so the player has content.
            if let manager = animationManager, manager.currentScene == nil {
                manager.currentScene = manager.scenes.first
            }
            isAnimationPlayerWindowVisible = true
            openAnimationPlayerWindowHandler?()
            print("🎬 Animation Player window opened")
        }
    }
    
    /// Ensure window content is visible - call when exiting immersive mode or on app launch
    /// Opens the window if it was previously dismissed
    func ensureWindowContentVisible() {
        if !isMenuWindowVisible {
            isMenuWindowVisible = true
            openMenuWindowHandler?()
            print("📋 Menu window restored (re-opened)")
        }
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
        renderSettings.isMenuInteractionActive = interacting
        gestureController?.suppressParameterGestures = interacting
    }

    /// Capture a screenshot for preset thumbnails
    func captureScreenshot() async -> Data? {
        return await captureScreenshotHandler?()
    }

}
