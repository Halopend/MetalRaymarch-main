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
    // Universal core parameters (work with every fractal type)
    case fractalScale
    case colorMix
    case iterations

    // Universal effect parameters
    case glow
    case fog
    case bloom
    case hueSpeed
    case saturation

    // Dynamic formula-parameter slots — resolve via FormulaCatalog for the active fractal.
    // formulaParam0 maps to the 1st non-bool param, formulaParam1 to the 2nd, etc.
    case formulaParam0
    case formulaParam1
    case formulaParam2

    // Legacy (kept for Codable backward-compat; migrated to formulaParam on load)
    case foldingLimit
    case sphereRadius

    // MARK: - Availability

    /// Cases shown in the UI add-menu. Excludes legacy/deprecated targets.
    static var availableCases: [MusicReactiveTarget] {
        [.fractalScale, .colorMix, .iterations,
         .glow, .fog, .bloom, .hueSpeed, .saturation,
         .formulaParam0, .formulaParam1, .formulaParam2]
    }

    /// Whether this target is a dynamic formula parameter slot.
    var isFormulaParam: Bool {
        switch self {
        case .formulaParam0, .formulaParam1, .formulaParam2: return true
        default: return false
        }
    }

    /// The ordinal slot (0, 1, 2) for formula-param targets; nil otherwise.
    var formulaParamSlot: Int? {
        switch self {
        case .formulaParam0: return 0
        case .formulaParam1: return 1
        case .formulaParam2: return 2
        default: return nil
        }
    }

    /// Returns the catalog descriptor for this formula param slot, for the given fractal type.
    func formulaDescriptor(for fractalType: FractalModelType) -> FormulaParamDescriptor? {
        guard let slot = formulaParamSlot else { return nil }
        let descriptors = Self.floatFormulaParams(for: fractalType)
        guard slot < descriptors.count else { return nil }
        return descriptors[slot]
    }

    /// Migrates legacy Mandelbox-specific targets to their formula-param equivalents.
    var migrated: MusicReactiveTarget {
        switch self {
        case .foldingLimit: return .formulaParam1
        case .sphereRadius: return .formulaParam2
        default: return self
        }
    }

    // MARK: - Static Helpers

    /// Non-bool formula params from the catalog for a given fractal type.
    static func floatFormulaParams(for fractalType: FractalModelType) -> [FormulaParamDescriptor] {
        guard let desc = FormulaCatalog.shared.descriptor(for: fractalType) else { return [] }
        return desc.params.filter { !($0.isBool ?? false) }
    }

    // MARK: - Display Properties (fractal-type-aware)

    func displayName(for fractalType: FractalModelType) -> String {
        if let desc = formulaDescriptor(for: fractalType) {
            return desc.name
        }
        return displayName
    }

    var displayName: String {
        switch self {
        case .fractalScale: return "Fractal Scale"
        case .colorMix: return "Color Mix"
        case .iterations: return "Iterations"
        case .glow: return "Glow"
        case .fog: return "Fog"
        case .bloom: return "Bloom"
        case .hueSpeed: return "Hue Speed"
        case .saturation: return "Saturation"
        case .formulaParam0: return "Formula Param 1"
        case .formulaParam1: return "Formula Param 2"
        case .formulaParam2: return "Formula Param 3"
        case .foldingLimit: return "Folding Limit"
        case .sphereRadius: return "Sphere Radius"
        }
    }

    func icon(for fractalType: FractalModelType) -> String {
        if isFormulaParam, formulaDescriptor(for: fractalType) != nil {
            return "function"
        }
        return icon
    }

    var icon: String {
        switch self {
        case .fractalScale: return "arrow.up.left.and.arrow.down.right"
        case .colorMix: return "paintpalette"
        case .iterations: return "number"
        case .glow: return "sparkles"
        case .fog: return "cloud.fog"
        case .bloom: return "sun.max"
        case .hueSpeed: return "dial.high"
        case .saturation: return "circle.lefthalf.filled"
        case .formulaParam0, .formulaParam1, .formulaParam2: return "function"
        case .foldingLimit: return "square.dashed"
        case .sphereRadius: return "circle.circle"
        }
    }

    // MARK: - Range Properties (fractal-type-aware)

    func allowedRange(for fractalType: FractalModelType) -> ClosedRange<Float> {
        if let desc = formulaDescriptor(for: fractalType) {
            return desc.min...desc.max
        }
        return allowedRange
    }

    var allowedRange: ClosedRange<Float> {
        switch self {
        case .fractalScale: return -5.0...8.0
        case .colorMix: return 0.0...1.0
        case .iterations: return 2.0...24.0
        case .glow: return 0.0...2.0
        case .fog: return 0.0...1.0
        case .bloom: return 0.0...2.0
        case .hueSpeed: return 0.0...0.5
        case .saturation: return 0.0...3.0
        case .formulaParam0, .formulaParam1, .formulaParam2: return -10.0...64.0
        case .foldingLimit: return -10.0...30.0
        case .sphereRadius: return -5.0...8.0
        }
    }

    func defaultRange(for fractalType: FractalModelType) -> ClosedRange<Float> {
        if let desc = formulaDescriptor(for: fractalType) {
            let spread = (desc.max - desc.min) * 0.2
            let lo = max(desc.min, desc.default - spread)
            let hi = min(desc.max, desc.default + spread)
            return lo...hi
        }
        return defaultRange
    }

    var defaultRange: ClosedRange<Float> {
        switch self {
        case .fractalScale: return 2.4...3.4
        case .colorMix: return 0.2...0.9
        case .iterations: return 8.0...12.0
        case .glow: return 0.2...0.9
        case .fog: return 0.05...0.5
        case .bloom: return 0.1...0.8
        case .hueSpeed: return 0.02...0.25
        case .saturation: return 0.8...2.0
        case .formulaParam0, .formulaParam1, .formulaParam2: return 0.0...1.0
        case .foldingLimit: return 0.9...1.35
        case .sphereRadius: return 0.25...0.8
        }
    }

    var defaultSource: MusicReactiveSource {
        switch self {
        case .fractalScale: return .composite
        case .colorMix: return .composite
        case .iterations: return .mid
        case .glow: return .composite
        case .fog: return .composite
        case .bloom: return .beat
        case .hueSpeed: return .treble
        case .saturation: return .mid
        case .formulaParam0: return .bass
        case .formulaParam1: return .mid
        case .formulaParam2: return .treble
        case .foldingLimit: return .bass
        case .sphereRadius: return .mid
        }
    }

    // MARK: - Parameter Target ID (fractal-type-aware)

    /// Returns the parameter system target ID for routing operations.
    /// Formula param targets require the active fractal type to resolve.
    func parameterTargetID(for fractalType: FractalModelType) -> String? {
        if let desc = formulaDescriptor(for: fractalType) {
            return "formula.\(fractalType.rawValue).\(desc.index).\(desc.name)"
        }
        return parameterTargetID
    }

    /// Static target ID — returns nil for formula param targets (they need fractal context).
    var parameterTargetID: String? {
        switch self {
        case .fractalScale: return "core.targetFractalScale"
        case .colorMix: return "core.colorMix"
        case .iterations: return "core.fractalIterations"
        case .glow: return "effect.glow"
        case .fog: return "effect.fog"
        case .bloom: return "effect.bloom"
        case .hueSpeed: return "effect.hueSpeed"
        case .saturation: return "effect.saturation"
        case .formulaParam0, .formulaParam1, .formulaParam2: return nil
        case .foldingLimit: return "formula.0.1.Folding Limit"
        case .sphereRadius: return "formula.0.2.Sphere Radius"
        }
    }

    // MARK: - Default Mapping Factory

    func defaultMapping(for fractalType: FractalModelType, enabled: Bool = true) -> MusicReactiveMapping {
        let range = defaultRange(for: fractalType)
        return MusicReactiveMapping(
            target: self,
            source: defaultSource,
            rangeMin: range.lowerBound,
            rangeMax: range.upperBound,
            responseSpeed: 0.12,
            amount: 1.0,
            isEnabled: enabled
        )
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

    /// Sanitize with fractal-type-aware ranges (for formula params).
    mutating func sanitizeInPlace(for fractalType: FractalModelType) {
        let allowed = target.allowedRange(for: fractalType)
        rangeMin = min(allowed.upperBound, max(allowed.lowerBound, rangeMin))
        rangeMax = min(allowed.upperBound, max(allowed.lowerBound, rangeMax))
        if rangeMin > rangeMax {
            swap(&rangeMin, &rangeMax)
        }
        responseSpeed = max(0.01, min(0.6, responseSpeed))
        amount = max(-2.0, min(2.0, amount))
    }

    /// Default mappings — starts empty. Users add what they want via the + button.
    static func defaultMappings() -> [MusicReactiveMapping] {
        []
    }

    /// Migrate legacy Mandelbox-specific mappings to generic formula param slots.
    static func migrateLegacy(_ mappings: [MusicReactiveMapping]) -> [MusicReactiveMapping] {
        var seen = Set<MusicReactiveTarget>()
        var result: [MusicReactiveMapping] = []
        for var mapping in mappings {
            let newTarget = mapping.target.migrated
            mapping.target = newTarget
            guard seen.insert(newTarget).inserted else { continue }
            result.append(mapping)
        }
        return result
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
    
    /// Which geometry / formula parameters this preset enables
    var geometryProfile: (scale: Bool, param0: Bool, param1: Bool, param2: Bool, colorMix: Bool) {
        switch self {
        case .electronic: return (true,  true,  true,  true,  true )
        case .ambient:    return (true,  false, false, false, true )
        case .rock:       return (true,  true,  true,  false, false)
        case .classical:  return (false, false, false, true,  true )
        case .hiphop:     return (true,  true,  true,  false, false)
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

    /// Build mappings for a specific fractal type — only includes formula param slots
    /// that actually exist for that fractal.
    func defaultMappings(for fractalType: FractalModelType) -> [MusicReactiveMapping] {
        let geometry = geometryProfile
        let effects = effectsProfile
        let formulaCount = MusicReactiveTarget.floatFormulaParams(for: fractalType).count
        var result: [MusicReactiveMapping] = []

        if geometry.scale     { result.append(MusicReactiveTarget.fractalScale.defaultMapping(for: fractalType)) }
        if geometry.param0, formulaCount > 0 { result.append(MusicReactiveTarget.formulaParam0.defaultMapping(for: fractalType)) }
        if geometry.param1, formulaCount > 1 { result.append(MusicReactiveTarget.formulaParam1.defaultMapping(for: fractalType)) }
        if geometry.param2, formulaCount > 2 { result.append(MusicReactiveTarget.formulaParam2.defaultMapping(for: fractalType)) }
        if geometry.colorMix  { result.append(MusicReactiveTarget.colorMix.defaultMapping(for: fractalType)) }
        if effects.glow       { result.append(MusicReactiveTarget.glow.defaultMapping(for: fractalType)) }
        if effects.fog        { result.append(MusicReactiveTarget.fog.defaultMapping(for: fractalType)) }
        if effects.bloom      { result.append(MusicReactiveTarget.bloom.defaultMapping(for: fractalType)) }
        if effects.hueSpeed   { result.append(MusicReactiveTarget.hueSpeed.defaultMapping(for: fractalType)) }
        if effects.saturation { result.append(MusicReactiveTarget.saturation.defaultMapping(for: fractalType)) }
        if effects.iterations { result.append(MusicReactiveTarget.iterations.defaultMapping(for: fractalType)) }

        return result
    }

    /// Fallback that uses Mandelbox as the default fractal (backward compat).
    var defaultMappings: [MusicReactiveMapping] {
        defaultMappings(for: .mandelbox)
    }
}
