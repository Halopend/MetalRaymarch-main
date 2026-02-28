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

enum GestureActionBinding: Codable, Hashable, Sendable {
    case core(FingerGestureAction)
    case parameter(GestureBindableParameter)

    static func availableBindings(for type: FractalModelType) -> [GestureActionBinding] {
        let core = type.supportedCoreGestureActions.map { GestureActionBinding.core($0) }
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
