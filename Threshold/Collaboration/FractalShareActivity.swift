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
        // Set targets for smooth interpolation using the setTargets method
        settings.setTargets(
            minDistance: minDistance,
            foldingLimit: foldingLimit,
            sphereRadius: sphereRadius,
            position: position
        )
        settings.scale = scale
        
        // Fractal parameters
        if let fractalModel = FractalModelType(rawValue: fractalType) {
            settings.fractalType = fractalModel
        }
        settings.fractalScale = fractalScale
        settings.targetFractalScale = fractalScale
        settings.fractalIterations = fractalIterations
        settings.maxRaySteps = maxRaySteps
        
        // Color
        settings.colorMix = colorMix
        
        // Safety bubble
        settings.safetyBubbleEnabled = safetyBubbleEnabled
        settings.safetyBubbleRadius = safetyBubbleRadius
        settings.safetyBubbleShape = safetyBubbleShape
    }
}
