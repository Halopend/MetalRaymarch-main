//
//  AppModel.swift
//  MetalProject
//
//  Created by MU on 18/11/24.
//

import SwiftUI
import ARKit

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
    
    init() {
        // Initialize gesture controller with render settings
        gestureController = GestureController(renderSettings: renderSettings)
    }
}

/// Snapshot of all render settings for single-lock batch reading
/// Use this in the render loop to avoid multiple lock acquisitions per frame
struct SettingsSnapshot {
    let minDistance: Float
    let scale: Float
    let position: SIMD3<Float>
    let fractalScale: Float
    let fractalIterations: Int
    let maxRaySteps: Int
    let foveationIntensity: Float
    let colorMix: Float
    let glowIntensity: Float
    let foldingLimit: Float
    let sphereRadius: Float
    let colorIterations: Float
    let resolutionScale: Float
    let debugEyeTint: Bool
    let tileSize: Int
    let useHierarchical: Bool
    let debugHierarchical: Bool
    let limitFlash: Float
    let sceneIndex: Int
    let ifsScale: Float
    let ifsOffset: Float
    let ifsGlow: Float
}

class RenderSettings {
    private let lock = NSLock()
    private var _minDistance: Float = 0.8           // 80% of max (1.0) for quality
    private var _scale: Float = 1.0
    private var _position: SIMD3<Float> = .zero
    private var _fractalScale: Float = 2.8
    private var _fractalIterations: Int = 4         // Lower = faster (was 5)
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
    
    /// Get a snapshot of all settings with a single lock acquisition
    /// Use this at the start of each frame to avoid repeated lock overhead
    func snapshot() -> SettingsSnapshot {
        lock.withLock {
            SettingsSnapshot(
                minDistance: _minDistance,
                scale: _scale,
                position: _position,
                fractalScale: _fractalScale,
                fractalIterations: _fractalIterations,
                maxRaySteps: _maxRaySteps,
                foveationIntensity: _foveationIntensity,
                colorMix: _colorMix,
                glowIntensity: _glowIntensity,
                foldingLimit: _foldingLimit,
                sphereRadius: _sphereRadius,
                colorIterations: _colorIterations,
                resolutionScale: _resolutionScale,
                debugEyeTint: _debugEyeTint,
                tileSize: _tileSize,
                useHierarchical: _useHierarchical,
                debugHierarchical: _debugHierarchical,
                limitFlash: _limitFlash,
                sceneIndex: _sceneIndex,
                ifsScale: _ifsScale,
                ifsOffset: _ifsOffset,
                ifsGlow: _ifsGlow
            )
        }
    }

    var minDistance: Float {
        get { lock.withLock { _minDistance } }
        set { lock.withLock { _minDistance = newValue } }
    }
    
    var scale: Float {
        get { lock.withLock { _scale } }
        set { lock.withLock { _scale = newValue } }
    }
    
    var position: SIMD3<Float> {
        get { lock.withLock { _position } }
        set { lock.withLock { _position = newValue } }
    }
    
    var fractalScale: Float {
        get { lock.withLock { _fractalScale } }
        set { lock.withLock { _fractalScale = newValue } }
    }
    
    var fractalIterations: Int {
        get { lock.withLock { _fractalIterations } }
        set { lock.withLock { _fractalIterations = newValue } }
    }
    
    var maxRaySteps: Int {
        get { lock.withLock { _maxRaySteps } }
        set { lock.withLock { _maxRaySteps = newValue } }
    }
    
    var foveationIntensity: Float {
        get { lock.withLock { _foveationIntensity } }
        set { lock.withLock { _foveationIntensity = newValue } }
    }
    
    var colorMix: Float {
        get { lock.withLock { _colorMix } }
        set { lock.withLock { _colorMix = newValue } }
    }
    
    var glowIntensity: Float {
        get { lock.withLock { _glowIntensity } }
        set { lock.withLock { _glowIntensity = newValue } }
    }
    
    var foldingLimit: Float {
        get { lock.withLock { _foldingLimit } }
        set { lock.withLock { _foldingLimit = newValue } }
    }
    
    var sphereRadius: Float {
        get { lock.withLock { _sphereRadius } }
        set { lock.withLock { _sphereRadius = newValue } }
    }
    
    var colorIterations: Float {
        get { lock.withLock { _colorIterations } }
        set { lock.withLock { _colorIterations = newValue } }
    }
    
    var resolutionScale: Float {
        get { lock.withLock { _resolutionScale } }
        set { lock.withLock { _resolutionScale = max(0.25, min(1.0, newValue)) } }
    }

    var debugEyeTint: Bool {
        get { lock.withLock { _debugEyeTint } }
        set { lock.withLock { _debugEyeTint = newValue } }
    }
    
    // 0 = disabled (standard per-pixel raymarch)
    // 2 = 2x2 tiles (4x overhead reduction, high quality)
    // 4 = 4x4 tiles (16x overhead reduction, performance mode)
    // 8 = 8x8 adaptive hierarchical (3-8x speedup, best performance)
    var tileSize: Int {
        get { lock.withLock { _tileSize } }
        set { lock.withLock { _tileSize = newValue } }
    }
    
    var useHierarchical: Bool {
        get { lock.withLock { _useHierarchical } }
        set { lock.withLock { _useHierarchical = newValue } }
    }
    
    var debugHierarchical: Bool {
        get { lock.withLock { _debugHierarchical } }
        set { lock.withLock { _debugHierarchical = newValue } }
    }
    
    /// Flash intensity for limit feedback (0-1). Set to 1.0 to trigger flash, decays automatically.
    var limitFlash: Float {
        get { lock.withLock { _limitFlash } }
        set { lock.withLock { _limitFlash = newValue } }
    }
    
    /// Decay the limit flash. Call once per frame.
    func updateLimitFlash(deltaTime: Float) {
        lock.withLock {
            if _limitFlash > 0 {
                _limitFlash = max(0, _limitFlash - deltaTime * 4.0) // Fade over ~0.25s
            }
        }
    }
    
    /// Trigger a limit flash
    func triggerLimitFlash() {
        lock.withLock {
            _limitFlash = 1.0
        }
    }
    
    /// Current scene: 0 = Mandelbox, 1 = Glowy IFS
    var sceneIndex: Int {
        get { lock.withLock { _sceneIndex } }
        set { lock.withLock { _sceneIndex = newValue } }
    }
    
    // IFS Scene parameters
    var ifsScale: Float {
        get { lock.withLock { _ifsScale } }
        set { lock.withLock { _ifsScale = newValue } }
    }
    
    var ifsOffset: Float {
        get { lock.withLock { _ifsOffset } }
        set { lock.withLock { _ifsOffset = newValue } }
    }
    
    var ifsGlow: Float {
        get { lock.withLock { _ifsGlow } }
        set { lock.withLock { _ifsGlow = newValue } }
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
