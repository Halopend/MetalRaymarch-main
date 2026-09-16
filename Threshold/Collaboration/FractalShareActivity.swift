//
//  FractalShareActivity.swift
//  com.puppypower.Threshold
//
//  SharePlay GroupActivity for shared fractal exploration.
//  Allows multiple users to view the same fractal space together.
//

import GroupActivities
import Foundation

/// SharePlay activity for synchronized fractal exploration
struct FractalShareActivity: GroupActivity {
    
    // Unique identifier for this activity type
    static let activityIdentifier = "com.puppypower.Threshold.shareplay"
    
    // Metadata shown in FaceTime UI
    var metadata: GroupActivityMetadata {
        var meta = GroupActivityMetadata()
        meta.title = "Explore Fractals Together"
        meta.subtitle = "Share your fractal journey"
        meta.type = .generic
        return meta
    }
}

/// Message sent between participants to sync fractal state
/// Kept minimal for low-latency network transmission (~200 bytes)
struct FractalSyncMessage: Codable, Sendable {
    
    // === CAMERA/POSITION ===
    let position: SIMD3<Float>      // World position in fractal space
    let scale: Float                 // Zoom level
    
    // === FRACTAL PARAMETERS ===
    let fractalType: Int32           // FractalType raw value
    let fractalScale: Float          // Mandelbox scale parameter
    let foldingLimit: Float          // Box folding limit
    let sphereRadius: Float          // Sphere folding radius
    let fractalIterations: Int       // Detail level
    let maxRaySteps: Int             // Ray quality
    
    // === COLOR ===
    let colorMix: Float              // Color mixing factor
    
    // === QUALITY ===
    let minDistance: Float           // Render quality (min ray distance)
    
    // === SAFETY BUBBLE ===
    let safetyBubbleEnabled: Bool
    let safetyBubbleRadius: Float
    let safetyBubbleShape: Float
    
    // === METADATA ===
    let timestamp: TimeInterval      // For ordering/interpolation
    let senderID: UUID               // Identifies message source
    
    /// Initialize from current RenderSettings (4 config snapshots vs 13 individual reads)
    init(from settings: RenderSettings, senderID: UUID) {
        // ── Geometry domain (1 lock) ──
        let geo = settings.geometryConfig
        self.position = geo.position
        self.scale = geo.scale
        self.fractalType = geo.fractalType.rawValue
        self.fractalScale = geo.fractalScale
        self.foldingLimit = geo.foldingLimit
        self.sphereRadius = geo.sphereRadius
        self.minDistance = geo.minDistance

        // ── Quality domain (1 lock) ──
        let qual = settings.qualityConfig
        self.fractalIterations = qual.baseFractalIterations
        self.maxRaySteps = qual.baseMaxRaySteps

        // ── Color domain (1 lock) ──
        self.colorMix = settings.colorConfig.colorMix

        // ── Safety bubble domain (1 lock) ──
        let sb = settings.safetyBubbleConfig
        self.safetyBubbleEnabled = sb.enabled
        self.safetyBubbleRadius = sb.radius
        self.safetyBubbleShape = sb.shape

        self.timestamp = Date().timeIntervalSince1970
        self.senderID = senderID
    }
    
    /// Apply this message's state to RenderSettings (for receiving participants)
    func apply(to settings: RenderSettings) {
        // SharePlay delivers any participant's message verbatim — a malicious
        // or buggy peer must not be able to wedge the GPU (maxRaySteps = 1e9
        // marches effectively forever → watchdog kill, and each distinct
        // resolution minted a fresh pipeline) or poison the smooth-damp
        // camera state with NaN/Inf. Mirror the file-decode contract BEFORE
        // any write: finite values only, clamped to the engine's ranges.
        let finiteMinDistance = Self.sanitized(minDistance, in: -5.0...15.0, fallback: 0.8)
        let finiteFoldingLimit = Self.sanitized(foldingLimit, in: -10.0...30.0, fallback: 1.0)
        let finiteSphereRadius = Self.sanitized(sphereRadius, in: -5.0...8.0, fallback: 0.5)
        let finiteScale = Self.sanitized(scale, in: 1e-3...1e3, fallback: 1.0)
        let finiteFractalScale = Self.sanitized(fractalScale, in: ControlCatalog.fractalScale.range, fallback: ControlCatalog.fractalScale.defaultValue)
        let finiteColorMix = Self.sanitized(colorMix, in: ControlCatalog.colorMix.range, fallback: ControlCatalog.colorMix.defaultValue)
        let finitePosition = SIMD3<Float>(
            Self.sanitized(position.x, in: -1e3...1e3, fallback: 0),
            Self.sanitized(position.y, in: -1e3...1e3, fallback: 0),
            Self.sanitized(position.z, in: -1e3...1e3, fallback: 0))
        let iterationsClamped = max(ControlCatalog.iterations.integerRange.lowerBound,
                                    min(ControlCatalog.iterations.integerRange.upperBound, fractalIterations))
        // The single most expensive knob: unclamped, a peer could set 1e9
        // (GPU marches forever → watchdog kill) and every distinct value
        // minted a new specialized pipeline (cache-key churn DoS).
        let rayStepsClamped = max(ControlCatalog.maxRaySteps.integerRange.lowerBound,
                                  min(ControlCatalog.maxRaySteps.integerRange.upperBound, maxRaySteps))
        let finiteBubbleRadius = Self.sanitized(safetyBubbleRadius, in: ControlCatalog.safetyBubbleRadius.range, fallback: ControlCatalog.safetyBubbleRadius.defaultValue)
        let finiteBubbleShape = Self.sanitized(safetyBubbleShape, in: 0.0...SafetyBubbleShapePreset.maxStoredValue, fallback: 0.0)

        // Remote collaboration is another scene-origin mutation source: update
        // the live view without turning the peer's stream into local preferences.
        // It follows the shared-scene comfort rule as well — peers may opt a
        // bubble on, but may not remotely disable an already-enabled bubble.
        settings.withPersistenceSuppressed {
            // Set targets for smooth interpolation using the setTargets method
            settings.setTargets(
                minDistance: finiteMinDistance,
                foldingLimit: finiteFoldingLimit,
                sphereRadius: finiteSphereRadius,
                position: finitePosition
            )
            settings.scale = finiteScale

            // Fractal parameters
            if let fractalModel = FractalModelType(rawValue: fractalType) {
                settings.fractalType = fractalModel
            }
            settings.fractalScale = finiteFractalScale
            settings.targetFractalScale = finiteFractalScale
            settings.fractalIterations = iterationsClamped
            settings.maxRaySteps = rayStepsClamped

            // Color
            settings.colorMix = finiteColorMix

            // Safety bubble
            if safetyBubbleEnabled {
                settings.safetyBubbleEnabled = true
                settings.safetyBubbleRadius = finiteBubbleRadius
                settings.safetyBubbleShape = finiteBubbleShape
            }
        }
    }

    /// Clamp a peer-supplied scalar into a safe range; non-finite values fall
    /// back to the field's default rather than propagating NaN/Inf into the
    /// render state.
    private static func sanitized(_ v: Float, in range: ClosedRange<Float>, fallback: Float) -> Float {
        guard v.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, v))
    }
}
