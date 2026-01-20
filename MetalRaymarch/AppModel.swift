//
//  AppModel.swift
//  MetalProject
//
//  Created by MU on 18/11/24.
//

import SwiftUI
import ARKit
import os  // For os_unfair_lock - fastest available lock primitive

/// Quality preset that bundles fractal iterations and ray steps
enum QualityPreset: String, CaseIterable {
    case low = "Low"
    case mid = "Mid"
    case high = "High"
    case ultra = "Ultra"
    
    var fractalIterations: Int {
        switch self {
        case .low: return 6
        case .mid: return 9
        case .high: return 12
        case .ultra: return 16
        }
    }
    
    var raySteps: Int {
        switch self {
        case .low: return 32
        case .mid: return 64
        case .high: return 100
        case .ultra: return 128
        }
    }
    
    /// Try to detect preset from current settings
    static func detect(fractalIterations: Int, raySteps: Int) -> QualityPreset? {
        for preset in allCases {
            if preset.fractalIterations == fractalIterations && preset.raySteps == raySteps {
                return preset
            }
        }
        return nil
    }
}

@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    let menuWindowID = "MenuWindow"
    
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    
    var immersiveSpaceState = ImmersiveSpaceState.closed

    var fps: Double = 0
    
    nonisolated let renderSettings = RenderSettings()
    
    // Hand tracking state
    var handTrackingEnabled: Bool = true
    var leftHandTracked: Bool = false
    var rightHandTracked: Bool = false
    
    // Gesture controller for mapping hand gestures to parameters
    var gestureController: GestureController?
    
    nonisolated let clock = AppClock()
    
    // Preset management
    let presetManager = PresetManager()
    
    // Parameter recording
    var parameterRecorder: ParameterRecorder?
    
    // Menu window visibility (toggled by gesture)
    // We hide content and glass to simulate window close while preserving position/size
    var isMenuWindowVisible: Bool = true
    
    // Screenshot capture (set by Renderer)
    var captureScreenshotHandler: (() async -> Data?)?
    
    init() {
        // Initialize gesture controller with render settings
        gestureController = GestureController(renderSettings: renderSettings)
        
        // Initialize parameter recorder
        parameterRecorder = ParameterRecorder(renderSettings: renderSettings)
        
        // Setup gesture callbacks
        gestureController?.onRecordingToggle = { [weak self] in
            self?.toggleRecording()
        }
        
        gestureController?.onMenuToggle = { [weak self] in
            self?.toggleMenuWindow()
        }
        
        // Add built-in presets if this is first launch
        presetManager.addBuiltInPresetsIfNeeded()
    }
    
    /// Toggle recording state
    func toggleRecording() {
        guard let recorder = parameterRecorder else { return }
        
        if recorder.isRecording {
            let _ = recorder.stopRecording()
        } else if recorder.isIdle {
            recorder.startRecording()
        }
    }
    
    /// Toggle menu window visibility (hides content while preserving window position/size)
    func toggleMenuWindow() {
        withAnimation(.easeInOut(duration: 0.25)) {
            isMenuWindowVisible.toggle()
        }
        print("📋 Menu window: \(isMenuWindowVisible ? "shown" : "hidden")")
    }
    
    /// Capture a screenshot for preset thumbnails
    func captureScreenshot() async -> Data? {
        return await captureScreenshotHandler?()
    }
    
    /// Update the recorder (call from render loop)
    func updateRecorder(deltaTime: Float) {
        guard let recorder = parameterRecorder else { return }
        
        // Update recording if active
        if recorder.isRecording {
            recorder.update()
        }
        
        // Update playback if active
        if recorder.isPlaying {
            recorder.updatePlayback(deltaTime: deltaTime)
        }
    }
}

// Fractal type enum matching ShaderTypes.h
enum FractalType: Int32 {
    case mandelbox = 0
    case triforce = 1
    
    var displayName: String {
        switch self {
        case .mandelbox: return "Mandelbox"
        case .triforce: return "Triforce"
        }
    }
}

// RenderSettings uses os_unfair_lock for minimal lock overhead
// This is the fastest synchronization primitive on Apple platforms
// NSLock has ~2-3x more overhead due to Objective-C dispatch
final class RenderSettings: @unchecked Sendable {
    // os_unfair_lock is a low-level spinlock - fastest for short critical sections
    private var _lock = os_unfair_lock()
    
    // Inline lock/unlock for zero function call overhead
    @inline(__always)
    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return body()
    }
    
    private var _minDistance: Float = 0.8           // 80% of max (1.0) for quality
    private var _scale: Float = 1.0
    private var _position: SIMD3<Float> = .zero
    private var _fractalScale: Float = 2.8
    private var _fractalIterations: Int = 9         // Mid quality default
    private var _maxRaySteps: Int = 64              // Mid quality default
    private var _foveationIntensity: Float = 1.0    // Gentle shader-side foveation (rate maps handle gaze tracking)
    private var _colorMix: Float = 0.5
    private var _glowIntensity: Float = 0.2
    private var _lightingPlay: Bool = false         // Play/pause lighting effects
    private var _foldingLimit: Float = 1.0
    private var _sphereRadius: Float = 0.5
    private var _colorIterations: Float = 8.0       // Lower = faster (was 10)
    private var _resolutionScale: Float = 1.0       // Native resolution (MetalFX removed)
    private var _fractalType: FractalType = .mandelbox  // Current fractal type
    private var _preferFoveated: Bool = false        // When true, disable MetalFX and keep system foveation
    private var _tileSize: Int = 0                   // 0=disabled, 2=2x2, 4=4x4, 8=8x8 adaptive hierarchical
    private var _useHierarchical: Bool = true        // Use hierarchical coarse/fine raymarching
    private var _debugHierarchical: Bool = false     // Visualize adaptive hierarchy levels
    private var _limitFlash: Float = 0.0             // Flash intensity when gesture hits parameter limit (0-1, decays)
    
    // HUD display
    private var _showHUD: Bool = true                // Show in-world HUD (default on)
    private var _activeGestureIndex: Int = 0         // Currently active gesture (0=none, 1=index, 2=middle, 3=ring)
    private var _useRelativeGestures: Bool = false   // Use relative gestures (delta-based) instead of absolute mapping

    // Safety bubble controls
    private var _safetyBubbleEnabled: Bool = true   // Cut out a small safe sphere (default on)
    private var _safetyBubbleRadius: Float = 1.8    // Radius of the safe bubble (meters)
    
    // === GESTURE TARGET VALUES ===
    // These are set by gestures asynchronously. Renderer interpolates from current to target each frame.
    // This decouples gesture detection (30Hz async) from render smoothing (90Hz sync).
    private var _targetMinDistance: Float = 0.8
    private var _targetFoldingLimit: Float = 1.0
    private var _targetSphereRadius: Float = 0.5
    private var _targetPosition: SIMD3<Float> = .zero
    
    // === REFINING PARAMETERS (Polychronakis 2024 / Keinert 2014) ===
    // These control the sphere tracing optimization thresholds
    private var _relaxFactor: Float = 1.6            // Over-relaxation multiplier (1.0-2.0)
    private var _relaxBacktrack: Float = 0.7         // Backtrack factor when overshooting (0.5-1.0)
    private var _sdfScaleCoarse: Float = 1.3         // SDF scaling for coarse pass (1.0-2.0)
    private var _sdfScaleSuperCoarse: Float = 1.5    // SDF scaling for super-coarse pass (1.0-2.5)
    private var _earlyTermRatio: Float = 0.3         // Early termination convergence ratio (0.1-0.5)
    private var _earlyTermCount: Int = 3             // Steps before early termination (1-5)

    var minDistance: Float {
        get { withLock { _minDistance } }
        set { withLock { _minDistance = newValue } }
    }
    
    var scale: Float {
        get { withLock { _scale } }
        set { withLock { _scale = newValue } }
    }
    
    var position: SIMD3<Float> {
        get { withLock { _position } }
        set { withLock { _position = newValue } }
    }
    
    var fractalScale: Float {
        get { withLock { _fractalScale } }
        set { withLock { _fractalScale = newValue } }
    }
    
    var fractalIterations: Int {
        get { withLock { _fractalIterations } }
        set { withLock { _fractalIterations = newValue } }
    }
    
    var maxRaySteps: Int {
        get { withLock { _maxRaySteps } }
        set { withLock { _maxRaySteps = newValue } }
    }
    
    var foveationIntensity: Float {
        get { withLock { _foveationIntensity } }
        set { withLock { _foveationIntensity = newValue } }
    }
    
    var colorMix: Float {
        get { withLock { _colorMix } }
        set { withLock { _colorMix = newValue } }
    }
    
    var glowIntensity: Float {
        get { withLock { _glowIntensity } }
        set { withLock { _glowIntensity = newValue } }
    }

    var lightingPlay: Bool {
        get { withLock { _lightingPlay } }
        set { withLock { _lightingPlay = newValue } }
    }
    
    var foldingLimit: Float {
        get { withLock { _foldingLimit } }
        set { withLock { _foldingLimit = newValue } }
    }
    
    var sphereRadius: Float {
        get { withLock { _sphereRadius } }
        set { withLock { _sphereRadius = newValue } }
    }
    
    var colorIterations: Float {
        get { withLock { _colorIterations } }
        set { withLock { _colorIterations = newValue } }
    }
    
    var resolutionScale: Float {
        get { withLock { _resolutionScale } }
        // Min 0.5 (50%) - below this spatial upscaling quality degrades significantly
        // Max 1.0 (100%) - no upscaling needed
        // Sweet spot is 0.67-0.75 for best quality/performance balance
        set { withLock { _resolutionScale = max(0.5, min(1.0, newValue)) } }
    }
    
    var fractalType: FractalType {
        get { withLock { _fractalType } }
        set { withLock { _fractalType = newValue } }
    }

    /// Prefer system foveated rendering over MetalFX upscaling (mutually exclusive)
    var preferFoveated: Bool {
        get { withLock { _preferFoveated } }
        set { withLock { _preferFoveated = newValue } }
    }

    // 0 = disabled (standard per-pixel raymarch)
    // 2 = 2x2 tiles (4x overhead reduction, high quality)
    // 4 = 4x4 tiles (16x overhead reduction, performance mode)
    // 8 = 8x8 adaptive hierarchical (3-8x speedup, best performance)
    var tileSize: Int {
        get { withLock { _tileSize } }
        set { withLock { _tileSize = newValue } }
    }
    
    var useHierarchical: Bool {
        get { withLock { _useHierarchical } }
        set { withLock { _useHierarchical = newValue } }
    }
    
    var debugHierarchical: Bool {
        get { withLock { _debugHierarchical } }
        set { withLock { _debugHierarchical = newValue } }
    }
    
    /// Flash intensity for limit feedback (0-1). Set to 1.0 to trigger flash, decays automatically.
    var limitFlash: Float {
        get { withLock { _limitFlash } }
        set { withLock { _limitFlash = newValue } }
    }
    
    /// Decay the limit flash. Call once per frame.
    func updateLimitFlash(deltaTime: Float) {
        withLock {
            if _limitFlash > 0 {
                _limitFlash = max(0, _limitFlash - deltaTime * 4.0) // Fade over ~0.25s
            }
        }
    }
    
    /// Trigger a limit flash
    func triggerLimitFlash() {
        withLock {
            _limitFlash = 1.0
        }
    }
    
    var showHUD: Bool {
        get { withLock { _showHUD } }
        set { withLock { _showHUD = newValue } }
    }
    
    var activeGestureIndex: Int {
        get { withLock { _activeGestureIndex } }
        set { withLock { _activeGestureIndex = newValue } }
    }

    var useRelativeGestures: Bool {
        get { withLock { _useRelativeGestures } }
        set { withLock { _useRelativeGestures = newValue } }
    }

    /// Enable safety bubble around the camera to prevent clipping into fractal geometry
    var safetyBubbleEnabled: Bool {
        get { withLock { _safetyBubbleEnabled } }
        set { withLock { _safetyBubbleEnabled = newValue } }
    }

    /// Radius of the safety bubble in meters (0.05 - 2.5)
    var safetyBubbleRadius: Float {
        get { withLock { _safetyBubbleRadius } }
        set { withLock { _safetyBubbleRadius = max(0.05, min(2.5, newValue)) } }
    }
    
    // === GESTURE TARGET VALUES ===
    // UI/gestures set these asynchronously. Renderer interpolates current → target each frame.
    // This cleanly separates: (1) intent (targets) from (2) animation (smoothing)
    
    var targetMinDistance: Float {
        get { withLock { _targetMinDistance } }
        set { withLock { _targetMinDistance = newValue } }
    }
    
    var targetFoldingLimit: Float {
        get { withLock { _targetFoldingLimit } }
        set { withLock { _targetFoldingLimit = newValue } }
    }
    
    var targetSphereRadius: Float {
        get { withLock { _targetSphereRadius } }
        set { withLock { _targetSphereRadius = newValue } }
    }
    
    var targetPosition: SIMD3<Float> {
        get { withLock { _targetPosition } }
        set { withLock { _targetPosition = newValue } }
    }
    
    /// Interpolation speed for gesture-controlled parameters (higher = faster convergence)
    /// 18.0 = ~63% convergence in 55ms, very responsive while still smooth
    private let gestureInterpolationSpeed: Float = 18.0
    
    /// Called by Renderer every frame to smoothly interpolate current values toward targets.
    /// This is the ONLY place smoothing happens for gesture parameters - single source of truth.
    /// Uses frame-rate independent exponential decay for consistent feel at any FPS.
    /// - Parameter deltaTime: Time since last frame in seconds
    func interpolateToTargets(deltaTime: Float) {
        withLock {
            // Guard against bad deltaTime values that could cause instability
            let clampedDT = max(0.001, min(0.1, deltaTime))  // 10ms to 100ms range
            
            // Exponential decay: factor = 1 - e^(-speed * dt)
            // At speed=18, dt=1/90: factor ≈ 0.18 (smooth 90fps)
            // At speed=18, dt=1/45: factor ≈ 0.33 (catches up on slow frames)
            let factor = 1.0 - exp(-gestureInterpolationSpeed * clampedDT)
            
            // Check for NaN/Inf in targets before interpolating
            if _targetMinDistance.isNaN || _targetMinDistance.isInfinite {
                print("⚠️ ANOMALY: targetMinDistance is \(_targetMinDistance), resetting to 0.8")
                _targetMinDistance = 0.8
            }
            if _targetFoldingLimit.isNaN || _targetFoldingLimit.isInfinite {
                print("⚠️ ANOMALY: targetFoldingLimit is \(_targetFoldingLimit), resetting to 1.0")
                _targetFoldingLimit = 1.0
            }
            if _targetSphereRadius.isNaN || _targetSphereRadius.isInfinite {
                print("⚠️ ANOMALY: targetSphereRadius is \(_targetSphereRadius), resetting to 0.5")
                _targetSphereRadius = 0.5
            }
            if _targetPosition.x.isNaN || _targetPosition.y.isNaN || _targetPosition.z.isNaN {
                print("⚠️ ANOMALY: targetPosition contains NaN, resetting to zero")
                _targetPosition = .zero
            }
            
            _minDistance += (_targetMinDistance - _minDistance) * factor
            _foldingLimit += (_targetFoldingLimit - _foldingLimit) * factor
            _sphereRadius += (_targetSphereRadius - _sphereRadius) * factor
            _position += (_targetPosition - _position) * factor
            
            // Clamp current values to sane ranges as a safety net
            _minDistance = max(0.1, min(10.0, _minDistance))
            _foldingLimit = max(0.1, min(20.0, _foldingLimit))
            _sphereRadius = max(0.05, min(5.0, _sphereRadius))
            
            // Clamp position to prevent drifting to infinity
            let maxPos: Float = 100.0
            _position.x = max(-maxPos, min(maxPos, _position.x))
            _position.y = max(-maxPos, min(maxPos, _position.y))
            _position.z = max(-maxPos, min(maxPos, _position.z))
        }
    }
    
    /// Snap current values immediately to targets (no smoothing)
    /// Use when loading presets or resetting state
    func snapToTargets() {
        withLock {
            _minDistance = _targetMinDistance
            _foldingLimit = _targetFoldingLimit
            _sphereRadius = _targetSphereRadius
            _position = _targetPosition
        }
    }
    
    /// Set all targets at once (for preset loading)
    func setTargets(minDistance: Float, foldingLimit: Float, sphereRadius: Float, position: SIMD3<Float>) {
        withLock {
            _targetMinDistance = minDistance
            _targetFoldingLimit = foldingLimit
            _targetSphereRadius = sphereRadius
            _targetPosition = position
        }
    }
    
    // === REFINING PARAMETERS ===
    // Over-relaxation multiplier (Keinert 2014)
    var relaxFactor: Float {
        get { withLock { _relaxFactor } }
        set { 
            withLock { _relaxFactor = newValue }
            print("[REFINE] relaxFactor = \(newValue)")
        }
    }
    
    // Backtrack factor when overshooting
    var relaxBacktrack: Float {
        get { withLock { _relaxBacktrack } }
        set { 
            withLock { _relaxBacktrack = newValue }
            print("[REFINE] relaxBacktrack = \(newValue)")
        }
    }
    
    // SDF scaling for coarse pass (Polychronakis 2024)
    var sdfScaleCoarse: Float {
        get { withLock { _sdfScaleCoarse } }
        set { 
            withLock { _sdfScaleCoarse = newValue }
            print("[REFINE] sdfScaleCoarse = \(newValue)")
        }
    }
    
    // SDF scaling for super-coarse pass
    var sdfScaleSuperCoarse: Float {
        get { withLock { _sdfScaleSuperCoarse } }
        set { 
            withLock { _sdfScaleSuperCoarse = newValue }
            print("[REFINE] sdfScaleSuperCoarse = \(newValue)")
        }
    }
    
    // Early termination convergence ratio
    var earlyTermRatio: Float {
        get { withLock { _earlyTermRatio } }
        set { 
            withLock { _earlyTermRatio = newValue }
            print("[REFINE] earlyTermRatio = \(newValue)")
        }
    }
    
    // Steps before early termination
    var earlyTermCount: Int {
        get { withLock { _earlyTermCount } }
        set { 
            withLock { _earlyTermCount = newValue }
            print("[REFINE] earlyTermCount = \(newValue)")
        }
    }
    
    // Log all current refining values
    func logRefiningValues() {
        print("[REFINE] === Current Refining Values ===")
        print("[REFINE] relaxFactor = \(relaxFactor)")
        print("[REFINE] relaxBacktrack = \(relaxBacktrack)")
        print("[REFINE] sdfScaleCoarse = \(sdfScaleCoarse)")
        print("[REFINE] sdfScaleSuperCoarse = \(sdfScaleSuperCoarse)")
        print("[REFINE] earlyTermRatio = \(earlyTermRatio)")
        print("[REFINE] earlyTermCount = \(earlyTermCount)")
        print("[REFINE] ================================")
    }
}

class AppClock {
    private var accumulatedTime: TimeInterval = 0
    private var startTime: Date?
    
    var speed: Double = 0 {
        willSet {
            accumulatedTime = time
        }
        didSet {
            startTime = (speed > 0 ? Date.now : nil)
        }
    }
    
    var time: TimeInterval {
        accumulatedTime + abs(startTime?.timeIntervalSinceNow ?? 0) * speed
    }
}
