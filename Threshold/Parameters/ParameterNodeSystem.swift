import Foundation
import Synchronization

// MARK: - Shared Parameter Taxonomy

enum ParameterLayer: String, Codable, Sendable {
    case ui
    case gesture
    case music
    case precompute
    case system
}

enum ParameterMotionStrategy: String, Codable, Sendable {
    case none
    case layerLerp
    case smoothDamp
}

struct ParameterGroup: Hashable, Codable, Sendable {
    let id: String
    let title: String
}

// MARK: - Core Node Protocol

/// @unchecked Sendable justification: immutable metadata only.
class AnyParameterNodeBase: @unchecked Sendable, Identifiable {
    let id: String
    let name: String
    let group: ParameterGroup?
    let icon: String
    let isGestureMappable: Bool
    let motionStrategy: ParameterMotionStrategy

    init(id: String,
         name: String,
         group: ParameterGroup?,
         icon: String,
         isGestureMappable: Bool,
         motionStrategy: ParameterMotionStrategy) {
        self.id = id
        self.name = name
        self.group = group
        self.icon = icon
        self.isGestureMappable = isGestureMappable
        self.motionStrategy = motionStrategy
    }
}

/// @unchecked Sendable justification: mutable layer state is protected by Mutex;
/// read/write closures are MainActor-isolated and only invoked from the UI path.
class FloatParameterNode: AnyParameterNodeBase, @unchecked Sendable {
    let range: ClosedRange<Float>
    let readValue: @MainActor (UISettingsCache) -> Float
    let writeValue: @MainActor (UISettingsCache, Float) -> Void
    private let _layerStack: Mutex<ParameterLayerStack>

    init(id: String,
         name: String,
         group: ParameterGroup?,
         icon: String,
         defaultValue: Float,
         range: ClosedRange<Float>,
         isGestureMappable: Bool,
         motionStrategy: ParameterMotionStrategy = .layerLerp,
         readValue: @MainActor @escaping (UISettingsCache) -> Float,
         writeValue: @MainActor @escaping (UISettingsCache, Float) -> Void) {
        self.range = range
        self.readValue = readValue
        self.writeValue = writeValue
        self._layerStack = Mutex(ParameterLayerStack(defaultValue: defaultValue, range: range))
        super.init(id: id,
                   name: name,
                   group: group,
                   icon: icon,
                   isGestureMappable: isGestureMappable,
                   motionStrategy: motionStrategy)
    }

    @discardableResult
    func applyLayer(_ layer: ParameterLayer,
                    value: Float,
                    smoothingTime: Float? = nil,
                    timestamp: TimeInterval = CFAbsoluteTimeGetCurrent()) -> Float {
        _layerStack.withLock { layerStack in
            layerStack.apply(layer: layer, value: value, smoothingTime: smoothingTime, timestamp: timestamp)
        }
    }

    func resolvedValue(timestamp: TimeInterval = CFAbsoluteTimeGetCurrent()) -> Float {
        _layerStack.withLock { layerStack in
            layerStack.resolvedValue(at: timestamp)
        }
    }

    func bootstrapBaseIfNeeded(from value: Float, timestamp: TimeInterval = CFAbsoluteTimeGetCurrent()) {
        _layerStack.withLock { layerStack in
            layerStack.setBaseIfNeeded(value, timestamp: timestamp)
        }
    }
}

/// @unchecked Sendable justification: stores immutable metadata plus MainActor-only closures.
final class BoolParameterNode: AnyParameterNodeBase, @unchecked Sendable {
    let readValue: @MainActor (UISettingsCache) -> Bool
    let writeValue: @MainActor (UISettingsCache, Bool) -> Void

    init(id: String,
         name: String,
         group: ParameterGroup?,
         icon: String,
         defaultValue: Bool,
         isGestureMappable: Bool,
         motionStrategy: ParameterMotionStrategy = .none,
         readValue: @MainActor @escaping (UISettingsCache) -> Bool,
         writeValue: @MainActor @escaping (UISettingsCache, Bool) -> Void) {
        self.readValue = readValue
        self.writeValue = writeValue
        super.init(id: id,
                   name: name,
                   group: group,
                   icon: icon,
                   isGestureMappable: isGestureMappable,
                   motionStrategy: motionStrategy)
    }
}

// MARK: - Layered Value Stack

private struct ParameterLayerEntry: Sendable {
    var rawValue: Float
    var smoothingTime: Float?
    private(set) var lastResolved: Float
    private(set) var lastTimestamp: TimeInterval

    init(rawValue: Float,
         smoothingTime: Float?,
         timestamp: TimeInterval) {
        self.rawValue = rawValue
        self.smoothingTime = smoothingTime
        self.lastResolved = rawValue
        self.lastTimestamp = timestamp
    }

    mutating func resolvedValue(at timestamp: TimeInterval) -> Float {
        guard let smoothingTime, smoothingTime > 0 else {
            lastResolved = rawValue
            lastTimestamp = timestamp
            return rawValue
        }

        let dt = max(0, timestamp - lastTimestamp)
        let decay = exp(-dt / max(0.001, Double(smoothingTime)))
        let alpha = Float(1.0 - decay)
        let resolved = lastResolved + (rawValue - lastResolved) * alpha
        lastResolved = resolved
        lastTimestamp = timestamp
        return resolved
    }
}

struct ParameterLayerStack: Sendable {
    /// Default smoothing time (seconds) applied to all non-music parameter changes.
    /// Provides frame-rate-independent exponential lerp that eliminates jitter/stagger
    /// from gesture input noise and discrete slider steps.
    static let defaultSmoothingTime: Float = 0.08

    private var ui: ParameterLayerEntry?
    private var precompute: ParameterLayerEntry?
    private var gesture: ParameterLayerEntry?
    private var system: ParameterLayerEntry?
    private var music: ParameterLayerEntry?

    private(set) var defaultValue: Float
    private(set) var range: ClosedRange<Float>

    /// The anchor (user/base) value the additive layers modulate around — i.e. the
    /// `.ui` layer's raw value. Non-mutating so the UI can peek without disturbing
    /// the smoothing state owned by the render side.
    var baseRawValue: Float? { ui?.rawValue }

    init(defaultValue: Float, range: ClosedRange<Float>, timestamp: TimeInterval = CFAbsoluteTimeGetCurrent()) {
        self.defaultValue = defaultValue
        self.range = range
        self.ui = ParameterLayerEntry(rawValue: defaultValue, smoothingTime: nil, timestamp: timestamp)
    }


    mutating func setBaseIfNeeded(_ value: Float, timestamp: TimeInterval) {
        guard ui == nil else { return }
        ui = ParameterLayerEntry(rawValue: value, smoothingTime: nil, timestamp: timestamp)
    }

    /// Force the anchor (`.ui`) layer to a fresh value, bypassing the one-shot
    /// `setBaseIfNeeded` guard. Used when the user manually re-sets a parameter
    /// (slider) so the additive music layer modulates around the new value
    /// instead of a stale bootstrap. `clearGesture` drops any prior gesture
    /// override so the manual value is authoritative.
    mutating func recenterBase(to value: Float, timestamp: TimeInterval, clearGesture: Bool) {
        ui = ParameterLayerEntry(rawValue: value, smoothingTime: nil, timestamp: timestamp)
        if clearGesture { gesture = nil }
    }

    @discardableResult
    mutating func apply(layer: ParameterLayer,
                        value: Float,
                        smoothingTime: Float?,
                        timestamp: TimeInterval) -> Float {
        // Clamp absolute-valued layers at input. Music is additive (offset from
        // anchor) so its raw value is intentionally unclamped — the final clamp
        // in resolvedValue() catches the sum.
        let clamped: Float
        if layer == .music {
            clamped = value
        } else {
            clamped = min(range.upperBound, max(range.lowerBound, value))
        }

        // Music bypasses smoothing entirely; all other layers get at least
        // the default smoothing time so parameter shifts lerp over time.
        let effectiveSmoothingTime: Float? = (layer == .music)
            ? smoothingTime
            : (smoothingTime ?? Self.defaultSmoothingTime)

        // Preserve previous smoothing state (lastResolved / lastTimestamp)
        // from an existing entry so the exponential lerp carries forward.
        // Creating a fresh entry each frame was resetting lastResolved = rawValue,
        // which zeroed out the lerp delta and killed all smoothing.
        if var existing = get(for: layer) {
            existing.rawValue = clamped
            existing.smoothingTime = effectiveSmoothingTime
            set(entry: existing, for: layer)
        } else {
            let entry = ParameterLayerEntry(rawValue: clamped, smoothingTime: effectiveSmoothingTime, timestamp: timestamp)
            set(entry: entry, for: layer)
        }
        return resolvedValue(at: timestamp)
    }

    mutating func resolvedValue(at timestamp: TimeInterval) -> Float {
        // Copy layer entries to locals to avoid overlapping access on self
        var uiEntry = ui
        var precomputeEntry = precompute
        var gestureEntry = gesture
        var systemEntry = system
        var musicEntry = music

        var value = Self.resolve(entry: &uiEntry, at: timestamp) ?? defaultValue

        if let p = Self.resolve(entry: &precomputeEntry, at: timestamp) {
            value = p
        }

        if let g = Self.resolve(entry: &gestureEntry, at: timestamp) {
            value = g
        }

        if let s = Self.resolve(entry: &systemEntry, at: timestamp) {
            value = s
        }

        if let m = Self.resolve(entry: &musicEntry, at: timestamp) {
            value += m
        }

        // Write back smoothed state
        ui = uiEntry
        precompute = precomputeEntry
        gesture = gestureEntry
        system = systemEntry
        music = musicEntry

        return min(range.upperBound, max(range.lowerBound, value))
    }

    // MARK: - Internal helpers

    private func get(for layer: ParameterLayer) -> ParameterLayerEntry? {
        switch layer {
        case .ui: return ui
        case .precompute: return precompute
        case .gesture: return gesture
        case .system: return system
        case .music: return music
        }
    }

    private static func resolve(entry: inout ParameterLayerEntry?, at timestamp: TimeInterval) -> Float? {
        guard var entryValue = entry else { return nil }
        let resolved = entryValue.resolvedValue(at: timestamp)
        entry = entryValue
        return resolved
    }

    private mutating func set(entry: ParameterLayerEntry?, for layer: ParameterLayer) {
        switch layer {
        case .ui: ui = entry
        case .precompute: precompute = entry
        case .gesture: gesture = entry
        case .system: system = entry
        case .music: music = entry
        }
    }
}

// MARK: - Batching + Registration

struct ParameterNodeBatch: Sendable {
    let fractalType: FractalModelType
    let floatNodes: [FloatParameterNode]
    let boolNodes: [BoolParameterNode]
    let floatNodeByFormulaIndex: [Int: FloatParameterNode]

    /// Combined view for UI iteration (float + bool nodes in original order).
    var allNodes: [AnyParameterNodeBase] {
        (floatNodes as [AnyParameterNodeBase]) + (boolNodes as [AnyParameterNodeBase])
    }

    init(fractalType: FractalModelType,
         floatNodes: [FloatParameterNode] = [],
         boolNodes: [BoolParameterNode] = [],
         floatNodeByFormulaIndex: [Int: FloatParameterNode] = [:]) {
        self.fractalType = fractalType
        self.floatNodes = floatNodes
        self.boolNodes = boolNodes
        self.floatNodeByFormulaIndex = floatNodeByFormulaIndex
    }
}

/// Startup-built registry of parameter nodes shared across UI and rendering.
/// @unchecked Sendable justification: mutable custom-formula batches are rebuilt
/// on demand behind `formulaBatchLock`; the singleton is otherwise read-mostly.
final class ParameterNodeRegistry: @unchecked Sendable {
    static let shared = ParameterNodeRegistry()

    private var formulaBatches: [FractalModelType: ParameterNodeBatch]
    private var customBatchDescriptorID: String?
    private let formulaBatchLock = NSLock()
    /// Core parameter nodes (fractalScale, colorMix).
    /// Keyed by their canonical targetID string (e.g. "core.fractalScale").
    let coreNodes: [String: FloatParameterNode]
    /// Effect parameter nodes (glow, fog, bloom, hueSpeed, saturation).
    let effectNodes: [String: FloatParameterNode]

    private init() {
        let coreAndEffectNodes = Self.buildCoreAndEffectNodes()
        self.coreNodes = coreAndEffectNodes.core
        self.effectNodes = coreAndEffectNodes.effect

        var batches: [FractalModelType: ParameterNodeBatch] = [:]
        for type in FractalModelType.allCases {
            batches[type] = Self.buildFormulaBatch(for: type)
        }
        self.formulaBatches = batches
        self.customBatchDescriptorID = FormulaCatalog.shared.descriptor(for: .custom)?.id
    }

    /// One-time build of engine-level parameter nodes for core geometry and effects.
    /// IDs and ranges mirror the descriptors in ParameterOperationDispatcher.
    /// NOTE: minDistance / foldingLimit / sphereRadius are now catalog-driven formula
    /// params (built per-type in buildFormulaBatch) rather than hard-coded core nodes.
    private static func buildCoreAndEffectNodes() -> (core: [String: FloatParameterNode], effect: [String: FloatParameterNode]) {
        let coreGroup = ParameterGroup(id: "core.geometry", title: "Fractal Geometry")
        let effectGroup = ParameterGroup(id: "effect.postprocess", title: "Post-Processing")
        var coreNodes: [String: FloatParameterNode] = [:]
        var effectNodes: [String: FloatParameterNode] = [:]

        // --- Core geometry nodes ---

        coreNodes[ParameterTargetID.Core.fractalScale] = FloatParameterNode(
            id: ParameterTargetID.Core.fractalScale,
            name: "Fractal Scale",
            group: coreGroup,
            icon: "arrow.up.left.and.arrow.down.right",
            defaultValue: 2.0,
            range: -5.0...8.0,
            isGestureMappable: true,
            motionStrategy: .smoothDamp,
            readValue: { $0.fractalScale },
            writeValue: { cache, v in cache.fractalScale = v; cache.push(\.targetFractalScale, value: v) }
        )

        coreNodes[ParameterTargetID.Core.colorMix] = FloatParameterNode(
            id: ParameterTargetID.Core.colorMix,
            name: "Color Mix",
            group: coreGroup,
            icon: "paintpalette",
            defaultValue: 0.5,
            range: 0.0...1.0,
            isGestureMappable: true,
            readValue: { $0.color.colorMix },
            writeValue: { cache, v in cache.color.colorMix = v; cache.push(\.colorMix, value: v) }
        )

        coreNodes[ParameterTargetID.Core.iterations] = FloatParameterNode(
            id: ParameterTargetID.Core.iterations,
            name: "Iterations",
            group: coreGroup,
            icon: "number",
            defaultValue: 12.0,
            range: 2.0...24.0,
            isGestureMappable: false,
            readValue: { Float($0.liveFractalIterations) },
            writeValue: { cache, v in
                let rounded = max(2, min(24, Int(round(v))))
                cache.liveFractalIterations = rounded
                cache.push(\.fractalIterations, value: rounded)
            }
        )

        // --- Effect nodes ---
        effectNodes[ParameterTargetID.Effect.glow] = FloatParameterNode(
            id: ParameterTargetID.Effect.glow,
            name: "Glow",
            group: effectGroup,
            icon: "sun.max",
            defaultValue: 0.0,
            range: 0.0...2.0,
            isGestureMappable: false,
            readValue: { $0.lighting.glowEffect.intensity },
            writeValue: { cache, v in cache.lighting.glowEffect.intensity = v; cache.commitGlowEffect() }
        )

        effectNodes[ParameterTargetID.Effect.fog] = FloatParameterNode(
            id: ParameterTargetID.Effect.fog,
            name: "Fog",
            group: effectGroup,
            icon: "cloud.fog",
            defaultValue: 0.32,
            range: 0.0...1.0,
            isGestureMappable: false,
            readValue: { $0.lighting.fogEffect.intensity },
            writeValue: { cache, v in cache.lighting.fogEffect.intensity = v; cache.commitFogEffect() }
        )

        effectNodes[ParameterTargetID.Effect.bloom] = FloatParameterNode(
            id: ParameterTargetID.Effect.bloom,
            name: "Bloom",
            group: effectGroup,
            icon: "sparkle",
            defaultValue: 0.0,
            range: 0.0...2.0,
            isGestureMappable: false,
            readValue: { $0.lighting.bloomEffect.strength },
            writeValue: { cache, v in cache.lighting.bloomEffect.strength = v; cache.commitBloomEffect() }
        )

        effectNodes[ParameterTargetID.Effect.hueSpeed] = FloatParameterNode(
            id: ParameterTargetID.Effect.hueSpeed,
            name: "Hue Speed",
            group: effectGroup,
            icon: "arrow.trianglehead.2.clockwise.rotate.90",
            defaultValue: 0.0,
            range: 0.0...0.5,
            isGestureMappable: false,
            readValue: { $0.lighting.hueRotationEffect.speed },
            writeValue: { cache, v in cache.lighting.hueRotationEffect.speed = v; cache.commitHueRotationEffect() }
        )

        effectNodes[ParameterTargetID.Effect.saturation] = FloatParameterNode(
            id: ParameterTargetID.Effect.saturation,
            name: "Saturation",
            group: effectGroup,
            icon: "drop.halffull",
            defaultValue: 2.0,
            range: 0.0...3.0,
            isGestureMappable: false,
            readValue: { $0.color.colorSchemeSaturation },
            writeValue: { cache, v in cache.color.colorSchemeSaturation = v; cache.commitColorSchemeSaturation() }
        )

        return (coreNodes, effectNodes)
    }

    func formulaBatch(for type: FractalModelType) -> ParameterNodeBatch {
        formulaBatchLock.lock()
        defer { formulaBatchLock.unlock() }

        if type == .custom {
            let currentDescriptorID = FormulaCatalog.shared.descriptor(for: .custom)?.id
            if currentDescriptorID != customBatchDescriptorID {
                formulaBatches[type] = currentDescriptorID == nil
                    ? ParameterNodeBatch(fractalType: type)
                    : Self.buildFormulaBatch(for: type)
                customBatchDescriptorID = currentDescriptorID
            }
        }

        return formulaBatches[type] ?? ParameterNodeBatch(fractalType: type)
    }

    func node(for type: FractalModelType, formulaIndex: Int) -> FloatParameterNode? {
        formulaBatch(for: type).floatNodeByFormulaIndex[formulaIndex]
    }

    func gestureBindableTriplets(for type: FractalModelType) -> [GestureBindableTriplet] {
        guard let descriptor = FormulaCatalog.shared.descriptor(for: type) else { return [] }
        let batch = formulaBatch(for: type)

        // Detect xyz groups by looking for params with names ending in .x, .y, .z
        // that share the same prefix (e.g. "Mins.x", "Mins.y", "Mins.z")
        var prefixGroups: [String: [(FormulaParamDescriptor, FloatParameterNode)]] = [:]
        for param in descriptor.params {
            guard !(param.isBool ?? false) else { continue }
            let name = param.name
            for suffix in [".x", ".y", ".z"] {
                if name.hasSuffix(suffix) {
                    let prefix = String(name.dropLast(suffix.count))
                    if let node = batch.floatNodeByFormulaIndex[param.index] {
                        prefixGroups[prefix, default: []].append((param, node))
                    }
                }
            }
        }

        var triplets: [GestureBindableTriplet] = []
        for (prefix, members) in prefixGroups.sorted(by: { $0.key < $1.key }) {
            guard members.count == 3 else { continue }
            let xMember = members.first { $0.0.name.hasSuffix(".x") }
            let yMember = members.first { $0.0.name.hasSuffix(".y") }
            let zMember = members.first { $0.0.name.hasSuffix(".z") }
            guard let x = xMember, let y = yMember, let z = zMember else { continue }

            let lo = min(x.0.min, y.0.min, z.0.min)
            let hi = max(x.0.max, y.0.max, z.0.max)

            triplets.append(GestureBindableTriplet(
                fractalType: type,
                groupName: prefix,
                xNodeID: x.1.id,
                yNodeID: y.1.id,
                zNodeID: z.1.id,
                xFormulaIndex: x.0.index,
                yFormulaIndex: y.0.index,
                zFormulaIndex: z.0.index,
                range: lo...hi,
                display: GestureDisplayMetadata(
                    title: "\(prefix) XYZ",
                    subtitle: descriptor.name,
                    icon: "move.3d"
                )
            ))
        }
        return triplets
    }

    func gestureBindableParameters(for type: FractalModelType) -> [GestureBindableParameter] {
        formulaBatch(for: type).floatNodes.map { node in
            let pieces = node.id.split(separator: ".")
            let formulaIndex = pieces.count >= 3 ? Int(pieces[2]) : nil
            return GestureBindableParameter(
                fractalType: type,
                parameterNodeID: node.id,
                formulaIndex: formulaIndex,
                display: GestureDisplayMetadata(
                    title: node.name,
                    subtitle: node.group?.title,
                    icon: node.icon
                )
            )
        }
    }

    func node(for binding: GestureBindableParameter) -> FloatParameterNode? {
        formulaBatch(for: binding.fractalType).floatNodes.first { $0.id == binding.parameterNodeID }
    }

    private static func buildFormulaBatch(for type: FractalModelType) -> ParameterNodeBatch {
        guard let descriptor = FormulaCatalog.shared.descriptor(for: type) else {
            return ParameterNodeBatch(fractalType: type)
        }

        let group = ParameterGroup(id: descriptor.id, title: descriptor.name)
        var seenFormulaIndices: Set<Int> = []
        var floatNodes: [FloatParameterNode] = []
        var boolNodes: [BoolParameterNode] = []
        var floatNodeByFormulaIndex: [Int: FloatParameterNode] = [:]

        for param in descriptor.params {
            guard !(param.isHidden ?? false) else { continue }
            assert(
                seenFormulaIndices.insert(param.index).inserted,
                "Duplicate formula parameter index \(param.index) for fractal type \(type.rawValue)"
            )

            let label = Self.displayLabel(for: param.name)
            let icon = Self.icon(for: param.name)
            let id = ParameterTargetID.formula(fractalType: type, formulaIndex: param.index, name: param.name)

            if param.isBool == true {
                boolNodes.append(BoolParameterNode(
                    id: id,
                    name: label,
                    group: group,
                    icon: icon,
                    defaultValue: param.default > 0.5,
                    isGestureMappable: false,
                    readValue: { cache in FormulaCatalog.getParam(cache.formulaParams, index: param.index) > 0.5 },
                    writeValue: { cache, value in
                        FormulaCatalog.setParam(&cache.formulaParams, index: param.index, value: value ? 1 : 0)
                        cache.renderSettings?.formulaParams = cache.formulaParams
                    }
                ))
                continue
            }

            let node = FloatParameterNode(
                id: id,
                name: label,
                group: group,
                icon: icon,
                defaultValue: param.default,
                range: param.min...param.max,
                isGestureMappable: true,
                motionStrategy: Self.formulaMotionStrategy(for: type, index: param.index),
                readValue: { cache in FormulaCatalog.getParam(cache.formulaParams, index: param.index) },
                writeValue: { cache, value in
                    if let settings = cache.renderSettings, settings.isAnimationPlaying {
                        settings.setManualFormulaParamOverride(index: param.index, value: value)
                        cache.formulaParams = settings.formulaParams
                    } else {
                        FormulaCatalog.setParam(&cache.formulaParams, index: param.index, value: value)
                        cache.renderSettings?.formulaParams = cache.formulaParams
                    }
                }
            )

            floatNodes.append(node)
            floatNodeByFormulaIndex[param.index] = node
        }

        return ParameterNodeBatch(
            fractalType: type,
            floatNodes: floatNodes,
            boolNodes: boolNodes,
            floatNodeByFormulaIndex: floatNodeByFormulaIndex
        )
    }

    private static func displayLabel(for rawName: String) -> String {
        let raw = rawName.replacingOccurrences(of: ".", with: " ")
        var result = ""
        for (index, char) in raw.enumerated() {
            if index > 0 && char.isUppercase && raw[raw.index(raw.startIndex, offsetBy: index - 1)].isLowercase {
                result += " "
            }
            result += String(char)
        }
        return result
    }

    private static func icon(for rawName: String) -> String {
        let name = rawName.lowercased()
        if name.contains("scale") { return "arrow.up.left.and.arrow.down.right" }
        if name.contains("power") { return "bolt" }
        if name.contains("bailout") || name.contains("threshold") { return "exclamationmark.triangle" }
        if name.contains("julia") { return "sparkle" }
        if name.contains("offset") { return "arrow.up.and.down.and.arrow.left.and.right" }
        if name.contains("fold") { return "arrow.triangle.branch" }
        if name.contains("size") || name.contains("rad") { return "circle.dashed" }
        if name.contains("rot") || name.contains("angle") || name.contains("twiddle") { return "arrow.trianglehead.2.clockwise.rotate.90" }
        if name.contains("phi") { return "fibrechannel" }
        if name.contains("de") { return "ruler" }
        if name.hasPrefix("c.") || name.hasPrefix("g.") { return "cube" }
        if name.contains("pre") { return "arrow.right" }
        if name.contains("bubble") { return "circle.grid.3x3" }
        return "slider.horizontal.3"
    }

    private static func formulaMotionStrategy(for type: FractalModelType,
                                              index: Int) -> ParameterMotionStrategy {
        switch (type, index) {
        case (.mandelbox, 0...2):
            return .smoothDamp
        default:
            return .layerLerp
        }
    }

}
