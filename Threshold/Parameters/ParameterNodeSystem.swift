import Foundation

// MARK: - Shared Parameter Taxonomy

// High-level bundles describe which conceptual group a parameter belongs to. This allows
// UI, gesture, and modulation layers to address related parameters consistently.
enum ParameterBundle: String, Codable, Sendable {
    case camera           // user/world transforms
    case position         // world position / translation
    case scale            // fractal/world scale
    case rotation         // world rotation
    case julia            // Julia set seeds / offsets
    case polarRotation    // polar phase / bulb rotations
    case color            // palette, color mix
    case lighting         // lighting/effects
    case fractalCore      // minDistance, folding limit, sphere radius
    case custom           // fallback when no specific bundle fits
}

// Layer ordering: UI defines the base, gesture overrides, precompute can override derived
// values, music applies an offset, and system sits at the top for authoritative writes.
enum ParameterLayer: String, Codable, Sendable {
    case ui
    case gesture
    case precompute
    case music
    case system
}

struct ParameterGroup: Hashable, Codable, Sendable {
    let id: String
    let title: String
}

// MARK: - Core Node Protocol

protocol ParameterNode: AnyObject, Identifiable {
    associatedtype Value

    var id: String { get }
    var name: String { get }
    var descriptionText: String { get }
    var group: ParameterGroup? { get }

    var isGestureMappable: Bool { get }
    var currentValue: Value { get set }
    var defaultValue: Value { get }
}

class AnyParameterNodeBase: @unchecked Sendable, Identifiable {
    let id: String
    let name: String
    let descriptionText: String
    let group: ParameterGroup?
    let icon: String
    let isGestureMappable: Bool

    init(id: String,
         name: String,
         descriptionText: String,
         group: ParameterGroup?,
         icon: String,
         isGestureMappable: Bool) {
        self.id = id
        self.name = name
        self.descriptionText = descriptionText
        self.group = group
        self.icon = icon
        self.isGestureMappable = isGestureMappable
    }
}

class BaseParameterNode<Value>: AnyParameterNodeBase, @unchecked Sendable, ParameterNode {
    var currentValue: Value

    let defaultValue: Value

    init(id: String,
         name: String,
         descriptionText: String,
         group: ParameterGroup?,
         icon: String,
         isGestureMappable: Bool,
         defaultValue: Value) {
        self.defaultValue = defaultValue
        self.currentValue = defaultValue
        super.init(
            id: id,
            name: name,
            descriptionText: descriptionText,
            group: group,
            icon: icon,
            isGestureMappable: isGestureMappable
        )
    }
}

class FloatParameterNode: BaseParameterNode<Float>, @unchecked Sendable {
    let range: ClosedRange<Float>
    let step: Float
    let readValue: @MainActor (UISettingsCache) -> Float
    let writeValue: @MainActor (UISettingsCache, Float) -> Void
    private var layerStack: ParameterLayerStack

    init(id: String,
         name: String,
         descriptionText: String,
         group: ParameterGroup?,
         icon: String,
         defaultValue: Float,
         range: ClosedRange<Float>,
         step: Float,
         isGestureMappable: Bool,
         readValue: @MainActor @escaping (UISettingsCache) -> Float,
         writeValue: @MainActor @escaping (UISettingsCache, Float) -> Void) {
        self.range = range
        self.step = step
        self.readValue = readValue
        self.writeValue = writeValue
        self.layerStack = ParameterLayerStack(defaultValue: defaultValue, range: range)
        super.init(id: id,
                   name: name,
                   descriptionText: descriptionText,
                   group: group,
                   icon: icon,
                   isGestureMappable: isGestureMappable,
                   defaultValue: defaultValue)
    }

    @discardableResult
    func applyLayer(_ layer: ParameterLayer,
                    value: Float,
                    smoothingTime: Float? = nil,
                    timestamp: TimeInterval = CFAbsoluteTimeGetCurrent()) -> Float {
        let resolved = layerStack.apply(layer: layer, value: value, smoothingTime: smoothingTime, timestamp: timestamp)
        super.currentValue = resolved
        return resolved
    }

    func resolvedValue(timestamp: TimeInterval = CFAbsoluteTimeGetCurrent()) -> Float {
        let resolved = layerStack.resolvedValue(at: timestamp)
        super.currentValue = resolved
        return resolved
    }

    func bootstrapBaseIfNeeded(from value: Float, timestamp: TimeInterval = CFAbsoluteTimeGetCurrent()) {
        layerStack.setBaseIfNeeded(value, timestamp: timestamp)
        super.currentValue = layerStack.resolvedValue(at: timestamp)
    }

    /// Clamp direct writes to the node's declared range.
    override var currentValue: Float {
        didSet {
            let clamped = min(range.upperBound, max(range.lowerBound, currentValue))
            if clamped != currentValue {
                super.currentValue = clamped
            }
        }
    }
}

final class BoolParameterNode: BaseParameterNode<Bool>, @unchecked Sendable {
    let readValue: @MainActor (UISettingsCache) -> Bool
    let writeValue: @MainActor (UISettingsCache, Bool) -> Void

    init(id: String,
         name: String,
         descriptionText: String,
         group: ParameterGroup?,
         icon: String,
         defaultValue: Bool,
         isGestureMappable: Bool,
         readValue: @MainActor @escaping (UISettingsCache) -> Bool,
         writeValue: @MainActor @escaping (UISettingsCache, Bool) -> Void) {
        self.readValue = readValue
        self.writeValue = writeValue
        super.init(id: id,
                   name: name,
                   descriptionText: descriptionText,
                   group: group,
                   icon: icon,
                   isGestureMappable: isGestureMappable,
                   defaultValue: defaultValue)
    }
}

// MARK: - Layered Value Stack

private struct ParameterLayerEntry {
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

struct ParameterLayerStack {
    /// Default smoothing time (seconds) applied to all non-music parameter changes.
    /// Provides frame-rate-independent exponential lerp that eliminates jitter/stagger
    /// from gesture input noise and discrete slider steps.
    static let defaultSmoothingTime: Float = 0.08

    private var ui: ParameterLayerEntry?
    private var gesture: ParameterLayerEntry?
    private var precompute: ParameterLayerEntry?
    private var music: ParameterLayerEntry?
    private var system: ParameterLayerEntry?

    private(set) var defaultValue: Float
    private(set) var range: ClosedRange<Float>

    init(defaultValue: Float, range: ClosedRange<Float>, timestamp: TimeInterval = CFAbsoluteTimeGetCurrent()) {
        self.defaultValue = defaultValue
        self.range = range
        self.ui = ParameterLayerEntry(rawValue: defaultValue, smoothingTime: nil, timestamp: timestamp)
    }


    mutating func setBaseIfNeeded(_ value: Float, timestamp: TimeInterval) {
        guard ui == nil else { return }
        ui = ParameterLayerEntry(rawValue: value, smoothingTime: nil, timestamp: timestamp)
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
        var gestureEntry = gesture
        var precomputeEntry = precompute
        var systemEntry = system
        var musicEntry = music

        var value = Self.resolve(entry: &uiEntry, at: timestamp) ?? defaultValue

        if let g = Self.resolve(entry: &gestureEntry, at: timestamp) {
            value = g
        }

        if let p = Self.resolve(entry: &precomputeEntry, at: timestamp) {
            value = p
        }

        if let s = Self.resolve(entry: &systemEntry, at: timestamp) {
            value = s
        }

        if let m = Self.resolve(entry: &musicEntry, at: timestamp) {
            value += m
        }

        // Write back smoothed state
        ui = uiEntry
        gesture = gestureEntry
        precompute = precomputeEntry
        system = systemEntry
        music = musicEntry

        return min(range.upperBound, max(range.lowerBound, value))
    }

    // MARK: - Internal helpers

    private func get(for layer: ParameterLayer) -> ParameterLayerEntry? {
        switch layer {
        case .ui: return ui
        case .gesture: return gesture
        case .precompute: return precompute
        case .music: return music
        case .system: return system
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
        case .gesture: gesture = entry
        case .precompute: precompute = entry
        case .music: music = entry
        case .system: system = entry
        }
    }
}

// MARK: - Batching + Registration

struct ParameterNodeBatch {
    let fractalType: FractalModelType
    let nodes: [AnyParameterNodeBase]
    let floatNodes: [FloatParameterNode]
    let boolNodes: [BoolParameterNode]
    let floatNodeByFormulaIndex: [Int: FloatParameterNode]

    init(fractalType: FractalModelType,
         nodes: [AnyParameterNodeBase],
         floatNodeByFormulaIndex: [Int: FloatParameterNode] = [:]) {
        self.fractalType = fractalType
        self.nodes = nodes
        self.floatNodes = nodes.compactMap { $0 as? FloatParameterNode }
        self.boolNodes = nodes.compactMap { $0 as? BoolParameterNode }
        self.floatNodeByFormulaIndex = floatNodeByFormulaIndex
    }
}

final class ParameterNodeRegistry: @unchecked Sendable {
    static let shared = ParameterNodeRegistry()

    struct MetricsSnapshot: Sendable {
        let batchRebuildCount: Int
        let nodeLookupCount: Int
        let nodeLookupDurationMs: Double
    }

    private var formulaBatches: [FractalModelType: ParameterNodeBatch] = [:]
    /// Core parameter nodes (fractalScale, colorMix).
    /// Keyed by their targetID string (e.g. "core.fractalScale").
    private(set) var coreNodes: [String: FloatParameterNode] = [:]
    /// Effect parameter nodes (glow, fog, bloom, hueSpeed, saturation).
    private(set) var effectNodes: [String: FloatParameterNode] = [:]
    private var batchRebuildCount: Int = 0
    private var nodeLookupCount: Int = 0

    private init() {
        buildCoreAndEffectNodes()
        rebuildFormulaBatches(force: true)
    }

    func metricsSnapshot() -> MetricsSnapshot {
        MetricsSnapshot(
            batchRebuildCount: batchRebuildCount,
            nodeLookupCount: nodeLookupCount,
            nodeLookupDurationMs: 0
        )
    }

    // MARK: - Core & Effect Node Registration

    func coreNode(id: String) -> FloatParameterNode? {
        coreNodes[id]
    }

    func effectNode(id: String) -> FloatParameterNode? {
        effectNodes[id]
    }

    /// One-time build of engine-level parameter nodes for core geometry and effects.
    /// IDs and ranges mirror the descriptors in ParameterOperationDispatcher.
    /// NOTE: minDistance / foldingLimit / sphereRadius are now catalog-driven formula
    /// params (built per-type in buildFormulaBatch) rather than hard-coded core nodes.
    private func buildCoreAndEffectNodes() {
        let coreGroup = ParameterGroup(id: "core.geometry", title: "Fractal Geometry")
        let effectGroup = ParameterGroup(id: "effect.postprocess", title: "Post-Processing")

        // --- Core geometry nodes ---

        coreNodes["core.fractalScale"] = FloatParameterNode(
            id: "core.fractalScale",
            name: "Fractal Scale",
            descriptionText: "Global fractal scale multiplier",
            group: coreGroup,
            icon: "arrow.up.left.and.arrow.down.right",
            defaultValue: 2.0,
            range: -5.0...8.0,
            step: 0.01,
            isGestureMappable: true,
            readValue: { $0.fractalScale },
            writeValue: { cache, v in cache.fractalScale = v; cache.push(\.targetFractalScale, value: v) }
        )

        coreNodes["core.colorMix"] = FloatParameterNode(
            id: "core.colorMix",
            name: "Color Mix",
            descriptionText: "Iteration-based color mix factor",
            group: coreGroup,
            icon: "paintpalette",
            defaultValue: 0.5,
            range: 0.0...1.0,
            step: 0.01,
            isGestureMappable: true,
            readValue: { $0.color.colorMix },
            writeValue: { cache, v in cache.color.colorMix = v; cache.push(\.colorMix, value: v) }
        )

        // --- Effect nodes ---
        effectNodes["effect.glow"] = FloatParameterNode(
            id: "effect.glow",
            name: "Glow",
            descriptionText: "Glow effect intensity",
            group: effectGroup,
            icon: "sun.max",
            defaultValue: 0.0,
            range: 0.0...2.0,
            step: 0.01,
            isGestureMappable: false,
            readValue: { $0.lighting.glowEffect.intensity },
            writeValue: { cache, v in cache.lighting.glowEffect.intensity = v; cache.push(\.glowEffect, value: cache.lighting.glowEffect) }
        )

        effectNodes["effect.fog"] = FloatParameterNode(
            id: "effect.fog",
            name: "Fog",
            descriptionText: "Fog effect intensity",
            group: effectGroup,
            icon: "cloud.fog",
            defaultValue: 0.32,
            range: 0.0...1.0,
            step: 0.01,
            isGestureMappable: false,
            readValue: { $0.lighting.fogEffect.intensity },
            writeValue: { cache, v in cache.lighting.fogEffect.intensity = v; cache.push(\.fogEffect, value: cache.lighting.fogEffect) }
        )

        effectNodes["effect.bloom"] = FloatParameterNode(
            id: "effect.bloom",
            name: "Bloom",
            descriptionText: "Bloom strength",
            group: effectGroup,
            icon: "sparkle",
            defaultValue: 0.0,
            range: 0.0...2.0,
            step: 0.01,
            isGestureMappable: false,
            readValue: { $0.lighting.bloomEffect.strength },
            writeValue: { cache, v in cache.lighting.bloomEffect.strength = v; cache.push(\.bloomEffect, value: cache.lighting.bloomEffect) }
        )

        effectNodes["effect.hueSpeed"] = FloatParameterNode(
            id: "effect.hueSpeed",
            name: "Hue Speed",
            descriptionText: "Hue rotation speed",
            group: effectGroup,
            icon: "arrow.trianglehead.2.clockwise.rotate.90",
            defaultValue: 0.0,
            range: 0.0...0.5,
            step: 0.001,
            isGestureMappable: false,
            readValue: { $0.lighting.hueRotationEffect.speed },
            writeValue: { cache, v in cache.lighting.hueRotationEffect.speed = v; cache.push(\.hueRotationEffect, value: cache.lighting.hueRotationEffect) }
        )

        effectNodes["effect.saturation"] = FloatParameterNode(
            id: "effect.saturation",
            name: "Saturation",
            descriptionText: "Color scheme saturation",
            group: effectGroup,
            icon: "drop.halffull",
            defaultValue: 2.0,
            range: 0.0...3.0,
            step: 0.01,
            isGestureMappable: false,
            readValue: { $0.color.colorSchemeSaturation },
            writeValue: { cache, v in cache.color.colorSchemeSaturation = v; cache.push(\.colorSchemeSaturation, value: v) }
        )
    }

    private func rebuildFormulaBatches(force: Bool = false) {
        var newBatches: [FractalModelType: ParameterNodeBatch] = [:]
        for type in FractalModelType.allCases {
            newBatches[type] = buildFormulaBatch(for: type)
        }
        formulaBatches = newBatches
        batchRebuildCount += 1
    }

    func formulaBatch(for type: FractalModelType) -> ParameterNodeBatch {
        if let cached = formulaBatches[type] { return cached }
        let built = buildFormulaBatch(for: type)
        formulaBatches[type] = built
        return built
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

    private func buildFormulaBatch(for type: FractalModelType) -> ParameterNodeBatch {
        guard let descriptor = FormulaCatalog.shared.descriptor(for: type) else {
            return ParameterNodeBatch(fractalType: type, nodes: [])
        }

        let group = ParameterGroup(id: descriptor.id, title: descriptor.name)
        var seenFormulaIndices: Set<Int> = []
        var floatNodeByFormulaIndex: [Int: FloatParameterNode] = [:]

        let nodes: [AnyParameterNodeBase] = descriptor.params.map { param in
            assert(
                seenFormulaIndices.insert(param.index).inserted,
                "Duplicate formula parameter index \(param.index) for fractal type \(type.rawValue)"
            )

            let label = displayLabel(for: param.name)
            let icon = icon(for: param.name)
            let id = "formula.\(type.rawValue).\(param.index).\(param.name)"
            let description = "\(descriptor.name) • \(param.name)"

            if param.isBool == true {
                return BoolParameterNode(
                    id: id,
                    name: label,
                    descriptionText: description,
                    group: group,
                    icon: icon,
                    defaultValue: param.default > 0.5,
                    isGestureMappable: false,
                    readValue: { cache in FormulaCatalog.getParam(cache.formulaParams, index: param.index) > 0.5 },
                    writeValue: { cache, value in
                        FormulaCatalog.setParam(&cache.formulaParams, index: param.index, value: value ? 1 : 0)
                        cache.renderSettings?.formulaParams = cache.formulaParams
                    }
                )
            }

            let node = FloatParameterNode(
                id: id,
                name: label,
                descriptionText: description,
                group: group,
                icon: icon,
                defaultValue: param.default,
                range: param.min...param.max,
                step: param.step,
                isGestureMappable: true,
                readValue: { cache in FormulaCatalog.getParam(cache.formulaParams, index: param.index) },
                writeValue: { cache, value in
                    FormulaCatalog.setParam(&cache.formulaParams, index: param.index, value: value)
                    cache.renderSettings?.formulaParams = cache.formulaParams
                }
            )

            floatNodeByFormulaIndex[param.index] = node
            return node
        }

        return ParameterNodeBatch(
            fractalType: type,
            nodes: nodes,
            floatNodeByFormulaIndex: floatNodeByFormulaIndex
        )
    }

    private func displayLabel(for rawName: String) -> String {
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

    private func icon(for rawName: String) -> String {
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

}
