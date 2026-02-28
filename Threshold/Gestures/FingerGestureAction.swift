import Foundation

enum FingerGestureAction: Int32, CaseIterable, Codable {
    case none         = 0
    case grab         = 1
    case minDistance  = 2
    case foldingLimit = 3
    case sphereRadius = 4
    case fractalScale = 5

    case formulaParam0  = 100
    case formulaParam1  = 101
    case formulaParam2  = 102
    case formulaParam3  = 103
    case formulaParam4  = 104
    case formulaParam5  = 105
    case formulaParam6  = 106
    case formulaParam7  = 107
    case formulaParam8  = 108
    case formulaParam9  = 109
    case formulaParam10 = 110
    case formulaParam11 = 111
    case formulaParam12 = 112
    case formulaParam13 = 113
    case formulaParam14 = 114
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

    static func availableActions(for type: FractalModelType) -> [FingerGestureAction] {
        coreCases + ParameterNodeRegistry.shared.formulaGestureActions(for: type)
    }

    func contextualDisplayName(for type: FractalModelType) -> String {
        guard formulaParamIndex != nil,
              let node = ParameterNodeRegistry.shared.node(for: type, action: self) else {
            return displayName
        }
        return "\(type.displayName): \(node.name)"
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
