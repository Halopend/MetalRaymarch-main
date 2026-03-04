//
//  AppModel.swift
//  MetalProject
//
//  Created by MU on 18/11/24.
//

import SwiftUI
import ARKit
import CoreGraphics

@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    let menuWindowID = "MenuWindow"
    static let fractalBrowserWindowID = "FractalBrowserWindow"
    static let fractalSettingsDidChangeNotification = Notification.Name("AppModel.fractalSettingsDidChange")
    
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }

    enum RuntimeViewMode: String {
        case raymarch
        case flame
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

    var fps: Double = 0
    
    /// Whether the renderer is currently using a specialized (compiled) pipeline vs generic fallback
    @ObservationIgnored nonisolated(unsafe) var isUsingSpecializedPipeline: Bool = false
    
    nonisolated let renderSettings = RenderSettings()
    
    // Buddhabrot volume renderer settings (shared between UI and render loop)
    nonisolated let buddhabrotSettings = BuddhabrotSettings()
    
    // Audio analyzer for reactive lighting
    let audioAnalyzer = AudioAnalyzer()

    // Apple Music integration for music visualizer
    let appleMusicManager = AppleMusicManager()
    
    // Unified music service (wraps Apple Music)
    private(set) var musicService: MusicService!
    
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
    var leftHandTracked: Bool = false
    var rightHandTracked: Bool = false
    
    /// Diagnostic string describing why gestures may not be working.
    /// Updated by the render loop and displayed in the Gesture Controls UI section.
    var gestureStatus: String = "Waiting for immersive space…"
    
    /// Whether the hand tracking ARKit provider is actively running.
    var handTrackingRunning: Bool = false

    /// Internal diagnostics for cross-source parameter arbitration.
    var showParameterDebugPanel: Bool = false {
        didSet {
            UserDefaults.standard.set(showParameterDebugPanel, forKey: "showParameterDebugPanel")
            ParameterDebugLogGate.isEnabled = showParameterDebugPanel
        }
    }

    
    // Gesture controller for mapping hand gestures to parameters
    var gestureController: GestureController?
    
    nonisolated let clock = AppClock()
    
    // Preset management
    let presetManager = PresetManager()

    // Error reporting for transient banners
    let errorReporter = ErrorReporter()

    // Flame runtime state (shared between browser + main panel)
    var importedFlame: FlameDocument?
    var importedFlamePreviewImage: CGImage?
    var importedFlameStatusText: String = ""
    var importedFlameErrorText: String?
    
    // Animation/Scene playback manager
    var animationManager: AnimationManager?
    
    // Menu window visibility (toggled by gesture)
    // We hide content and glass to simulate window close while preserving position/size
    var isMenuWindowVisible: Bool = true

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
            gestureController?.setDebugTraceEnabled(parameterOperationDebugTrace)
        }
    }
    
    init() {
        // Initialize gesture controller with render settings
        gestureController = GestureController(renderSettings: renderSettings)
        gestureController?.setDebugTraceEnabled(parameterOperationDebugTrace)
        
        // Initialize unified music service
        musicService = MusicService(appleMusic: appleMusicManager)
        
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
        
        // Initialize SharePlay session
        shareSession = FractalShareSession(renderSettings: renderSettings)
        
        // Setup gesture callbacks
        gestureController?.onMenuToggle = { [weak self] in
            print("📋 onMenuToggle callback fired!")
            self?.toggleMenuWindow()
        }

        refreshMenuInteractionState()
        
        // Add built-in presets if this is first launch
        presetManager.addBuiltInPresetsIfNeeded()
        
        // Restore last state if available
        presetManager.restoreLastState(to: renderSettings)
        
        // Configure SharePlay session listener
        shareSession?.configureGroupSessions()

        // Load default flame from bundled library
        loadDefaultFlame()
    }

    /// Load the first flame in the bundled library as the default flame.
    private func loadDefaultFlame() {
        let library = FlameLibrary.shared
        library.loadIfNeeded()
        if let flame = library.defaultFlame {
            importedFlame = flame
            importedFlameStatusText = "Loaded bundled flame: \(flame.name)"
        }
    }
    
    /// Save current state for restore on next launch
    func saveLastState() {
        presetManager.saveLastState(from: renderSettings)
    }
    
    /// Callback to open the menu window (set by App scene)
    var openMenuWindowHandler: (() -> Void)?
    
    /// Callback to dismiss the menu window (set by App scene)
    var dismissMenuWindowHandler: (() -> Void)?
    
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

    func parameterDiagnosticsText() -> String {
        let registry = ParameterNodeRegistry.shared.metricsSnapshot()
        return "Batch rebuilds: \(registry.batchRebuildCount) • Node lookups: \(registry.nodeLookupCount) in \(String(format: "%.2f", registry.nodeLookupDurationMs))ms"
    }

    /// Capture a screenshot for preset thumbnails
    func captureScreenshot() async -> Data? {
        return await captureScreenshotHandler?()
    }

}

