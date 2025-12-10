//
//  AppModel.swift
//  MetalProject
//
//  Created by MU on 18/11/24.
//

import SwiftUI

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
    
    nonisolated let clock = AppClock()
}

class RenderSettings {
    private let lock = NSLock()
    private var _minDistance: Float = 0.1           // Higher = faster (was 0.05)
    private var _scale: Float = 1.0
    private var _position: SIMD3<Float> = .zero
    private var _fractalScale: Float = 2.8
    private var _fractalIterations: Int = 5         // Lower = faster (was 7)
    private var _maxRaySteps: Int = 48              // Lower = faster (was 64)
    private var _foveationIntensity: Float = 1.5    // Higher = more aggressive foveation
    private var _colorMix: Float = 0.5
    private var _glowIntensity: Float = 0.2
    private var _foldingLimit: Float = 1.0
    private var _sphereRadius: Float = 0.5
    private var _colorIterations: Float = 3.0       // Lower = faster (was 5)

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
