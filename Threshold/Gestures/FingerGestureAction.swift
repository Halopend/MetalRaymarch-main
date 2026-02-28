import Foundation

enum FingerGestureAction: Int32, CaseIterable, Codable, Hashable {
    case none         = 0
    case grab         = 1
    case minDistance  = 2
    case foldingLimit = 3
    case sphereRadius = 4
    case fractalScale = 5

    @available(*, deprecated, message: "Use GestureBindableParameter-based bindings instead.")
    case formulaParam0  = 100
    @available(*, deprecated, message: "Use GestureBindableParameter-based bindings instead.")
    case formulaParam1  = 101
    @available(*, deprecated, message: "Use GestureBindableParameter-based bindings instead.")
    case formulaParam2  = 102
    @available(*, deprecated, message: "Use GestureBindableParameter-based bindings instead.")
    case formulaParam3  = 103
    @available(*, deprecated, message: "Use GestureBindableParameter-based bindings instead.")
    case formulaParam4  = 104
    @available(*, deprecated, message: "Use GestureBindableParameter-based bindings instead.")
    case formulaParam5  = 105
    @available(*, deprecated, message: "Use GestureBindableParameter-based bindings instead.")
    case formulaParam6  = 106
    @available(*, deprecated, message: "Use GestureBindableParameter-based bindings instead.")
    case formulaParam7  = 107
    @available(*, deprecated, message: "Use GestureBindableParameter-based bindings instead.")
    case formulaParam8  = 108
    @available(*, deprecated, message: "Use GestureBindableParameter-based bindings instead.")
    case formulaParam9  = 109
    @available(*, deprecated, message: "Use GestureBindableParameter-based bindings instead.")
    case formulaParam10 = 110
    @available(*, deprecated, message: "Use GestureBindableParameter-based bindings instead.")
    case formulaParam11 = 111
    @available(*, deprecated, message: "Use GestureBindableParameter-based bindings instead.")
    case formulaParam12 = 112
    @available(*, deprecated, message: "Use GestureBindableParameter-based bindings instead.")
    case formulaParam13 = 113
    @available(*, deprecated, message: "Use GestureBindableParameter-based bindings instead.")
    case formulaParam14 = 114
    @available(*, deprecated, message: "Use GestureBindableParameter-based bindings instead.")
    case formulaParam15 = 115

    static let coreCases: [FingerGestureAction] = [.none, .grab, .minDistance, .foldingLimit, .sphereRadius, .fractalScale]

    init?(formulaParamIndex: Int) {
        switch formulaParamIndex {
        case 0: self = .formulaParam0
        case 1: self = .formulaParam1
        case 2: self = .formulaParam2
        case 3: self = .formulaParam3
        case 4: self = .formulaParam4
        case 5: self = .formulaParam5
        case 6: self = .formulaParam6
        case 7: self = .formulaParam7
        case 8: self = .formulaParam8
        case 9: self = .formulaParam9
        case 10: self = .formulaParam10
        case 11: self = .formulaParam11
        case 12: self = .formulaParam12
        case 13: self = .formulaParam13
        case 14: self = .formulaParam14
        case 15: self = .formulaParam15
        default: return nil
        }
    }

    var formulaParamIndex: Int? {
        switch self {
        case .formulaParam0: return 0
        case .formulaParam1: return 1
        case .formulaParam2: return 2
        case .formulaParam3: return 3
        case .formulaParam4: return 4
        case .formulaParam5: return 5
        case .formulaParam6: return 6
        case .formulaParam7: return 7
        case .formulaParam8: return 8
        case .formulaParam9: return 9
        case .formulaParam10: return 10
        case .formulaParam11: return 11
        case .formulaParam12: return 12
        case .formulaParam13: return 13
        case .formulaParam14: return 14
        case .formulaParam15: return 15
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .grab: return "Grab (Scale/Rotate)"
        case .minDistance: return "Min Distance"
        case .foldingLimit: return "Folding Limit"
        case .sphereRadius: return "Sphere Radius"
        case .fractalScale: return "Fractal Scale"
        default: return "Formula Param"
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
        default: return "slider.horizontal.3"
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

enum GestureActionBinding: Codable, Hashable, Sendable {
    case core(FingerGestureAction)
    case parameter(GestureBindableParameter)

    static func availableBindings(for type: FractalModelType) -> [GestureActionBinding] {
        let core = FingerGestureAction.coreCases.map { GestureActionBinding.core($0) }
        let params = ParameterNodeRegistry.shared.gestureBindableParameters(for: type).map { GestureActionBinding.parameter($0) }
        return core + params
    }

    var icon: String {
        switch self {
        case .core(let action):
            return action.icon
        case .parameter(let descriptor):
            return descriptor.display.icon
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
