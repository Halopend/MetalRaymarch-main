import Foundation

enum ParameterDebugLogGate {
    static var isEnabled: Bool = false

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        print("🧭 \(message())")
    }
}

// MARK: - Shared Parameter Taxonomy

enum ParameterSection: String, CaseIterable, Codable, Sendable {
    case fractal
    case gestures
    case effects
    case animation
}

struct ParameterGroup: Hashable, Codable, Sendable {
    let id: String
    let title: String
}

enum ParameterNodeSource: String, Codable, Sendable {
    case core
    case formula
}

// MARK: - Core Node Protocol

protocol ParameterNode: AnyObject, Identifiable {
    associatedtype Value

    var id: String { get }
    var name: String { get }
    var descriptionText: String { get }
    var section: ParameterSection { get }
    var group: ParameterGroup? { get }
    var source: ParameterNodeSource { get }

    var isDirty: Bool { get }
    func markDirty()
    func markClean()

    var isGestureMappable: Bool { get }
    var currentValue: Value { get set }
    var defaultValue: Value { get }
    func resetToDefault()
}

class AnyParameterNodeBase: @unchecked Sendable, Identifiable {
    let id: String
    let name: String
    let descriptionText: String
    let section: ParameterSection
    let group: ParameterGroup?
    let source: ParameterNodeSource
    let icon: String
    let isGestureMappable: Bool

    fileprivate(set) var isDirty: Bool = false

    init(id: String,
         name: String,
         descriptionText: String,
         section: ParameterSection,
         group: ParameterGroup?,
         source: ParameterNodeSource,
         icon: String,
         isGestureMappable: Bool) {
        self.id = id
        self.name = name
        self.descriptionText = descriptionText
        self.section = section
        self.group = group
        self.source = source
        self.icon = icon
        self.isGestureMappable = isGestureMappable
    }

    func markDirty() { isDirty = true }
    func markClean() { isDirty = false }
}

class BaseParameterNode<Value>: AnyParameterNodeBase, ParameterNode {
    var currentValue: Value {
        didSet { markDirty() }
    }

    let defaultValue: Value

    init(id: String,
         name: String,
         descriptionText: String,
         section: ParameterSection,
         group: ParameterGroup?,
         source: ParameterNodeSource,
         icon: String,
         isGestureMappable: Bool,
         defaultValue: Value) {
        self.defaultValue = defaultValue
        self.currentValue = defaultValue
        super.init(
            id: id,
            name: name,
            descriptionText: descriptionText,
            section: section,
            group: group,
            source: source,
            icon: icon,
            isGestureMappable: isGestureMappable
        )
    }

    func resetToDefault() { currentValue = defaultValue }
}

class FloatParameterNode: BaseParameterNode<Float> {
    let range: ClosedRange<Float>
    let step: Float
    let gestureAction: FingerGestureAction?
    let readValue: (UISettingsCache) -> Float
    let writeValue: (UISettingsCache, Float) -> Void

    init(id: String,
         name: String,
         descriptionText: String,
         section: ParameterSection,
         group: ParameterGroup?,
         source: ParameterNodeSource,
         icon: String,
         defaultValue: Float,
         range: ClosedRange<Float>,
         step: Float,
         isGestureMappable: Bool,
         readValue: @escaping (UISettingsCache) -> Float,
         writeValue: @escaping (UISettingsCache, Float) -> Void) {
        self.range = range
        self.step = step
        self.readValue = readValue
        self.writeValue = writeValue
        super.init(id: id,
                   name: name,
                   descriptionText: descriptionText,
                   section: section,
                   group: group,
                   source: source,
                   icon: icon,
                   isGestureMappable: isGestureMappable,
                   defaultValue: defaultValue)
    }

    @inline(__always)
    func lerp(from a: Float, to b: Float, t: Float) -> Float {
        let clamped = max(0, min(1, t))
        return a + (b - a) * clamped
    }
}

final class BoolParameterNode: BaseParameterNode<Bool> {
    let readValue: (UISettingsCache) -> Bool
    let writeValue: (UISettingsCache, Bool) -> Void

    init(id: String,
         name: String,
         descriptionText: String,
         section: ParameterSection,
         group: ParameterGroup?,
         source: ParameterNodeSource,
         icon: String,
         defaultValue: Bool,
         isGestureMappable: Bool,
         readValue: @escaping (UISettingsCache) -> Bool,
         writeValue: @escaping (UISettingsCache, Bool) -> Void) {
        self.readValue = readValue
        self.writeValue = writeValue
        super.init(id: id,
                   name: name,
                   descriptionText: descriptionText,
                   section: section,
                   group: group,
                   source: source,
                   icon: icon,
                   isGestureMappable: isGestureMappable,
                   defaultValue: defaultValue)
    }
}

// MARK: - Optional Smoothing Primitive

final class FloatDelayBuffer {
    private(set) var current: Float
    private var target: Float
    private(set) var responseTime: Float

    init(initialValue: Float, responseTime: Float) {
        self.current = initialValue
        self.target = initialValue
        self.responseTime = max(0.001, responseTime)
    }

    func setTarget(_ value: Float) { target = value }

    func setResponseTime(_ value: Float) { responseTime = max(0.001, value) }

    func snap(to value: Float) {
        current = value
        target = value
    }

    func update(deltaTime: Float) {
        guard deltaTime > 0 else { return }
        let alpha = 1 - exp(-deltaTime / max(0.001, responseTime))
        current += (target - current) * alpha
    }
}

final class SmoothedFloatParameterNode: FloatParameterNode {
    private(set) var smoothedValue: Float
    private var delayBuffer: FloatDelayBuffer
    private var smoothingTime: Float

    init(id: String,
         name: String,
         descriptionText: String,
         section: ParameterSection,
         group: ParameterGroup?,
         source: ParameterNodeSource,
         icon: String,
         defaultValue: Float,
         range: ClosedRange<Float>,
         step: Float,
         smoothingTime: Float,
         isGestureMappable: Bool,
         readValue: @escaping (UISettingsCache) -> Float,
         writeValue: @escaping (UISettingsCache, Float) -> Void) {
        self.smoothingTime = max(0, smoothingTime)
        self.smoothedValue = defaultValue
        self.delayBuffer = FloatDelayBuffer(initialValue: defaultValue, responseTime: max(0.001, smoothingTime))
        super.init(id: id,
                   name: name,
                   descriptionText: descriptionText,
                   section: section,
                   group: group,
                   source: source,
                   icon: icon,
                   defaultValue: defaultValue,
                   range: range,
                   step: step,
                   isGestureMappable: isGestureMappable,
                   readValue: readValue,
                   writeValue: writeValue)
    }

    override var currentValue: Float {
        didSet {
            delayBuffer.setTarget(currentValue)
            markDirty()
        }
    }

    func updateSmoothing(deltaTime: Float) {
        let previous = smoothedValue
        if smoothingTime <= 0 {
            delayBuffer.snap(to: currentValue)
            smoothedValue = currentValue
        } else {
            delayBuffer.setResponseTime(smoothingTime)
            delayBuffer.update(deltaTime: deltaTime)
            smoothedValue = delayBuffer.current
        }
        if abs(previous - smoothedValue) > .ulpOfOne || abs(currentValue - smoothedValue) > .ulpOfOne {
            markDirty()
        } else {
            markClean()
        }
    }

    func setSmoothingTime(_ value: Float) {
        smoothingTime = max(0, value)
        delayBuffer.setResponseTime(max(0.001, smoothingTime))
        markDirty()
    }

    func snap(to value: Float) {
        delayBuffer.snap(to: value)
        smoothedValue = value
        super.currentValue = value
        markDirty()
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
    private var batchRebuildCount: Int = 0
    private var nodeLookupCount: Int = 0
    private var nodeLookupDuration: CFTimeInterval = 0
    private var lastRebuildTimestamp: CFTimeInterval = 0
    private let minRebuildInterval: CFTimeInterval = 0.25

    private init() {
        rebuildFormulaBatches(force: true)
    }

    func rebuildFormulaBatches(force: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        if !force, now - lastRebuildTimestamp < minRebuildInterval {
            ParameterDebugLogGate.log("Skipped formula batch rebuild to avoid per-frame churn.")
            return
        }
        var newBatches: [FractalModelType: ParameterNodeBatch] = [:]
        for type in FractalModelType.allCases {
            newBatches[type] = buildFormulaBatch(for: type)
        }
        formulaBatches = newBatches
        batchRebuildCount += 1
        lastRebuildTimestamp = now
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

    func formulaGestureActions(for type: FractalModelType) -> [FingerGestureAction] {
        formulaBatch(for: type).floatNodes.compactMap { node in
            guard let formulaIndex = formulaIndex(for: node, type: type) else { return nil }
            return FingerGestureAction(formulaParamIndex: formulaIndex)
        }
    }

    func formulaActionMapping(for type: FractalModelType,
                              action: FingerGestureAction) -> (formulaIndex: Int, node: FloatParameterNode)? {
        guard let formulaIndex = action.formulaParamIndex,
              let node = node(for: type, formulaIndex: formulaIndex) else {
            return nil
        }
        return (formulaIndex, node)
    }

    func node(for type: FractalModelType, action: FingerGestureAction) -> FloatParameterNode? {
        formulaActionMapping(for: type, action: action)?.node
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

    func fractalParameterMappingJSON(prettyPrinted: Bool = true) -> String? {
        struct Mapping: Codable {
            struct FractalEntry: Codable {
                let fractalType: Int32
                let fractalName: String
                let parameters: [String]
            }
            let version: Int
            let fractals: [FractalEntry]
        }

        let payload = Mapping(
            version: 2,
            fractals: FractalModelType.allCases.map { type in
                .init(fractalType: type.rawValue,
                      fractalName: type.displayName,
                      parameters: formulaBatch(for: type).nodes.map(\.id))
            }
        )

        let encoder = JSONEncoder()
        if prettyPrinted { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        guard let data = try? encoder.encode(payload) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func buildFormulaBatch(for type: FractalModelType) -> ParameterNodeBatch {
        guard let descriptor = FormulaCatalog.shared.descriptor(for: type),
              !(descriptor.usesMandelboxParams ?? false) else {
            return ParameterNodeBatch(fractalType: type, nodes: [])
        }

        let group = ParameterGroup(id: descriptor.id, title: descriptor.name)
        var seenFormulaIndices: Set<Int> = []
        var floatNodeByFormulaIndex: [Int: FloatParameterNode] = [:]

        let nodes = descriptor.params.map { param in
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
                    section: .fractal,
                    group: group,
                    source: .formula,
                    icon: icon,
                    defaultValue: param.default > 0.5,
                    isGestureMappable: false,
                    readValue: { cache in FormulaCatalog.getParam(cache.formulaParams, index: param.index) > 0.5 },
                    writeValue: { cache, value in cache.pushFormulaParam(index: param.index, value: value ? 1 : 0) }
                )
            }

            let node = SmoothedFloatParameterNode(
                id: id,
                name: label,
                descriptionText: description,
                section: .fractal,
                group: group,
                source: .formula,
                icon: icon,
                defaultValue: param.default,
                range: param.min...param.max,
                step: param.step,
                smoothingTime: 0,
                isGestureMappable: true,
                readValue: { cache in FormulaCatalog.getParam(cache.formulaParams, index: param.index) },
                writeValue: { cache, value in cache.pushFormulaParam(index: param.index, value: value) }
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

    private func formulaIndex(for node: FloatParameterNode, type: FractalModelType) -> Int? {
        let prefix = "formula.\(type.rawValue)."
        guard node.id.hasPrefix(prefix) else { return nil }
        let suffix = node.id.dropFirst(prefix.count)
        guard let segment = suffix.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true).first else { return nil }
        return Int(segment)
    }
}
