import Foundation

enum MenuToggleGestureMode: Int32, CaseIterable, Codable {
    case middleToPalm = 0
    case middleAndRingToPalm = 1
    case fist = 2
    case wristTap = 3
    case thumbToIndexPalmUp = 4
    case ringToPalm = 5
    case middleOrRingToPalm = 6

    var displayName: String {
        switch self {
        case .middleToPalm: return "Middle to Palm"
        case .middleAndRingToPalm: return "Middle + Ring to Palm"
        case .fist: return "Fist"
        case .wristTap: return "Wrist Tap"
        case .thumbToIndexPalmUp: return "Thumb-Index (Palm Up)"
        case .ringToPalm: return "Ring to Palm"
        case .middleOrRingToPalm: return "Middle or Ring to Palm"
        }
    }

    var icon: String {
        switch self {
        case .middleToPalm: return "hand.point.up.left.fill"
        case .middleAndRingToPalm: return "hand.raised.fingers.spread"
        case .fist: return "hand.rays.fill"  // no fist glyph exists on visionOS; "hand.closed.fill" renders blank
        case .wristTap: return "hand.tap.fill"
        case .thumbToIndexPalmUp: return "hand.thumbsup.fill"
        case .ringToPalm: return "hand.point.up.fill"
        case .middleOrRingToPalm: return "hand.raised.fill"
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
