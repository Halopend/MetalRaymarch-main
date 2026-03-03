//
//  MusicReactiveTypes.swift
//  Threshold
//
//  Shared types for music-reactive parameter modulation.
//  Originally part of SpotifyManager.swift, extracted as service-agnostic types.
//

import Foundation

enum MusicReactiveSource: String, CaseIterable, Codable, Sendable {
    case composite
    case bass
    case mid
    case treble
    case beat
    case overall

    var displayName: String {
        switch self {
        case .composite: return "Composite"
        case .bass: return "Bass"
        case .mid: return "Mid"
        case .treble: return "Treble"
        case .beat: return "Beat"
        case .overall: return "Overall"
        }
    }
}

enum MusicReactiveTarget: String, CaseIterable, Codable, Sendable {
    case fractalScale
    case foldingLimit
    case sphereRadius
    case colorMix
    case glow
    case fog
    case bloom
    case hueSpeed
    case saturation
    case iterations

    var displayName: String {
        switch self {
        case .fractalScale: return "Fractal Scale"
        case .foldingLimit: return "Folding Limit"
        case .sphereRadius: return "Sphere Radius"
        case .colorMix: return "Color Mix"
        case .glow: return "Glow"
        case .fog: return "Fog"
        case .bloom: return "Bloom"
        case .hueSpeed: return "Hue Speed"
        case .saturation: return "Saturation"
        case .iterations: return "Iterations"
        }
    }

    var icon: String {
        switch self {
        case .fractalScale: return "arrow.up.left.and.arrow.down.right"
        case .foldingLimit: return "square.dashed"
        case .sphereRadius: return "circle.circle"
        case .colorMix: return "paintpalette"
        case .glow: return "sparkles"
        case .fog: return "cloud.fog"
        case .bloom: return "sun.max"
        case .hueSpeed: return "dial.high"
        case .saturation: return "circle.lefthalf.filled"
        case .iterations: return "number"
        }
    }

    var allowedRange: ClosedRange<Float> {
        switch self {
        case .fractalScale: return 1.6...5.2
        case .foldingLimit: return -10.0...30.0
        case .sphereRadius: return 0.03...1.2
        case .colorMix: return 0.0...1.0
        case .glow: return 0.0...1.0
        case .fog: return 0.0...1.0
        case .bloom: return 0.0...1.0
        case .hueSpeed: return 0.0...0.5
        case .saturation: return 0.0...3.0
        case .iterations: return 2.0...24.0
        }
    }

    var defaultRange: ClosedRange<Float> {
        switch self {
        case .fractalScale: return 2.4...3.4
        case .foldingLimit: return 0.9...1.35
        case .sphereRadius: return 0.25...0.8
        case .colorMix: return 0.2...0.9
        case .glow: return 0.2...0.9
        case .fog: return 0.05...0.5
        case .bloom: return 0.1...0.8
        case .hueSpeed: return 0.02...0.25
        case .saturation: return 0.8...2.0
        case .iterations: return 8.0...12.0
        }
    }

    var defaultSource: MusicReactiveSource {
        switch self {
        case .fractalScale: return .composite
        case .foldingLimit: return .bass
        case .sphereRadius: return .mid
        case .colorMix: return .composite
        case .glow: return .composite
        case .fog: return .composite
        case .bloom: return .beat
        case .hueSpeed: return .treble
        case .saturation: return .mid
        case .iterations: return .mid
        }
    }

    var parameterTargetID: String? {
        switch self {
        case .fractalScale: return "core.targetFractalScale"
        case .foldingLimit: return "formula.0.1.Folding Limit"
        case .sphereRadius: return "formula.0.2.Sphere Radius"
        case .colorMix: return "core.colorMix"
        case .glow: return "effect.glow"
        case .fog: return "effect.fog"
        case .bloom: return "effect.bloom"
        case .hueSpeed: return "effect.hueSpeed"
        case .saturation: return "effect.saturation"
        case .iterations: return "core.fractalIterations"
        }
    }

    func defaultMapping(enabled: Bool = true) -> MusicReactiveMapping {
        MusicReactiveMapping(
            target: self,
            source: defaultSource,
            rangeMin: defaultRange.lowerBound,
            rangeMax: defaultRange.upperBound,
            responseSpeed: 0.12,
            amount: 1.0,
            isEnabled: enabled
        )
    }
}

struct MusicReactiveMapping: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var target: MusicReactiveTarget
    var source: MusicReactiveSource
    var rangeMin: Float
    var rangeMax: Float
    var responseSpeed: Float
    var amount: Float
    var isEnabled: Bool

    init(id: UUID = UUID(),
         target: MusicReactiveTarget,
         source: MusicReactiveSource,
         rangeMin: Float,
         rangeMax: Float,
         responseSpeed: Float,
         amount: Float,
         isEnabled: Bool) {
        self.id = id
        self.target = target
        self.source = source
        self.rangeMin = rangeMin
        self.rangeMax = rangeMax
        self.responseSpeed = responseSpeed
        self.amount = amount
        self.isEnabled = isEnabled
        sanitizeInPlace()
    }

    mutating func sanitizeInPlace() {
        let allowed = target.allowedRange
        rangeMin = min(allowed.upperBound, max(allowed.lowerBound, rangeMin))
        rangeMax = min(allowed.upperBound, max(allowed.lowerBound, rangeMax))
        if rangeMin > rangeMax {
            swap(&rangeMin, &rangeMax)
        }
        responseSpeed = max(0.01, min(0.6, responseSpeed))
        amount = max(-2.0, min(2.0, amount))
    }

    static func defaultMappings() -> [MusicReactiveMapping] {
        [
            MusicReactiveTarget.fractalScale.defaultMapping(enabled: true),
            MusicReactiveTarget.foldingLimit.defaultMapping(enabled: true),
            MusicReactiveTarget.sphereRadius.defaultMapping(enabled: true),
            MusicReactiveTarget.colorMix.defaultMapping(enabled: true),
            MusicReactiveTarget.glow.defaultMapping(enabled: true),
            MusicReactiveTarget.fog.defaultMapping(enabled: true),
            MusicReactiveTarget.bloom.defaultMapping(enabled: true),
            MusicReactiveTarget.hueSpeed.defaultMapping(enabled: true),
            MusicReactiveTarget.saturation.defaultMapping(enabled: true),
            MusicReactiveTarget.iterations.defaultMapping(enabled: false)
        ]
    }
}

struct MusicReactivePreset: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date
    var audioAmount: Float
    var beatPunch: Float
    var bassSensitivity: Float
    var midSensitivity: Float
    var trebleSensitivity: Float
    var beatSensitivity: Float
    var mappings: [MusicReactiveMapping]

    init(id: UUID = UUID(),
         name: String,
         createdAt: Date = Date(),
         audioAmount: Float,
         beatPunch: Float,
         bassSensitivity: Float,
         midSensitivity: Float,
         trebleSensitivity: Float,
         beatSensitivity: Float,
         mappings: [MusicReactiveMapping]) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.audioAmount = audioAmount
        self.beatPunch = beatPunch
        self.bassSensitivity = bassSensitivity
        self.midSensitivity = midSensitivity
        self.trebleSensitivity = trebleSensitivity
        self.beatSensitivity = beatSensitivity
        self.mappings = mappings
    }
}

/// Genre-optimized reactivity presets.
/// Each preset tunes sensitivity curves and which parameters respond to audio.
enum ReactivityPreset: String, CaseIterable {
    case electronic = "EDM"
    case ambient    = "Ambient"
    case rock       = "Rock"
    case classical  = "Classical"
    case hiphop     = "Hip-Hop"

    var icon: String {
        switch self {
        case .electronic: return "bolt.fill"
        case .ambient:    return "leaf.fill"
        case .rock:       return "flame.fill"
        case .classical:  return "music.note"
        case .hiphop:     return "waveform"
        }
    }

    /// Core sensitivity tuning: (audioAmount, beatPunch, bassSens, midSens, trebleSens, beatSens)
    var settings: (audioAmount: Float, beatPunch: Float, bassSensitivity: Float,
                   midSensitivity: Float, trebleSensitivity: Float, beatSensitivity: Float) {
        switch self {
        case .electronic: return (0.75, 0.85, 1.1, 0.8, 0.9, 1.2)
        case .ambient:    return (0.45, 0.15, 0.6, 0.8, 0.9, 0.3)
        case .rock:       return (0.65, 0.70, 0.9, 1.0, 0.7, 0.8)
        case .classical:  return (0.40, 0.20, 0.5, 0.9, 0.8, 0.3)
        case .hiphop:     return (0.80, 0.90, 1.2, 0.7, 0.5, 1.0)
        }
    }
    
    /// Which geometry parameters this preset enables
    var geometryProfile: (scale: Bool, folding: Bool, radius: Bool, colorMix: Bool) {
        switch self {
        case .electronic: return (true,  true,  true,  true )
        case .ambient:    return (true,  false, false, true )
        case .rock:       return (true,  true,  true,  false)
        case .classical:  return (false, false, true,  true )
        case .hiphop:     return (true,  true,  true,  false)
        }
    }
    
    /// Which effect parameters this preset enables
    var effectsProfile: (glow: Bool, fog: Bool, bloom: Bool, hueSpeed: Bool, saturation: Bool, iterations: Bool) {
        switch self {
        case .electronic: return (true,  true,  true,  true,  false, false)
        case .ambient:    return (false, true,  false, true,  true,  false)
        case .rock:       return (true,  false, true,  false, false, false)
        case .classical:  return (false, true,  false, true,  true,  false)
        case .hiphop:     return (true,  false, true,  false, false, false)
        }
    }

    var defaultMappings: [MusicReactiveMapping] {
        var mappings = MusicReactiveMapping.defaultMappings()
        let geometry = geometryProfile
        let effects = effectsProfile
        for index in mappings.indices {
            switch mappings[index].target {
            case .fractalScale: mappings[index].isEnabled = geometry.scale
            case .foldingLimit: mappings[index].isEnabled = geometry.folding
            case .sphereRadius: mappings[index].isEnabled = geometry.radius
            case .colorMix: mappings[index].isEnabled = geometry.colorMix
            case .glow: mappings[index].isEnabled = effects.glow
            case .fog: mappings[index].isEnabled = effects.fog
            case .bloom: mappings[index].isEnabled = effects.bloom
            case .hueSpeed: mappings[index].isEnabled = effects.hueSpeed
            case .saturation: mappings[index].isEnabled = effects.saturation
            case .iterations: mappings[index].isEnabled = effects.iterations
            }
        }
        return mappings
    }
}
