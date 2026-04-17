import Foundation

/// Axis constraint for single-hand scalar drag gestures.
enum GestureDirection: String, CaseIterable, Codable, Hashable, Sendable {
    case vertical    // Y-axis finger movement (up/down) — default
    case horizontal  // X-axis finger movement (left/right)

    var displayName: String {
        switch self {
        case .vertical:   return "Vertical"
        case .horizontal: return "Horizontal"
        }
    }

    var icon: String {
        switch self {
        case .vertical:   return "arrow.up.arrow.down"
        case .horizontal: return "arrow.left.arrow.right"
        }
    }

    var suffix: String {
        switch self {
        case .vertical:   return "V"
        case .horizontal: return "H"
        }
    }
}

enum FingerGestureAction: Int32, CaseIterable, Codable, Hashable {
    case none         = 0
    case grab         = 1
    case minDistance  = 2
    case foldingLimit = 3
    case sphereRadius = 4
    case fractalScale = 5
    case translate    = 6

    static let coreCases: [FingerGestureAction] = [.none, .grab, .minDistance, .foldingLimit, .sphereRadius, .fractalScale, .translate]

    var displayName: String {
        switch self {
        case .none: return "None"
        case .grab: return "Grab (Scale/Rotate)"
        case .minDistance: return "Min Distance"
        case .foldingLimit: return "Folding Limit"
        case .sphereRadius: return "Sphere Radius"
        case .fractalScale: return "Fractal Scale"
        case .translate: return "Translate (Position)"
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
        case .translate: return "move.3d"
        }
    }
}

// MARK: - Per-Hand Gesture Binding Model

enum GestureHandMode: String, CaseIterable, Codable, Hashable, Sendable {
    case left
    case right
    case both

    var displayName: String {
        switch self {
        case .left:  return "Left Hand"
        case .right: return "Right Hand"
        case .both:  return "Both Hands"
        }
    }

    var icon: String {
        switch self {
        case .left:  return "hand.raised.fingers.spread"
        case .right: return "hand.raised.fingers.spread.fill"
        case .both:  return "hands.sparkles"
        }
    }
}

enum FingerDigit: Int, CaseIterable, Codable, Hashable, Sendable {
    case index  = 1
    case middle = 2
    case ring   = 3

    var displayName: String {
        switch self {
        case .index:  return "Index"
        case .middle: return "Middle"
        case .ring:   return "Ring"
        }
    }

    var icon: String {
        switch self {
        case .index:  return "1.circle.fill"
        case .middle: return "2.circle.fill"
        case .ring:   return "3.circle.fill"
        }
    }
}

struct GestureSlot: Hashable, Codable, Sendable {
    let hand: GestureHandMode
    let finger: FingerDigit
    /// Direction constraint for single-hand scalar bindings.
    /// `.vertical` (default) = Y-axis drag, `.horizontal` = X-axis drag.
    /// Both-hand slots ignore this (always nil).
    var direction: GestureDirection?

    /// UserDefaults persistence key, e.g. "leftIndexBinding" or "leftIndexBindingH"
    var persistenceKey: String {
        let base = "\(hand.rawValue)\(finger.displayName)Binding"
        guard let dir = direction, dir == .horizontal else { return base }
        return base + "H"
    }

    /// Legacy key (no direction suffix) for backward-compatible loading.
    var legacyPersistenceKey: String {
        "\(hand.rawValue)\(finger.displayName)Binding"
    }

    init(hand: GestureHandMode, finger: FingerDigit, direction: GestureDirection? = nil) {
        self.hand = hand
        self.finger = finger
        self.direction = (hand == .both) ? nil : direction
    }

    static let allSlots: [GestureSlot] = {
        var slots: [GestureSlot] = []
        for hand in GestureHandMode.allCases {
            for finger in FingerDigit.allCases {
                if hand == .both {
                    slots.append(GestureSlot(hand: hand, finger: finger))
                } else {
                    slots.append(GestureSlot(hand: hand, finger: finger, direction: .vertical))
                    slots.append(GestureSlot(hand: hand, finger: finger, direction: .horizontal))
                }
            }
        }
        return slots
    }()

    /// Slots for the old 9-slot layout (backward compatible — no direction, or vertical only).
    static let legacySlots: [GestureSlot] = {
        var slots: [GestureSlot] = []
        for hand in GestureHandMode.allCases {
            for finger in FingerDigit.allCases {
                slots.append(GestureSlot(hand: hand, finger: finger))
            }
        }
        return slots
    }()

    static func slots(for hand: GestureHandMode) -> [GestureSlot] {
        if hand == .both {
            return FingerDigit.allCases.map { GestureSlot(hand: hand, finger: $0) }
        }
        return FingerDigit.allCases.flatMap { finger in
            [GestureSlot(hand: hand, finger: finger, direction: .vertical),
             GestureSlot(hand: hand, finger: finger, direction: .horizontal)]
        }
    }
}

struct GestureDisplayMetadata: Codable, Hashable, Sendable {
    let title: String
    let subtitle: String?
    let icon: String
}

struct GestureBindableParameter: Codable, Sendable, Hashable {
    let fractalType: FractalModelType
    let parameterNodeID: String
    let formulaIndex: Int?
    let display: GestureDisplayMetadata

    // Compare by semantic identity only — display metadata is cosmetic.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.fractalType == rhs.fractalType && lhs.parameterNodeID == rhs.parameterNodeID
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(fractalType)
        hasher.combine(parameterNodeID)
    }
}

struct GestureBindableTriplet: Codable, Sendable, Hashable {
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

    // Compare by semantic identity only — display metadata is cosmetic.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.fractalType == rhs.fractalType && lhs.groupName == rhs.groupName
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(fractalType)
        hasher.combine(groupName)
    }

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

    static func availableBindings(for type: FractalModelType, handMode: GestureHandMode? = nil) -> [GestureActionBinding] {
        let allCore = type.supportedCoreGestureActions
        let filteredCore: [FingerGestureAction]
        switch handMode {
        case .left, .right:
            // Single-hand: translate, none, and scalar/triplet params
            filteredCore = allCore.filter { $0 == .none || $0 == .translate }
        case .both:
            // Two-hand: grab, core shape params, scale, none (no translate)
            filteredCore = allCore.filter { $0 != .translate }
        case nil:
            filteredCore = allCore
        }
        let core = filteredCore.map { GestureActionBinding.core($0) }

        let triplets: [GestureActionBinding]
        let params: [GestureActionBinding]
        switch handMode {
        case .both:
            // Two-hand only supports scalar params, not triplets
            triplets = []
            params = ParameterNodeRegistry.shared.gestureBindableParameters(for: type).map { .parameter($0) }
        case .left, .right:
            // Single-hand supports triplets and scalar params (1D drag)
            triplets = ParameterNodeRegistry.shared.gestureBindableTriplets(for: type).map { .parameterTriplet($0) }
            params = ParameterNodeRegistry.shared.gestureBindableParameters(for: type).map { .parameter($0) }
        case nil:
            triplets = ParameterNodeRegistry.shared.gestureBindableTriplets(for: type).map { .parameterTriplet($0) }
            params = ParameterNodeRegistry.shared.gestureBindableParameters(for: type).map { .parameter($0) }
        }
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

