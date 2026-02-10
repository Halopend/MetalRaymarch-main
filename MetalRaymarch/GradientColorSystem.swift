//
//  GradientColorSystem.swift
//  MetalRaymarch
//
//  Replaces hardcoded palettes with a user-editable gradient system.
//  Inspired by GMT-fractals' dual-layer gradient with multiple mapping modes.
//
//  Each gradient has up to 8 color stops at arbitrary positions (0-1).
//  The gradient is sampled using different mapping modes (orbit trap, iteration,
//  depth, angle, normal) to produce the final fractal color.
//

import Foundation
import simd

// MARK: - Gradient Stop

/// A single color stop in a gradient, with position and color.
struct GradientStop: Codable, Identifiable, Equatable {
    let id: UUID
    var position: Float   // 0.0 - 1.0, where it sits in the gradient
    var color: SIMD3<Float>  // RGB, 0-1 range
    
    init(position: Float, color: SIMD3<Float>) {
        self.id = UUID()
        self.position = simd_clamp(position, 0, 1)
        self.color = color
    }
    
    init(position: Float, r: Float, g: Float, b: Float) {
        self.init(position: position, color: SIMD3<Float>(r, g, b))
    }
}

// MARK: - Color Mapping Mode

/// How the gradient is sampled from the fractal's orbit data.
/// Each mode produces a different visual interpretation of the fractal geometry.
enum ColorMappingMode: Int, Codable, CaseIterable {
    case orbitTrap    = 0  // Distance to orbit trap (default, classic look)
    case iterations   = 1  // Normalized iteration count
    case zDepth       = 2  // Distance from camera (depth-based)
    case angle        = 3  // Angle of trap position (polar coloring)
    case normal       = 4  // Surface normal direction
    case blended      = 5  // Mix of orbit trap + iteration (smooth blending)
    
    var displayName: String {
        switch self {
        case .orbitTrap:  return "Orbit Trap"
        case .iterations: return "Iterations"
        case .zDepth:     return "Z-Depth"
        case .angle:      return "Angle"
        case .normal:     return "Normal"
        case .blended:    return "Blended"
        }
    }
    
    var icon: String {
        switch self {
        case .orbitTrap:  return "target"
        case .iterations: return "repeat"
        case .zDepth:     return "arrow.up.and.down"
        case .angle:      return "angle"
        case .normal:     return "arrow.up.right"
        case .blended:    return "circle.lefthalf.filled"
        }
    }
}

// MARK: - Gradient Color Map

/// A complete gradient definition: sorted color stops + mapping mode.
struct GradientColorMap: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var stops: [GradientStop]
    var mappingMode: ColorMappingMode
    var repeatCount: Float    // How many times the gradient repeats (1.0 = once)
    var offset: Float         // Shifts the gradient start point (0-1)
    var smoothing: Float      // 0 = sharp transitions, 1 = smooth (default 1.0)
    
    init(name: String, stops: [GradientStop], mappingMode: ColorMappingMode = .orbitTrap,
         repeatCount: Float = 1.0, offset: Float = 0.0, smoothing: Float = 1.0) {
        self.id = UUID()
        self.name = name
        self.stops = stops.sorted { $0.position < $1.position }
        self.mappingMode = mappingMode
        self.repeatCount = repeatCount
        self.offset = offset
        self.smoothing = smoothing
    }
    
    /// Sort stops by position
    mutating func sortStops() {
        stops.sort { $0.position < $1.position }
    }
    
    /// Evaluate gradient at position t (0-1), applying repeat and offset
    func evaluate(at t: Float) -> SIMD3<Float> {
        guard !stops.isEmpty else { return SIMD3<Float>(1, 1, 1) }
        guard stops.count > 1 else { return stops[0].color }
        
        // Apply repeat and offset
        var mapped = fract(t * repeatCount + offset)
        
        // Find surrounding stops
        var lower = stops[0]
        var upper = stops[stops.count - 1]
        
        for i in 0..<(stops.count - 1) {
            if mapped >= stops[i].position && mapped <= stops[i + 1].position {
                lower = stops[i]
                upper = stops[i + 1]
                break
            }
        }
        
        // Interpolate
        let range = upper.position - lower.position
        guard range > 0 else { return lower.color }
        let localT = (mapped - lower.position) / range
        
        // Apply smoothstep for smoother transitions
        let smoothT = smoothing > 0 ? smoothstep(localT) * smoothing + localT * (1 - smoothing) : localT
        
        return simd_mix(lower.color, upper.color, SIMD3<Float>(repeating: smoothT))
    }
    
    /// Convert to shader-compatible stop arrays (colors + positions, padded to MAX_GRADIENT_STOPS)
    func toShaderStops() -> (colors: [SIMD4<Float>], count: Int) {
        let maxStops = 8
        var colors: [SIMD4<Float>] = Array(repeating: SIMD4<Float>(0, 0, 0, 0), count: maxStops)
        
        let sorted = stops.sorted { $0.position < $1.position }
        let count = min(sorted.count, maxStops)
        
        for i in 0..<count {
            // Pack color (xyz) + position (w) into a single float4
            colors[i] = SIMD4<Float>(sorted[i].color.x, sorted[i].color.y, sorted[i].color.z, sorted[i].position)
        }
        
        return (colors, count)
    }
    
    private func fract(_ x: Float) -> Float {
        return x - floor(x)
    }
    
    private func smoothstep(_ x: Float) -> Float {
        let t = simd_clamp(x, 0, 1)
        return t * t * (3 - 2 * t)
    }
}

// MARK: - Gradient Presets

/// Factory for built-in gradient presets that replace the old hardcoded ColorScheme palettes.
/// Users can start from these and customize, or create from scratch.
enum GradientPreset: String, CaseIterable, Codable {
    case classic
    case ocean
    case fire
    case forest
    case nebula
    case mono
    case aurora
    case volcanic
    case neonCyber
    case neonSunset
    case neonMatrix
    case rainbow
    case infrared
    case twilight
    
    var displayName: String {
        switch self {
        case .classic:    return "Classic"
        case .ocean:      return "Ocean"
        case .fire:       return "Fire"
        case .forest:     return "Forest"
        case .nebula:     return "Nebula"
        case .mono:       return "Mono"
        case .aurora:     return "Aurora"
        case .volcanic:   return "Volcanic"
        case .neonCyber:  return "Neon Cyber"
        case .neonSunset: return "Neon Sunset"
        case .neonMatrix: return "Neon Matrix"
        case .rainbow:    return "Rainbow"
        case .infrared:   return "Infrared"
        case .twilight:   return "Twilight"
        }
    }
    
    var icon: String {
        switch self {
        case .classic:    return "paintpalette"
        case .ocean:      return "water.waves"
        case .fire:       return "flame"
        case .forest:     return "leaf"
        case .nebula:     return "sparkles"
        case .mono:       return "circle.lefthalf.filled"
        case .aurora:     return "rainbow"
        case .volcanic:   return "mountain.2"
        case .neonCyber:  return "bolt.circle.fill"
        case .neonSunset: return "sun.horizon.fill"
        case .neonMatrix: return "chevron.left.forwardslash.chevron.right"
        case .rainbow:    return "rainbow"
        case .infrared:   return "thermometer.high"
        case .twilight:   return "moon.stars"
        }
    }
    
    /// Whether this preset should enable neon mode in the shader
    var isNeonMode: Bool {
        switch self {
        case .neonCyber, .neonSunset, .neonMatrix: return true
        default: return false
        }
    }
    
    /// Suggested post-processing for this preset
    var postProcessing: (saturation: Float, contrast: Float, gamma: Float) {
        switch self {
        case .classic:    return (2.0, 1.15, 0.45)
        case .ocean:      return (1.8, 1.12, 0.48)
        case .fire:       return (2.2, 1.2, 0.42)
        case .forest:     return (1.8, 1.1, 0.5)
        case .nebula:     return (2.3, 1.15, 0.42)
        case .mono:       return (0.6, 1.3, 0.46)
        case .aurora:     return (2.5, 1.15, 0.4)
        case .volcanic:   return (2.0, 1.35, 0.38)
        case .neonCyber:  return (2.8, 1.2, 0.38)
        case .neonSunset: return (2.6, 1.25, 0.4)
        case .neonMatrix: return (3.0, 1.4, 0.35)
        case .rainbow:    return (2.0, 1.1, 0.45)
        case .infrared:   return (1.5, 1.3, 0.4)
        case .twilight:   return (1.8, 1.15, 0.45)
        }
    }
    
    /// Neon mode parameters for neon presets
    var neonParams: (hueFreq: Float, hueOffset: Float, bandFreq: Float, stripeFreq: Float,
                     stripeStrength: Float, glowSharpness: Float, satPower: Float) {
        switch self {
        case .neonCyber:  return (1.5, 0.0, 3.0, 0.0, 0.0, 4.0, 0.2)
        case .neonSunset: return (2.0, 0.33, 0.0, 0.0, 0.0, 2.5, 0.25)
        case .neonMatrix: return (0.5, 0.0, 6.0, 0.0, 0.0, 5.0, 0.15)
        default:          return (1.5, 0.0, 2.0, 0.0, 0.0, 3.0, 0.3)
        }
    }
    
    /// Create the gradient color map for this preset
    func makeGradient() -> GradientColorMap {
        switch self {
        case .classic:
            return GradientColorMap(name: "Classic", stops: [
                GradientStop(position: 0.0,  r: 0.05, g: 0.02, b: 0.02),
                GradientStop(position: 0.25, r: 1.0,  g: 0.1,  b: 0.1),
                GradientStop(position: 0.5,  r: 0.2,  g: 0.4,  b: 0.9),
                GradientStop(position: 0.75, r: 1.0,  g: 0.8,  b: 0.0),
                GradientStop(position: 1.0,  r: 0.0,  g: 0.2,  b: 0.8),
            ])
        case .ocean:
            return GradientColorMap(name: "Ocean", stops: [
                GradientStop(position: 0.0,  r: 0.0,  g: 0.05, b: 0.15),
                GradientStop(position: 0.3,  r: 0.0,  g: 0.3,  b: 1.0),
                GradientStop(position: 0.6,  r: 0.0,  g: 0.9,  b: 0.8),
                GradientStop(position: 1.0,  r: 0.4,  g: 1.0,  b: 1.0),
            ])
        case .fire:
            return GradientColorMap(name: "Fire", stops: [
                GradientStop(position: 0.0,  r: 0.1,  g: 0.0,  b: 0.0),
                GradientStop(position: 0.25, r: 0.8,  g: 0.1,  b: 0.0),
                GradientStop(position: 0.5,  r: 1.0,  g: 0.4,  b: 0.0),
                GradientStop(position: 0.75, r: 1.0,  g: 0.8,  b: 0.1),
                GradientStop(position: 1.0,  r: 1.0,  g: 1.0,  b: 0.5),
            ])
        case .forest:
            return GradientColorMap(name: "Forest", stops: [
                GradientStop(position: 0.0,  r: 0.05, g: 0.1,  b: 0.02),
                GradientStop(position: 0.3,  r: 0.1,  g: 0.8,  b: 0.2),
                GradientStop(position: 0.6,  r: 0.6,  g: 0.4,  b: 0.1),
                GradientStop(position: 1.0,  r: 0.8,  g: 1.0,  b: 0.2),
            ])
        case .nebula:
            return GradientColorMap(name: "Nebula", stops: [
                GradientStop(position: 0.0,  r: 0.05, g: 0.0,  b: 0.1),
                GradientStop(position: 0.25, r: 0.6,  g: 0.0,  b: 1.0),
                GradientStop(position: 0.5,  r: 1.0,  g: 0.2,  b: 0.6),
                GradientStop(position: 0.75, r: 0.2,  g: 0.6,  b: 1.0),
                GradientStop(position: 1.0,  r: 0.8,  g: 0.1,  b: 0.9),
            ])
        case .mono:
            return GradientColorMap(name: "Mono", stops: [
                GradientStop(position: 0.0,  r: 0.02, g: 0.02, b: 0.03),
                GradientStop(position: 0.5,  r: 0.5,  g: 0.5,  b: 0.55),
                GradientStop(position: 1.0,  r: 1.0,  g: 1.0,  b: 0.95),
            ])
        case .aurora:
            return GradientColorMap(name: "Aurora", stops: [
                GradientStop(position: 0.0,  r: 0.0,  g: 0.1,  b: 0.05),
                GradientStop(position: 0.25, r: 0.0,  g: 1.0,  b: 0.4),
                GradientStop(position: 0.5,  r: 0.0,  g: 0.6,  b: 1.0),
                GradientStop(position: 0.75, r: 0.8,  g: 0.2,  b: 1.0),
                GradientStop(position: 1.0,  r: 0.0,  g: 0.9,  b: 0.7),
            ])
        case .volcanic:
            return GradientColorMap(name: "Volcanic", stops: [
                GradientStop(position: 0.0,  r: 0.02, g: 0.01, b: 0.01),
                GradientStop(position: 0.3,  r: 0.05, g: 0.02, b: 0.02),
                GradientStop(position: 0.6,  r: 1.0,  g: 0.3,  b: 0.0),
                GradientStop(position: 0.85, r: 1.0,  g: 0.8,  b: 0.1),
                GradientStop(position: 1.0,  r: 0.8,  g: 0.1,  b: 0.0),
            ])
        case .neonCyber:
            return GradientColorMap(name: "Neon Cyber", stops: [
                GradientStop(position: 0.0,  r: 0.1,  g: 0.0,  b: 0.15),
                GradientStop(position: 0.33, r: 1.0,  g: 0.0,  b: 0.6),
                GradientStop(position: 0.66, r: 0.0,  g: 1.0,  b: 1.0),
                GradientStop(position: 1.0,  r: 0.6,  g: 0.0,  b: 1.0),
            ])
        case .neonSunset:
            return GradientColorMap(name: "Neon Sunset", stops: [
                GradientStop(position: 0.0,  r: 0.15, g: 0.0,  b: 0.1),
                GradientStop(position: 0.33, r: 1.0,  g: 0.4,  b: 0.0),
                GradientStop(position: 0.66, r: 1.0,  g: 0.0,  b: 0.5),
                GradientStop(position: 1.0,  r: 0.5,  g: 0.0,  b: 1.0),
            ])
        case .neonMatrix:
            return GradientColorMap(name: "Neon Matrix", stops: [
                GradientStop(position: 0.0,  r: 0.0,  g: 0.05, b: 0.0),
                GradientStop(position: 0.33, r: 0.0,  g: 1.0,  b: 0.0),
                GradientStop(position: 0.66, r: 0.0,  g: 0.6,  b: 0.2),
                GradientStop(position: 1.0,  r: 0.5,  g: 1.0,  b: 0.5),
            ])
        case .rainbow:
            return GradientColorMap(name: "Rainbow", stops: [
                GradientStop(position: 0.0,   r: 1.0, g: 0.0, b: 0.0),
                GradientStop(position: 0.167, r: 1.0, g: 0.5, b: 0.0),
                GradientStop(position: 0.333, r: 1.0, g: 1.0, b: 0.0),
                GradientStop(position: 0.5,   r: 0.0, g: 1.0, b: 0.0),
                GradientStop(position: 0.667, r: 0.0, g: 0.5, b: 1.0),
                GradientStop(position: 0.833, r: 0.5, g: 0.0, b: 1.0),
                GradientStop(position: 1.0,   r: 1.0, g: 0.0, b: 0.5),
            ])
        case .infrared:
            return GradientColorMap(name: "Infrared", stops: [
                GradientStop(position: 0.0,  r: 0.0,  g: 0.0,  b: 0.0),
                GradientStop(position: 0.25, r: 0.2,  g: 0.0,  b: 0.5),
                GradientStop(position: 0.5,  r: 1.0,  g: 0.0,  b: 0.0),
                GradientStop(position: 0.75, r: 1.0,  g: 0.8,  b: 0.0),
                GradientStop(position: 1.0,  r: 1.0,  g: 1.0,  b: 1.0),
            ])
        case .twilight:
            return GradientColorMap(name: "Twilight", stops: [
                GradientStop(position: 0.0,  r: 0.0,  g: 0.0,  b: 0.1),
                GradientStop(position: 0.3,  r: 0.2,  g: 0.1,  b: 0.5),
                GradientStop(position: 0.5,  r: 0.8,  g: 0.3,  b: 0.4),
                GradientStop(position: 0.7,  r: 1.0,  g: 0.6,  b: 0.2),
                GradientStop(position: 1.0,  r: 1.0,  g: 0.9,  b: 0.5),
            ])
        }
    }
    
    /// Get the matching old ColorScheme for backward compatibility during transition
    var legacyColorScheme: ColorScheme? {
        switch self {
        case .classic:    return .classic
        case .ocean:      return .ocean
        case .fire:       return .fire
        case .forest:     return .forest
        case .nebula:     return .nebula
        case .mono:       return .mono
        case .aurora:     return .aurora
        case .volcanic:   return .volcanic
        case .neonCyber:  return .neonCyber
        case .neonSunset: return .neonSunset
        case .neonMatrix: return .neonMatrix
        default:          return nil
        }
    }
}

// MARK: - Gradient Manager

/// Manages the active gradient and provides shader-ready data.
/// Owned by RenderSettings for thread-safe access.
struct GradientState: Codable, Equatable {
    var gradient: GradientColorMap
    var useGradientColoring: Bool    // true = new gradient system, false = legacy palette
    var gradientPreset: GradientPreset?  // Which preset this came from (nil if custom)
    
    init() {
        self.gradient = GradientPreset.nebula.makeGradient()
        self.useGradientColoring = false  // Start with legacy mode for backward compat
        self.gradientPreset = .nebula
    }
    
    init(preset: GradientPreset) {
        self.gradient = preset.makeGradient()
        self.useGradientColoring = true
        self.gradientPreset = preset
    }
    
    /// Apply a preset, replacing the current gradient
    mutating func applyPreset(_ preset: GradientPreset) {
        gradient = preset.makeGradient()
        gradientPreset = preset
    }
    
    /// Mark as custom (when user edits stops)
    mutating func markAsCustom() {
        gradientPreset = nil
    }
}
