//
//  MusicReactiveTypes.swift
//  Threshold
//
//  Shared types for music-reactive parameter modulation.
//  Originally part of SpotifyManager.swift, extracted as service-agnostic types.
//

import Foundation

enum MusicReactiveMode: String, Codable, Sendable {
    case absolute
    case relative

    static let allCases: [MusicReactiveMode] = [.relative]

    var displayName: String {
        switch self {
        case .absolute: return "Relative"
        case .relative: return "Relative"
        }
    }

    var helpText: String {
        switch self {
        case .absolute: return "Legacy mappings are migrated to relative modulation around the current base value"
        case .relative: return "Music adds a delta around the current animation or manual base value"
        }
    }

    var runtimeMode: MusicReactiveMode {
        switch self {
        case .absolute: return .relative
        case .relative: return .relative
        }
    }
}

enum LFOShape: String, CaseIterable, Codable, Sendable {
    case sine
    case triangle
    case square
    case sawtooth

    var displayName: String {
        switch self {
        case .sine: return "Sine"
        case .triangle: return "Triangle"
        case .square: return "Square"
        case .sawtooth: return "Sawtooth"
        }
    }

    var icon: String {
        switch self {
        case .sine: return "waveform.path"
        case .triangle: return "triangle"
        case .square: return "square"
        case .sawtooth: return "chart.line.uptrend.xyaxis"
        }
    }

    func evaluate(phase: Float) -> Float {
        let p = phase - floor(phase)
        switch self {
        case .sine:
            return sin(p * 2.0 * .pi)
        case .triangle:
            return p < 0.5 ? (4.0 * p - 1.0) : (3.0 - 4.0 * p)
        case .square:
            return p < 0.5 ? 1.0 : -1.0
        case .sawtooth:
            return 2.0 * p - 1.0
        }
    }
}

struct LFOSettings: Codable, Hashable, Sendable {
    var enabled: Bool = false
    var frequency: Float = 0.1
    var amplitude: Float = 0.2
    var shape: LFOShape = .sine

    mutating func sanitizeInPlace() {
        frequency = max(0.01, min(5.0, frequency))
        amplitude = max(0.0, min(1.0, amplitude))
    }

    static let `default` = LFOSettings()
}

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
    case formulaParam3

    // Legacy (kept for Codable backward-compat; migrated to formulaParam on load)
    case foldingLimit
    case sphereRadius

    // MARK: - Availability

    /// Cases shown in the UI add-menu. Excludes legacy/deprecated targets.
    static var availableCases: [MusicReactiveTarget] {
        [.fractalScale, .colorMix, .iterations,
         .glow, .fog, .bloom, .hueSpeed, .saturation,
         .formulaParam0, .formulaParam1, .formulaParam2, .formulaParam3]
    }

    /// Whether this target is a dynamic formula parameter slot.
    var isFormulaParam: Bool {
        switch self {
        case .formulaParam0, .formulaParam1, .formulaParam2, .formulaParam3: return true
        default: return false
        }
    }

    /// The ordinal slot (0, 1, 2) for formula-param targets; nil otherwise.
    var formulaParamSlot: Int? {
        switch self {
        case .formulaParam0: return 0
        case .formulaParam1: return 1
        case .formulaParam2: return 2
        case .formulaParam3: return 3
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
        case .formulaParam3: return "Formula Param 4"
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
        case .formulaParam0, .formulaParam1, .formulaParam2, .formulaParam3: return "function"
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
        case .formulaParam0, .formulaParam1, .formulaParam2, .formulaParam3: return -10.0...64.0
        case .foldingLimit: return -10.0...30.0
        case .sphereRadius: return -5.0...8.0
        }
    }

    func defaultRange(for fractalType: FractalModelType) -> ClosedRange<Float> {
        if let desc = formulaDescriptor(for: fractalType) {
            // Mandelbulb PolarRotation is most useful around +Y alignment.
            if fractalType == .mandelbulb, desc.name == "PolarRotation" {
                let center = Float.pi * 0.5
                return (center - 0.5)...(center + 0.5)
            }
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
        case .formulaParam0, .formulaParam1, .formulaParam2, .formulaParam3: return 0.0...1.0
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
        case .formulaParam3: return .mid
        case .foldingLimit: return .bass
        case .sphereRadius: return .mid
        }
    }

    // MARK: - Parameter Target ID (fractal-type-aware)

    /// Returns the parameter system target ID for routing operations.
    /// Formula param targets require the active fractal type to resolve.
    func parameterTargetID(for fractalType: FractalModelType) -> String? {
        if let desc = formulaDescriptor(for: fractalType) {
            return ParameterTargetID.formula(fractalType: fractalType, formulaIndex: desc.index, name: desc.name)
        }
        return parameterTargetID
    }

    /// Static target ID — returns nil for formula param targets (they need fractal context).
    var parameterTargetID: String? {
        switch self {
        case .fractalScale: return ParameterTargetID.Core.fractalScale
        case .colorMix: return ParameterTargetID.Core.colorMix
        case .iterations: return ParameterTargetID.Core.iterations
        case .glow: return ParameterTargetID.Effect.glow
        case .fog: return ParameterTargetID.Effect.fog
        case .bloom: return ParameterTargetID.Effect.bloom
        case .hueSpeed: return ParameterTargetID.Effect.hueSpeed
        case .saturation: return ParameterTargetID.Effect.saturation
        case .formulaParam0, .formulaParam1, .formulaParam2, .formulaParam3: return nil
        case .foldingLimit: return ParameterTargetID.formula(fractalType: .mandelbox, formulaIndex: 1, name: "Folding Limit")
        case .sphereRadius: return ParameterTargetID.formula(fractalType: .mandelbox, formulaIndex: 2, name: "Sphere Radius")
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
    var mode: MusicReactiveMode
    var lfo: LFOSettings
    var smoothingWindow: Float

    init(id: UUID = UUID(),
         target: MusicReactiveTarget,
         source: MusicReactiveSource,
         rangeMin: Float,
         rangeMax: Float,
         responseSpeed: Float,
         amount: Float,
         isEnabled: Bool,
         mode: MusicReactiveMode = .relative,
         lfo: LFOSettings = .default,
         smoothingWindow: Float = 0.0) {
        self.id = id
        self.target = target
        self.source = source
        self.rangeMin = rangeMin
        self.rangeMax = rangeMax
        self.responseSpeed = responseSpeed
        self.amount = amount
        self.isEnabled = isEnabled
        self.mode = mode
        self.lfo = lfo
        self.smoothingWindow = smoothingWindow
        sanitizeInPlace()
    }

    mutating func sanitizeInPlace() {
        mode = mode.runtimeMode
        let allowed = target.allowedRange
        rangeMin = min(allowed.upperBound, max(allowed.lowerBound, rangeMin))
        rangeMax = min(allowed.upperBound, max(allowed.lowerBound, rangeMax))
        if rangeMin > rangeMax {
            swap(&rangeMin, &rangeMax)
        }
        responseSpeed = max(0.01, min(1.0, responseSpeed))
        amount = max(-3.0, min(3.0, amount))
        smoothingWindow = max(0.0, min(2.0, smoothingWindow))
        lfo.sanitizeInPlace()
    }

    /// Sanitize with fractal-type-aware ranges (for formula params).
    mutating func sanitizeInPlace(for fractalType: FractalModelType) {
        mode = mode.runtimeMode
        let allowed = target.allowedRange(for: fractalType)
        rangeMin = min(allowed.upperBound, max(allowed.lowerBound, rangeMin))
        rangeMax = min(allowed.upperBound, max(allowed.lowerBound, rangeMax))
        if rangeMin > rangeMax {
            swap(&rangeMin, &rangeMax)
        }
        responseSpeed = max(0.01, min(1.0, responseSpeed))
        amount = max(-3.0, min(3.0, amount))
        smoothingWindow = max(0.0, min(2.0, smoothingWindow))
        lfo.sanitizeInPlace()
    }

    /// Default mappings — starts empty. Users add what they want via the + button.
    static func defaultMappings() -> [MusicReactiveMapping] {
        []
    }

    // MARK: - Backward-compatible Codable

    enum CodingKeys: String, CodingKey {
        case id, target, source, rangeMin, rangeMax, responseSpeed, amount, isEnabled
        case mode, lfo, smoothingWindow
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.target = try c.decode(MusicReactiveTarget.self, forKey: .target)
        self.source = try c.decode(MusicReactiveSource.self, forKey: .source)
        self.rangeMin = try c.decode(Float.self, forKey: .rangeMin)
        self.rangeMax = try c.decode(Float.self, forKey: .rangeMax)
        self.responseSpeed = try c.decode(Float.self, forKey: .responseSpeed)
        self.amount = try c.decode(Float.self, forKey: .amount)
        self.isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        self.mode = (try c.decodeIfPresent(MusicReactiveMode.self, forKey: .mode) ?? .relative).runtimeMode
        self.lfo = try c.decodeIfPresent(LFOSettings.self, forKey: .lfo) ?? .default
        self.smoothingWindow = try c.decodeIfPresent(Float.self, forKey: .smoothingWindow) ?? 0.0
    }

    /// Migrate legacy Mandelbox-specific mappings to generic formula param slots.
    static func migrateLegacy(_ mappings: [MusicReactiveMapping]) -> [MusicReactiveMapping] {
        var seen = Set<MusicReactiveTarget>()
        var result: [MusicReactiveMapping] = []
        for var mapping in mappings {
            let newTarget = mapping.target.migrated
            mapping.target = newTarget
            mapping.mode = mapping.mode.runtimeMode
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
    var geometryProfile: (scale: Bool, param0: Bool, param1: Bool, param2: Bool, param3: Bool, colorMix: Bool) {
        switch self {
        case .electronic: return (true,  true,  true,  true,  false, true )
        case .ambient:    return (true,  false, false, false, false, true )
        case .rock:       return (true,  true,  true,  false, false, false)
        case .classical:  return (false, false, false, true,  false, true )
        case .hiphop:     return (true,  true,  true,  false, false, false)
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
        if geometry.param3, formulaCount > 3 { result.append(MusicReactiveTarget.formulaParam3.defaultMapping(for: fractalType)) }
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
