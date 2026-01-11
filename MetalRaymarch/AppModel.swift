//
//  AppModel.swift
//  MetalProject
//
//  Created by MU on 18/11/24.
//

import SwiftUI
import ARKit
import os  // For os_unfair_lock - fastest available lock primitive

@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    
    var immersiveSpaceState = ImmersiveSpaceState.closed

    var fps: Double = 0
    
    nonisolated let renderSettings = RenderSettings()
    
    // MetalFX / spatial upscaling state exposed for UI/debugging
    var metalFXAvailable: Bool = false
    var metalFXStatus: String = "Unknown"
    
    // Hand tracking state
    var handTrackingEnabled: Bool = true
    var leftHandTracked: Bool = false
    var rightHandTracked: Bool = false
    
    // Gesture controller for mapping hand gestures to parameters
    var gestureController: GestureController?
    
    nonisolated let clock = AppClock()
    
    // Preset management
    let presetManager = PresetManager()
    
    // Screenshot capture (set by Renderer)
    var captureScreenshotHandler: (() async -> Data?)?
    
    init() {
        // Initialize gesture controller with render settings
        gestureController = GestureController(renderSettings: renderSettings)
        
        // Add built-in presets if this is first launch
        presetManager.addBuiltInPresetsIfNeeded()
    }
    
    /// Capture a screenshot for preset thumbnails
    func captureScreenshot() async -> Data? {
        return await captureScreenshotHandler?()
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
    private var _fractalIterations: Int = 6         // Slightly higher default for quality
    private var _maxRaySteps: Int = 32              // Lower = faster (was 48) - target 90fps
    private var _foveationIntensity: Float = 1.0    // Gentle shader-side foveation (rate maps handle gaze tracking)
    private var _colorMix: Float = 0.5
    private var _glowIntensity: Float = 0.2
    private var _foldingLimit: Float = 1.0
    private var _sphereRadius: Float = 0.5
    private var _colorIterations: Float = 8.0       // Lower = faster (was 10)
    private var _resolutionScale: Float = 0.5       // MetalFX upscaling: render at 50%, upscale to 100%
    private var _debugEyeTint: Bool = false          // Force per-eye red/blue debug fill
    private var _tileSize: Int = 0                   // 0=disabled, 2=2x2, 4=4x4, 8=8x8 adaptive hierarchical
    private var _useHierarchical: Bool = true        // Use hierarchical coarse/fine raymarching
    private var _debugHierarchical: Bool = false     // Visualize adaptive hierarchy levels
    private var _limitFlash: Float = 0.0             // Flash intensity when gesture hits parameter limit (0-1, decays)
    private var _sceneIndex: Int = 0                 // 0 = Mandelbox, 1 = Glowy IFS
    
    // IFS Scene parameters
    private var _ifsScale: Float = 1.74              // IFS scaling factor (default 1.74)
    private var _ifsOffset: Float = 0.98             // IFS offset parameter (default 0.98)
    private var _ifsGlow: Float = 1.0                // IFS glow intensity multiplier
    
    // HUD display
    private var _showHUD: Bool = true                // Show in-world HUD (default on)
    private var _activeGestureIndex: Int = 0         // Currently active gesture (0=none, 1=index, 2=middle, 3=ring)
    private var _showFurHands: Bool = false          // Render hands as fur (default off)
    
    // Grid Sphere Tracing (GST)
    private var _useGST: Bool = true                // Use precomputed SDF grid for raymarching (default ON)

    // Safety bubble controls
    private var _safetyBubbleEnabled: Bool = true   // Cut out a small safe sphere (default on)
    private var _safetyBubbleRadius: Float = 1.8    // Radius of the safe bubble (meters)

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
        set { withLock { _resolutionScale = max(0.25, min(1.0, newValue)) } }
    }

    var debugEyeTint: Bool {
        get { withLock { _debugEyeTint } }
        set { withLock { _debugEyeTint = newValue } }
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
    
    /// Current scene: 0 = Mandelbox, 1 = Glowy IFS
    var sceneIndex: Int {
        get { withLock { _sceneIndex } }
        set { withLock { _sceneIndex = newValue } }
    }
    
    // IFS Scene parameters
    var ifsScale: Float {
        get { withLock { _ifsScale } }
        set { withLock { _ifsScale = newValue } }
    }
    
    var ifsOffset: Float {
        get { withLock { _ifsOffset } }
        set { withLock { _ifsOffset = newValue } }
    }
    
    var ifsGlow: Float {
        get { withLock { _ifsGlow } }
        set { withLock { _ifsGlow = newValue } }
    }
    
    var showHUD: Bool {
        get { withLock { _showHUD } }
        set { withLock { _showHUD = newValue } }
    }
    
    var activeGestureIndex: Int {
        get { withLock { _activeGestureIndex } }
        set { withLock { _activeGestureIndex = newValue } }
    }
    
    var showFurHands: Bool {
        get { withLock { _showFurHands } }
        set { withLock { _showFurHands = newValue } }
    }
    
    /// Enable Grid Sphere Tracing for faster ray marching using precomputed SDF grids
    var useGST: Bool {
        get { withLock { _useGST } }
        set { withLock { _useGST = newValue } }
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
