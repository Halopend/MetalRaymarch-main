//
//  MusicReactiveTypes.swift
//  Threshold
//
//  Shared types for music-reactive parameter modulation.
//  Originally part of SpotifyManager.swift, extracted as service-agnostic types.
//

import Foundation

/// How audio energy shapes the parameter offset.
/// Each curve produces a different delta shape from the same source level (0–1).
enum ResponseCurve: String, CaseIterable, Codable, Sendable {
    /// "Wave" — smooth continuous oscillation around the base value; louder
    /// audio swings wider and faster. The "alive / breathing" shape.
    case sinusoidal
    /// "Pulse" — fast attack, exponential decay: a sharp spike that fades. Pair
    /// with the Drop source for a snap on each big hit.
    case pulse
    /// "Follow" — smoothly tracks the source with lag; a gentle wander that
    /// never jumps. The "ambient / slow color drift" shape.
    /// (rawValue stays `drift` for back-compat.)
    case drift
    /// "Living" — a Wave oscillation riding on a slow Follow; movement + drift
    /// at once. (rawValue stays `hybrid` for back-compat.)
    case hybrid

    var displayName: String {
        switch self {
        case .sinusoidal: return "Wave"
        case .pulse:      return "Pulse"
        case .drift:      return "Follow"
        case .hybrid:     return "Living"
        }
    }

    var icon: String {
        switch self {
        case .sinusoidal: return "waveform.path"
        case .pulse:      return "bolt.fill"
        case .drift:      return "water.waves"
        case .hybrid:     return "sparkles"
        }
    }

    /// Display order for the UI curve picker: Follow → Living → Pulse → Wave.
    /// (Separate from `allCases`/Codable, which keep declaration order & rawValues.)
    static var pickerCases: [ResponseCurve] {
        [.drift, .hybrid, .pulse, .sinusoidal]
    }
}

enum LFOShape: String, CaseIterable, Codable, Sendable {
    case sine
    case triangle
    case square
    case sawtooth

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
        frequency = frequency.clamped(to: 0.001...5.0)
        amplitude = amplitude.clamped(to: 0.0...1.0)
    }

    static let `default` = LFOSettings()
}

enum MusicReactiveSource: String, CaseIterable, Codable, Sendable {
    /// Band-weighted overall intensity — the sensible default. (rawValue `composite`.)
    case composite
    case bass
    case mid
    case treble
    /// The punctuation / "the beat dropped" — a real spectral-flux onset that
    /// spikes on big hits. (rawValue stays `beat` for back-compat.)
    case beat
    /// Deprecated wideband RMS; redundant with Energy. Hidden from the picker
    /// (see `pickerCases`) but kept so older saved mappings still decode.
    case overall

    var displayName: String {
        switch self {
        case .composite: return "Energy"
        case .bass: return "Bass"
        case .mid: return "Mid"
        case .treble: return "Treble"
        case .beat: return "Drop"
        case .overall: return "Energy"   // legacy alias; behaves like wideband but reads as Energy
        }
    }

    /// Sources offered in the UI picker. Excludes the deprecated `overall`
    /// (redundant with Energy) so the control stays a clean, intuitive set.
    static var pickerCases: [MusicReactiveSource] {
        [.composite, .bass, .mid, .treble, .beat]
    }
}

/// Groups music-reactive targets so the "Add Control" menu can present collapsible
/// sub-sections instead of one long flat list. Formula param slots get their own
/// fractal-named section handled separately by the UI.
enum MusicReactiveTargetCategory: String, CaseIterable, Sendable {
    case geometry = "Geometry"
    case color = "Color"
    case light = "Light & Effects"
    case transform = "Transformations"

    var icon: String {
        switch self {
        case .geometry: return "cube.transparent"
        case .color: return "paintpalette"
        case .light: return "sun.max"
        case .transform: return "circle.hexagongrid"
        }
    }

    /// Display order for the universal (non-formula) sections.
    static let universalOrder: [MusicReactiveTargetCategory] = [.geometry, .color, .light, .transform]
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

    // Universal geometry parameter — safety bubble inner radius.
    case safetyBubbleRadius

    // Universal color parameter — gradient phase offset ("Color Offset").
    case gradientOffset

    // Universal space-transform params — cross-fractal sphere projection.
    case sphereProjectionBlend
    case sphereProjectionRadius

    // Dynamic formula-parameter slots — resolve via FormulaCatalog for the active fractal.
    // formulaParam0 maps to the 1st non-bool param, formulaParam1 to the 2nd, etc.
    // Supports up to 16 slots to match FormulaParams capacity.
    case formulaParam0
    case formulaParam1
    case formulaParam2
    case formulaParam3
    case formulaParam4
    case formulaParam5
    case formulaParam6
    case formulaParam7
    case formulaParam8
    case formulaParam9
    case formulaParam10
    case formulaParam11
    case formulaParam12
    case formulaParam13
    case formulaParam14
    case formulaParam15

    // Composable transform-STACK slots — per-slot master amount, resolved against the
    // LIVE stack (slot N = the Nth transform card). Up to kMaxSpaceWarpOps (8). Dynamic
    // like formula slots: nil static target id, surfaced only for slots that exist.
    case spaceWarp0
    case spaceWarp1
    case spaceWarp2
    case spaceWarp3
    case spaceWarp4
    case spaceWarp5
    case spaceWarp6
    case spaceWarp7

    // Legacy (kept for Codable backward-compat; migrated to formulaParam on load)
    case foldingLimit
    case sphereRadius

    /// All transform-slot cases in slot order.
    static let allSpaceWarpCases: [MusicReactiveTarget] = [
        .spaceWarp0, .spaceWarp1, .spaceWarp2, .spaceWarp3,
        .spaceWarp4, .spaceWarp5, .spaceWarp6, .spaceWarp7
    ]

    /// The slot index (0–7) for a transform-stack target; nil otherwise.
    var spaceWarpSlot: Int? { Self.allSpaceWarpCases.firstIndex(of: self) }
    var isSpaceWarp: Bool { spaceWarpSlot != nil }

    /// Transform-stack targets for the slots that actually exist in a `count`-deep stack.
    static func availableSpaceWarpCases(count: Int) -> [MusicReactiveTarget] {
        Array(allSpaceWarpCases.prefix(max(0, min(count, allSpaceWarpCases.count))))
    }

    // MARK: - Availability

    /// All formula param cases in slot order.
    static let allFormulaParamCases: [MusicReactiveTarget] = [
        .formulaParam0, .formulaParam1, .formulaParam2, .formulaParam3,
        .formulaParam4, .formulaParam5, .formulaParam6, .formulaParam7,
        .formulaParam8, .formulaParam9, .formulaParam10, .formulaParam11,
        .formulaParam12, .formulaParam13, .formulaParam14, .formulaParam15
    ]

    /// Cases shown in the UI add-menu. Excludes legacy/deprecated targets.
    /// Formula param slots beyond what the active fractal supports are hidden.
    static var availableCases: [MusicReactiveTarget] {
        [.fractalScale, .iterations,
         .glow, .fog, .bloom, .saturation, .safetyBubbleRadius, .gradientOffset,
         .sphereProjectionBlend, .sphereProjectionRadius]
    }

    /// Returns the full list of available targets for a given fractal type,
    /// including only formula param slots that exist for that fractal.
    static func availableCases(for fractalType: FractalModelType) -> [MusicReactiveTarget] {
        let formulaCount = floatFormulaParams(for: fractalType).count
        let formulaSlots = Array(allFormulaParamCases.prefix(formulaCount))
        return [.fractalScale, .iterations,
                .glow, .fog, .bloom, .saturation, .safetyBubbleRadius, .gradientOffset,
                .sphereProjectionBlend, .sphereProjectionRadius] + formulaSlots
    }

    /// Whether this target is a dynamic formula parameter slot.
    var isFormulaParam: Bool {
        Self.allFormulaParamCases.contains(self)
    }

    /// The ordinal slot (0–15) for formula-param targets; nil otherwise.
    var formulaParamSlot: Int? {
        Self.allFormulaParamCases.firstIndex(of: self)
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

    /// Category used to group this target in the "Add Control" menu. Formula param
    /// slots are surfaced under their own fractal-named section by the UI, so they
    /// fall through to `.geometry` here and are never read via this property.
    var category: MusicReactiveTargetCategory {
        // Routed core/effect/space targets project their category from the authored
        // ParameterCatalog facet (Slice 5). Formula param slots + legacy Mandelbox
        // aliases (no catalog facet) all group as .geometry.
        if isSpaceWarp { return .transform }
        if let id = parameterTargetID, let facet = ParameterCatalog.byID[id]?.music { return facet.category }
        return .geometry
    }

    var displayName: String {
        // Canonical core/effect controls source their label from ControlCatalog
        // (single source of truth). Formula slots + legacy targets fall through.
        if let slot = spaceWarpSlot { return "Transform \(slot + 1)" }
        if let id = parameterTargetID, let spec = ControlCatalog.spec(id) { return spec.name }
        if let slot = formulaParamSlot { return "Formula Param \(slot + 1)" }
        switch self {
        case .foldingLimit: return "Folding Limit"
        case .sphereRadius: return "Sphere Radius"
        default: return ""   // unreachable: core/effect handled above
        }
    }

    func icon(for fractalType: FractalModelType) -> String {
        if isFormulaParam, formulaDescriptor(for: fractalType) != nil {
            return "function"
        }
        return icon
    }

    var icon: String {
        // Canonical core/effect controls source their glyph from ControlCatalog.
        if isSpaceWarp { return "circle.hexagongrid" }
        if let id = parameterTargetID, let spec = ControlCatalog.spec(id) { return spec.icon }
        switch self {
        case .foldingLimit: return "square.dashed"
        case .sphereRadius: return "circle.circle"
        default: return "function"   // formula param slots
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
        // Canonical core/effect controls source their range from ControlCatalog.
        if isSpaceWarp { return 0...1 }   // transform master amount (blend / intensity)
        if let id = parameterTargetID, let spec = ControlCatalog.spec(id) { return spec.range }
        switch self {
        case .foldingLimit: return -10.0...30.0
        case .sphereRadius: return -5.0...8.0
        default: return -10.0...64.0   // formula param slots
        }
    }

    var defaultSource: MusicReactiveSource {
        // Routed targets project from the catalog facet (Slice 5). The remaining
        // formula param slots + legacy Mandelbox aliases keep their per-slot defaults.
        if let slot = spaceWarpSlot { return [.bass, .mid, .treble][slot % 3] }
        if let id = parameterTargetID, let facet = ParameterCatalog.byID[id]?.music { return facet.defaultSource }
        switch self {
        case .formulaParam0, .formulaParam4, .formulaParam8, .formulaParam12, .foldingLimit:
            return .bass
        case .formulaParam2, .formulaParam6, .formulaParam10, .formulaParam14:
            return .treble
        default:
            return .mid   // formulaParam1/3/5/7/9/11/13/15, sphereRadius (routed handled above)
        }
    }

    /// Default response curve for this target type.
    var defaultResponseCurve: ResponseCurve {
        // Routed targets project from the catalog facet (Slice 5); formula slots +
        // legacy Mandelbox aliases all default to .sinusoidal.
        if let id = parameterTargetID, let facet = ParameterCatalog.byID[id]?.music { return facet.defaultResponseCurve }
        return .sinusoidal
    }

    var hasFlashingRisk: Bool {
        // Routed targets project from the catalog facet (Slice 5); formula slots +
        // legacy Mandelbox aliases carry no flashing risk. (Legacy foldingLimit/
        // sphereRadius resolve to a non-catalog formula id, so they fall through to
        // false — matching the prior `self.migrated` mapping to formulaParam1/2.)
        if let id = parameterTargetID, let facet = ParameterCatalog.byID[id]?.music { return facet.hasFlashingRisk }
        return false
    }

    // MARK: - Parameter Target ID (fractal-type-aware)

    /// Returns the parameter system target ID for routing operations.
    /// Formula param targets require the active fractal type to resolve.
    func parameterTargetID(for fractalType: FractalModelType) -> String? {
        if let slot = spaceWarpSlot {
            return ParameterTargetID.SpaceWarp.opStrength(slot: slot)
        }
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
        case .safetyBubbleRadius: return ParameterTargetID.Effect.safetyBubbleRadius
        case .gradientOffset: return ParameterTargetID.Effect.gradientOffset
        case .sphereProjectionBlend: return ParameterTargetID.Space.sphereProjectionBlend
        case .sphereProjectionRadius: return ParameterTargetID.Space.sphereProjectionRadius
        case .formulaParam0, .formulaParam1, .formulaParam2, .formulaParam3,
             .formulaParam4, .formulaParam5, .formulaParam6, .formulaParam7,
             .formulaParam8, .formulaParam9, .formulaParam10, .formulaParam11,
             .formulaParam12, .formulaParam13, .formulaParam14, .formulaParam15: return nil
        case .spaceWarp0, .spaceWarp1, .spaceWarp2, .spaceWarp3,
             .spaceWarp4, .spaceWarp5, .spaceWarp6, .spaceWarp7: return nil   // dynamic — resolve via parameterTargetID(for:)
        case .foldingLimit: return ParameterTargetID.formula(fractalType: .mandelbox, formulaIndex: 1, name: "Folding Limit")
        case .sphereRadius: return ParameterTargetID.formula(fractalType: .mandelbox, formulaIndex: 2, name: "Sphere Radius")
        }
    }

    // MARK: - Default Mapping Factory

    func defaultMapping(for fractalType: FractalModelType, enabled: Bool = true) -> MusicReactiveMapping {
        MusicReactiveMapping(
            target: self,
            source: defaultSource,
            amount: 1.0,
            isEnabled: enabled
        )
    }

    func defaultMapping(enabled: Bool = true) -> MusicReactiveMapping {
        MusicReactiveMapping(
            target: self,
            source: defaultSource,
            amount: 1.0,
            isEnabled: enabled
        )
    }
}

struct MusicReactiveMapping: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var target: MusicReactiveTarget
    var source: MusicReactiveSource
    var amount: Float
    var isEnabled: Bool
    var responseCurve: ResponseCurve
    var lfo: LFOSettings
    var smoothingWindow: Float
    /// Hybrid-only blend: 0 = mostly drift, 1 = more fast vibration.
    var hybridCombo: Float
    /// Which field of a transform-stack op this mapping drives (only meaningful when
    /// `target` is a `spaceWarpN` slot). Defaults to `.strength` — the sole field
    /// bindable before this existed — so pre-existing scenes decode unchanged.
    var spaceWarpField: SpaceWarpField

    init(id: UUID = UUID(),
         target: MusicReactiveTarget,
         source: MusicReactiveSource,
         amount: Float,
         isEnabled: Bool,
         responseCurve: ResponseCurve? = nil,
         lfo: LFOSettings = .default,
         smoothingWindow: Float = 0.0,
         hybridCombo: Float = 0.35,
         spaceWarpField: SpaceWarpField = .strength) {
        self.id = id
        self.target = target
        self.source = source
        self.amount = amount
        self.isEnabled = isEnabled
        self.responseCurve = responseCurve ?? target.defaultResponseCurve
        self.lfo = lfo
        self.smoothingWindow = smoothingWindow
        self.hybridCombo = hybridCombo
        self.spaceWarpField = spaceWarpField
        sanitizeInPlace()
    }

    mutating func sanitizeInPlace() {
        amount = amount.clamped(to: -3.0...3.0)
        smoothingWindow = smoothingWindow.clamped(to: 0.0...2.0)
        hybridCombo = hybridCombo.clamped(to: 0.0...1.0)
        lfo.sanitizeInPlace()
    }

    var hasFlashingRisk: Bool {
        isEnabled && target.migrated.hasFlashingRisk && abs(amount) > 0.01
    }

    // MARK: - Backward-compatible Codable

    // Only the keys still in use are decoded. Legacy keys (rangeMin/rangeMax/
    // responseSpeed/mode) in older saved data are simply ignored.
    enum CodingKeys: String, CodingKey {
        case id, target, source, amount, isEnabled
        case responseCurve, lfo, smoothingWindow, hybridCombo, spaceWarpField
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.target = try c.decode(MusicReactiveTarget.self, forKey: .target)
        self.source = try c.decode(MusicReactiveSource.self, forKey: .source)
        self.amount = try c.decode(Float.self, forKey: .amount)
        self.isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        self.responseCurve = try c.decodeIfPresent(ResponseCurve.self, forKey: .responseCurve)
            ?? target.defaultResponseCurve
        self.lfo = try c.decodeIfPresent(LFOSettings.self, forKey: .lfo) ?? .default
        self.smoothingWindow = try c.decodeIfPresent(Float.self, forKey: .smoothingWindow) ?? 0.0
        self.hybridCombo = try c.decodeIfPresent(Float.self, forKey: .hybridCombo) ?? 0.35
        self.spaceWarpField = try c.decodeIfPresent(SpaceWarpField.self, forKey: .spaceWarpField) ?? .strength
        sanitizeInPlace()
    }

    /// Migrate legacy Mandelbox-specific mappings to generic formula param slots.
    static func migrateLegacy(_ mappings: [MusicReactiveMapping]) -> [MusicReactiveMapping] {
        var seen = Set<MusicReactiveTarget>()
        var result: [MusicReactiveMapping] = []
        for mapping in mappings {
            var mapping = mapping
            let newTarget = mapping.target.migrated
            mapping.target = newTarget
            guard seen.insert(newTarget).inserted else { continue }
            result.append(mapping)
        }
        return result
    }
}

// MARK: - Music-driven preset-bank sequencing

/// Ordered scene collections available to the music-driven preset sequencer.
///
/// These deliberately reuse the same classifications as the Explore browser.
/// Custom-formula and Mixed-immersion scenes are excluded from every bank: a
/// beat-driven switch must not start shader compilation or change immersion
/// mode on the render path.
enum MusicPresetBank: String, CaseIterable, Codable, Sendable {
    case musicReactive
    case jumpingOff
    case allStatic

    var displayName: String {
        switch self {
        case .musicReactive: return "Music Reactive"
        case .jumpingOff: return "Jumping Off"
        case .allStatic: return "All Static"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .musicReactive: return "Music"
        case .jumpingOff: return "Jumping Off"
        case .allStatic: return "All"
        }
    }

    var icon: String {
        switch self {
        case .musicReactive: return "waveform"
        case .jumpingOff: return "sparkles"
        case .allStatic: return "square.stack.3d.up"
        }
    }

    /// Return this bank's presets in the stable order supplied by PresetManager.
    /// Duplicate IDs are ignored defensively so wraparound can never oscillate
    /// between two copies of the same stored scene.
    func presets(from candidates: [FractalPreset]) -> [FractalPreset] {
        var seen = Set<UUID>()
        return candidates.filter { preset in
            guard preset.name != "__lastState__",
                  !preset.isCustomScenePreset,
                  preset.mixedModeScene != true,
                  seen.insert(preset.id).inserted else {
                return false
            }

            switch self {
            case .musicReactive:
                return !preset.isJumpingOffPreset
            case .jumpingOff:
                return preset.isJumpingOffPreset
            case .allStatic:
                return true
            }
        }
    }
}

/// Persistent, library-level configuration for switching full visual presets
/// from detected music Drops. This is intentionally not part of
/// AudioReactiveConfig: loading a scene replaces that scene-authored config,
/// which would otherwise disable its own sequencer after the first switch.
struct MusicPresetBankEffect: Codable, Equatable, Sendable {
    static let supportedDropCadences = [1, 2, 4, 8, 16]

    var isEnabled: Bool
    var bank: MusicPresetBank
    var dropsPerChange: Int
    var minimumInterval: TimeInterval

    init(
        isEnabled: Bool = false,
        bank: MusicPresetBank = .musicReactive,
        dropsPerChange: Int = 8,
        minimumInterval: TimeInterval = 8
    ) {
        self.isEnabled = isEnabled
        self.bank = bank
        self.dropsPerChange = dropsPerChange
        self.minimumInterval = minimumInterval
        normalizeInPlace()
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, bank, dropsPerChange, minimumInterval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? false
        bank = (try? container.decode(MusicPresetBank.self, forKey: .bank)) ?? .musicReactive
        dropsPerChange = (try? container.decode(Int.self, forKey: .dropsPerChange)) ?? 8
        minimumInterval = (try? container.decode(TimeInterval.self, forKey: .minimumInterval)) ?? 8
        normalizeInPlace()
    }

    mutating func normalizeInPlace() {
        dropsPerChange = min(32, max(1, dropsPerChange))
        minimumInterval = minimumInterval.isFinite
            ? min(60, max(2, minimumInterval))
            : 8
    }

    var normalized: MusicPresetBankEffect {
        var copy = self
        copy.normalizeInPlace()
        return copy
    }
}

/// Combines the unscaled Drop signals used by the preset-bank sequencer. Scene
/// presets are allowed to author their own beat sensitivity (including zero),
/// so sequencing must listen before that scene-local multiplier is applied.
enum MusicPresetBankDropEnvelope {
    static func merged(
        analyzerOnset: Float,
        analyzerIsActive: Bool,
        playbackBeat: Float,
        playbackIsActive: Bool
    ) -> Float {
        var level: Float = 0
        if analyzerIsActive, analyzerOnset.isFinite {
            level = max(level, analyzerOnset)
        }
        if playbackIsActive, playbackBeat.isFinite {
            level = max(level, playbackBeat)
        }
        return min(1, max(0, level))
    }
}

/// Rising-edge/hysteresis detector for the Drop envelope. The audio analyzer's
/// onset remains high for several frames, so level-based triggering would load
/// the same scene repeatedly. A low rearm threshold plus a short edge debounce
/// turns each pulse into exactly one counted Drop.
struct MusicPresetBankTrigger: Sendable {
    static let triggerThreshold: Float = 0.65
    static let rearmThreshold: Float = 0.25
    static let minimumDropInterval: TimeInterval = 0.20

    private(set) var detectedDropCount = 0
    private var isDropLatched = false
    private var lastAcceptedDropTime: TimeInterval?
    private var lastChangeTime: TimeInterval?

    mutating func update(
        beatIntensity: Float,
        configuration: MusicPresetBankEffect,
        hasActiveSource: Bool,
        now: TimeInterval
    ) -> Bool {
        let configuration = configuration.normalized
        guard configuration.isEnabled, hasActiveSource else {
            reset()
            return false
        }

        let level = beatIntensity.isFinite ? max(0, min(1, beatIntensity)) : 0
        if level <= Self.rearmThreshold {
            isDropLatched = false
            return false
        }

        guard level >= Self.triggerThreshold, !isDropLatched else { return false }
        isDropLatched = true

        let timestamp = now.isFinite ? now : 0
        if let lastAcceptedDropTime,
           timestamp - lastAcceptedDropTime < Self.minimumDropInterval {
            return false
        }
        lastAcceptedDropTime = timestamp
        detectedDropCount = min(configuration.dropsPerChange, detectedDropCount + 1)

        guard detectedDropCount >= configuration.dropsPerChange else { return false }
        if let lastChangeTime,
           timestamp - lastChangeTime < configuration.minimumInterval {
            // Keep the cadence satisfied; the next Drop after the cooldown
            // advances immediately instead of making the user count again.
            return false
        }

        detectedDropCount = 0
        lastChangeTime = timestamp
        return true
    }

    mutating func reset() {
        detectedDropCount = 0
        isDropLatched = false
        lastAcceptedDropTime = nil
        lastChangeTime = nil
    }
}

/// Pure wraparound selection shared by keyboard scene switching and the music
/// sequencer. Callers compare the returned ID with the current ID so an
/// already-selected singleton never causes an unnecessary reload.
enum MusicPresetBankCycler {
    static func nextPreset(
        in candidates: [FractalPreset],
        after currentID: UUID?,
        forward: Bool = true
    ) -> FractalPreset? {
        var seen = Set<UUID>()
        let presets = candidates.filter { seen.insert($0.id).inserted }
        guard !presets.isEmpty else { return nil }

        guard let currentID,
              let currentIndex = presets.firstIndex(where: { $0.id == currentID }) else {
            return forward ? presets.first : presets.last
        }
        guard presets.count > 1 else { return presets[currentIndex] }

        let offset = forward ? 1 : -1
        let count = presets.count
        let nextIndex = ((currentIndex + offset) % count + count) % count
        return presets[nextIndex]
    }
}

struct MusicReactivePreset: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date
    var audioAmount: Float
    var beatPunch: Float
    var audioDamping: Float
    var bassSensitivity: Float
    var midSensitivity: Float
    var trebleSensitivity: Float
    var beatSensitivity: Float
    var mappings: [MusicReactiveMapping]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt
        case audioAmount
        case beatPunch
        case audioDamping
        case bassSensitivity
        case midSensitivity
        case trebleSensitivity
        case beatSensitivity
        case mappings
    }

    init(id: UUID = UUID(),
         name: String,
         createdAt: Date = Date(),
         audioAmount: Float,
         beatPunch: Float,
         audioDamping: Float,
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
        self.audioDamping = audioDamping
        self.bassSensitivity = bassSensitivity
        self.midSensitivity = midSensitivity
        self.trebleSensitivity = trebleSensitivity
        self.beatSensitivity = beatSensitivity
        self.mappings = mappings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        audioAmount = try container.decode(Float.self, forKey: .audioAmount)
        beatPunch = try container.decode(Float.self, forKey: .beatPunch)
        audioDamping = try container.decodeIfPresent(Float.self, forKey: .audioDamping) ?? 0.0
        bassSensitivity = try container.decode(Float.self, forKey: .bassSensitivity)
        midSensitivity = try container.decode(Float.self, forKey: .midSensitivity)
        trebleSensitivity = try container.decode(Float.self, forKey: .trebleSensitivity)
        beatSensitivity = try container.decode(Float.self, forKey: .beatSensitivity)
        mappings = try container.decodeIfPresent([MusicReactiveMapping].self, forKey: .mappings) ?? []
    }
    // `encode(to:)` is synthesized from the explicit `CodingKeys` above.
}

/// Genre-optimized reactivity presets.
/// Each preset tunes sensitivity scalars and which parameters respond to audio.
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

    /// Core sensitivity tuning: (audioAmount, beatPunch, audioDamping, bassSens, midSens, trebleSens, beatSens)
    var settings: (audioAmount: Float, beatPunch: Float, audioDamping: Float, bassSensitivity: Float,
                   midSensitivity: Float, trebleSensitivity: Float, beatSensitivity: Float) {
        switch self {
        case .electronic: return (0.75, 0.85, 0.12, 1.1, 0.8, 0.9, 1.2)
        case .ambient:    return (0.45, 0.15, 0.55, 0.6, 0.8, 0.9, 0.3)
        case .rock:       return (0.65, 0.70, 0.20, 0.9, 1.0, 0.7, 0.8)
        case .classical:  return (0.40, 0.20, 0.60, 0.5, 0.9, 0.8, 0.3)
        case .hiphop:     return (0.80, 0.90, 0.16, 1.2, 0.7, 0.5, 1.0)
        }
    }
    
    /// Which formula-param slots (by index) this preset enables.
    /// Slots beyond what the active fractal supports are silently ignored.
    var formulaParamSlots: [Int] {
        switch self {
        case .electronic: return [0, 1, 2, 3]
        case .ambient:    return []
        case .rock:       return [0, 1, 2]
        case .classical:  return [3]
        case .hiphop:     return [0, 1, 2]
        }
    }

    /// Whether this preset enables fractalScale and colorMix.
    var enablesScaleAndColor: (scale: Bool, colorMix: Bool) {
        switch self {
        case .electronic: return (true,  true )
        case .ambient:    return (true,  true )
        case .rock:       return (true,  false)
        case .classical:  return (false, true )
        case .hiphop:     return (true,  false)
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
        let geo = enablesScaleAndColor
        let effects = effectsProfile
        let slots = formulaParamSlots
        let formulaSlots = MusicReactiveTarget.allFormulaParamCases
        let formulaCount = MusicReactiveTarget.floatFormulaParams(for: fractalType).count
        var result: [MusicReactiveMapping] = []

        if geo.scale     { result.append(MusicReactiveTarget.fractalScale.defaultMapping(for: fractalType)) }
        for slot in slots where slot < formulaCount && slot < formulaSlots.count {
            result.append(formulaSlots[slot].defaultMapping(for: fractalType))
        }
        // colorMix + hueSpeed are no longer music-bindable (see availableCases).
        if effects.glow       { result.append(MusicReactiveTarget.glow.defaultMapping(for: fractalType)) }
        if effects.fog        { result.append(MusicReactiveTarget.fog.defaultMapping(for: fractalType)) }
        if effects.bloom      { result.append(MusicReactiveTarget.bloom.defaultMapping(for: fractalType)) }
        if effects.saturation { result.append(MusicReactiveTarget.saturation.defaultMapping(for: fractalType)) }
        if effects.iterations { result.append(MusicReactiveTarget.iterations.defaultMapping(for: fractalType)) }

        return result
    }

    /// Fallback that uses Mandelbox as the default fractal (backward compat).
    var defaultMappings: [MusicReactiveMapping] {
        defaultMappings(for: .mandelbox)
    }

    var hasFlashingRisk: Bool {
        defaultMappings.contains(where: \.hasFlashingRisk)
    }
}
