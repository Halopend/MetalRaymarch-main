//
//  FractalShareActivity.swift
//  MetalRaymarch
//
//  SharePlay GroupActivity for shared fractal exploration.
//  Allows multiple users to view the same fractal space together.
//

import GroupActivities
import Foundation

/// SharePlay activity for synchronized fractal exploration
struct FractalShareActivity: GroupActivity {
    
    // Unique identifier for this activity type
    static let activityIdentifier = "com.puppypower.MetalRaymarch.shareplay"
    
    // Metadata shown in FaceTime UI
    var metadata: GroupActivityMetadata {
        var meta = GroupActivityMetadata()
        meta.title = "Explore Fractals Together"
        meta.subtitle = "Share your fractal journey"
        meta.type = .generic
        meta.previewImage = nil  // Could add app icon here
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
    let colorScheme: Int32           // ColorScheme raw value
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
    
    /// Initialize from current RenderSettings
    init(from settings: RenderSettings, senderID: UUID) {
        self.position = settings.position
        self.scale = settings.scale
        self.fractalType = settings.fractalType.rawValue
        self.fractalScale = settings.fractalScale
        self.foldingLimit = settings.foldingLimit
        self.sphereRadius = settings.sphereRadius
        self.fractalIterations = settings.fractalIterations
        self.maxRaySteps = settings.maxRaySteps
        self.colorScheme = settings.colorScheme.rawValue
        self.colorMix = settings.colorMix
        self.minDistance = settings.minDistance
        self.safetyBubbleEnabled = settings.safetyBubbleEnabled
        self.safetyBubbleRadius = settings.safetyBubbleRadius
        self.safetyBubbleShape = settings.safetyBubbleShape
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
        if let fractal = FractalType(rawValue: fractalType) {
            settings.fractalType = fractal
        }
        settings.fractalScale = fractalScale
        settings.fractalIterations = fractalIterations
        settings.maxRaySteps = maxRaySteps
        
        // Color - use transitionToColorScheme for animated transitions
        if let scheme = ColorScheme(rawValue: colorScheme) {
            settings.transitionToColorScheme(scheme)
        }
        settings.colorMix = colorMix
        
        // Safety bubble
        settings.safetyBubbleEnabled = safetyBubbleEnabled
        settings.safetyBubbleRadius = safetyBubbleRadius
        settings.safetyBubbleShape = safetyBubbleShape
    }
}
