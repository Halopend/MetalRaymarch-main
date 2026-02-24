import Foundation

enum MenuToggleGestureMode: Int32, CaseIterable, Codable {
    case middleToPalm = 0
    case middleAndRingToPalm = 1
    case fist = 2

    var displayName: String {
        switch self {
        case .middleToPalm: return "Middle to Palm"
        case .middleAndRingToPalm: return "Middle + Ring to Palm"
        case .fist: return "Fist"
        }
    }

    var icon: String {
        switch self {
        case .middleToPalm: return "hand.point.up.left.fill"
        case .middleAndRingToPalm: return "hand.raised.fingers.spread"
        case .fist: return "hand.closed.fill"
        }
    }
}
