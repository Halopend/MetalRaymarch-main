import Foundation

enum FingerGestureAction: Int32, CaseIterable, Codable, Hashable {
    case none         = 0
    case grab         = 1
    case minDistance  = 2
    case foldingLimit = 3
    case sphereRadius = 4
    case fractalScale = 5

    static let coreCases: [FingerGestureAction] = [.none, .grab, .minDistance, .foldingLimit, .sphereRadius, .fractalScale]

    var displayName: String {
        switch self {
        case .none: return "None"
        case .grab: return "Grab (Scale/Rotate)"
        case .minDistance: return "Min Distance"
        case .foldingLimit: return "Folding Limit"
        case .sphereRadius: return "Sphere Radius"
        case .fractalScale: return "Fractal Scale"
        }
    }

    var icon: String {
        switch self {
        case .none: return "xmark.circle"
        case .grab: return "hand.pinch"
        case .minDistance: return "circle.dashed"
        case .foldingLimit: return "square.dashed"
        case .sphereRadius: return "circle.circle"
        case .fractalScale: return "arrow.up.left.and.arrow.down.right"
        }
    }
}

struct GestureDisplayMetadata: Codable, Hashable, Sendable {
    let title: String
    let subtitle: String?
    let icon: String
}

struct GestureBindableParameter: Codable, Hashable, Sendable {
    let fractalType: FractalModelType
    let parameterNodeID: String
    let formulaIndex: Int?
    let display: GestureDisplayMetadata
}

struct GestureBindableTriplet: Codable, Hashable, Sendable {
    let fractalType: FractalModelType
    let groupName: String
    let xNodeID: String
    let yNodeID: String
    let zNodeID: String
    let xFormulaIndex: Int
    let yFormulaIndex: Int
    let zFormulaIndex: Int
    let range: ClosedRange<Float>
    let display: GestureDisplayMetadata

    private enum CodingKeys: String, CodingKey {
        case fractalType, groupName
        case xNodeID, yNodeID, zNodeID
        case xFormulaIndex, yFormulaIndex, zFormulaIndex
        case rangeLower, rangeUpper
        case display
    }

    init(fractalType: FractalModelType, groupName: String,
         xNodeID: String, yNodeID: String, zNodeID: String,
         xFormulaIndex: Int, yFormulaIndex: Int, zFormulaIndex: Int,
         range: ClosedRange<Float>, display: GestureDisplayMetadata) {
        self.fractalType = fractalType
        self.groupName = groupName
        self.xNodeID = xNodeID
        self.yNodeID = yNodeID
        self.zNodeID = zNodeID
        self.xFormulaIndex = xFormulaIndex
        self.yFormulaIndex = yFormulaIndex
        self.zFormulaIndex = zFormulaIndex
        self.range = range
        self.display = display
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fractalType = try c.decode(FractalModelType.self, forKey: .fractalType)
        groupName = try c.decode(String.self, forKey: .groupName)
        xNodeID = try c.decode(String.self, forKey: .xNodeID)
        yNodeID = try c.decode(String.self, forKey: .yNodeID)
        zNodeID = try c.decode(String.self, forKey: .zNodeID)
        xFormulaIndex = try c.decode(Int.self, forKey: .xFormulaIndex)
        yFormulaIndex = try c.decode(Int.self, forKey: .yFormulaIndex)
        zFormulaIndex = try c.decode(Int.self, forKey: .zFormulaIndex)
        let lo = try c.decode(Float.self, forKey: .rangeLower)
        let hi = try c.decode(Float.self, forKey: .rangeUpper)
        range = lo...hi
        display = try c.decode(GestureDisplayMetadata.self, forKey: .display)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fractalType, forKey: .fractalType)
        try c.encode(groupName, forKey: .groupName)
        try c.encode(xNodeID, forKey: .xNodeID)
        try c.encode(yNodeID, forKey: .yNodeID)
        try c.encode(zNodeID, forKey: .zNodeID)
        try c.encode(xFormulaIndex, forKey: .xFormulaIndex)
        try c.encode(yFormulaIndex, forKey: .yFormulaIndex)
        try c.encode(zFormulaIndex, forKey: .zFormulaIndex)
        try c.encode(range.lowerBound, forKey: .rangeLower)
        try c.encode(range.upperBound, forKey: .rangeUpper)
        try c.encode(display, forKey: .display)
    }
}

enum GestureActionBinding: Codable, Hashable, Sendable {
    case core(FingerGestureAction)
    case parameter(GestureBindableParameter)
    case parameterTriplet(GestureBindableTriplet)

    static func availableBindings(for type: FractalModelType) -> [GestureActionBinding] {
        let core = type.supportedCoreGestureActions.map { GestureActionBinding.core($0) }
        let triplets = ParameterNodeRegistry.shared.gestureBindableTriplets(for: type).map { GestureActionBinding.parameterTriplet($0) }
        let params = ParameterNodeRegistry.shared.gestureBindableParameters(for: type).map { GestureActionBinding.parameter($0) }
        return core + triplets + params
    }

    var icon: String {
        switch self {
        case .core(let action):
            return action.icon
        case .parameter(let descriptor):
            return descriptor.display.icon
        case .parameterTriplet(let triplet):
            return triplet.display.icon
        }
    }

    func contextualDisplayName(for currentType: FractalModelType) -> String {
        switch self {
        case .core(let action):
            return action.displayName
        case .parameter(let descriptor):
            if descriptor.fractalType == currentType {
                return descriptor.display.title
            }
            return "\(descriptor.fractalType.displayName): \(descriptor.display.title)"
        case .parameterTriplet(let triplet):
            if triplet.fractalType == currentType {
                return triplet.display.title
            }
            return "\(triplet.fractalType.displayName): \(triplet.display.title)"
        }
    }
}

enum FingerPair: Int, CaseIterable {
    case index = 1
    case middle = 2
    case ring = 3
    case pinky = 4

    var displayName: String {
        switch self {
        case .index: return "Index"
        case .middle: return "Middle"
        case .ring: return "Ring"
        case .pinky: return "Pinky"
        }
    }

    var icon: String {
        switch self {
        case .index: return "1.circle.fill"
        case .middle: return "2.circle.fill"
        case .ring: return "3.circle.fill"
        case .pinky: return "4.circle.fill"
        }
    }
}
