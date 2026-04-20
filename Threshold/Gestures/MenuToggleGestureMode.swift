import Foundation

enum MenuToggleGestureMode: Int32, CaseIterable, Codable {
    case middleToPalm = 0
    case middleAndRingToPalm = 1
    case fist = 2
    case wristTap = 3
    case thumbToIndexPalmUp = 4

    var displayName: String {
        switch self {
        case .middleToPalm: return "Middle to Palm"
        case .middleAndRingToPalm: return "Middle + Ring to Palm"
        case .fist: return "Fist"
        case .wristTap: return "Wrist Tap"
        case .thumbToIndexPalmUp: return "Thumb-Index (Palm Up)"
        }
    }

    var icon: String {
        switch self {
        case .middleToPalm: return "hand.point.up.left.fill"
        case .middleAndRingToPalm: return "hand.raised.fingers.spread"
        case .fist: return "hand.closed.fill"
        case .wristTap: return "hand.tap.fill"
        case .thumbToIndexPalmUp: return "hand.thumbsup.fill"
        }
    }

    /// Whether this mode requires both hands to be tracked
    var requiresBothHands: Bool {
        switch self {
        case .wristTap: return true
        default: return false
        }
    }
}
