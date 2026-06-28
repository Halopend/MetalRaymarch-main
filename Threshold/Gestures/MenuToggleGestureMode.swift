import Foundation

/// The menu-opening gestures Threshold supports. Deliberately limited to the
/// three styles surfaced at first launch (`MenuGestureStarterStyle`) — the
/// raw values are kept stable (1/3/6) so configs written by builds that had
/// the wider list still decode the kept modes correctly.
enum MenuToggleGestureMode: Int32, CaseIterable, Codable {
    case middleAndRingToPalm = 1
    case wristTap = 3
    case middleOrRingToPalm = 6

    var displayName: String {
        switch self {
        case .middleAndRingToPalm: return "Middle + Ring to Palm"
        case .wristTap: return "Wrist Tap"
        case .middleOrRingToPalm: return "Middle or Ring to Palm"
        }
    }

    var icon: String {
        switch self {
        case .middleAndRingToPalm: return "hand.raised.fingers.spread"
        case .wristTap: return "hand.tap.fill"
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

    /// Robust decode: configs written by an older build may carry a now-removed
    /// mode's raw value (e.g. the retired `fist` = 2). Fall back to the default
    /// instead of throwing and discarding the user's whole gesture config.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int32.self)
        self = MenuToggleGestureMode(rawValue: raw) ?? .middleOrRingToPalm
    }
}

/// Friendly-named presentation of the supported `MenuToggleGestureMode`s,
/// surfaced at first launch so new users can pick how they open the menu.
/// Settings > Gestures exposes the same set.
///
/// Background: some people naturally rest their hand with the index finger
/// curled (as if mid-tap), which can fight an index-based menu gesture — so all
/// three starter styles avoid the index finger.
enum MenuGestureStarterStyle: Int32, CaseIterable, Identifiable {
    /// "Web-shooter" pose — curl the middle + ring fingers to the palm while
    /// index, pinky, and thumb stay extended.
    case webslinger
    /// Forgiving one-handed curl — tap *either* the middle or ring finger to the
    /// palm. This is the default.
    case palmer
    /// Two-handed — tap your wrist with your other hand.
    case wristTap

    var id: Int32 { rawValue }

    /// The underlying engine mode this starter style maps to.
    var mode: MenuToggleGestureMode {
        switch self {
        case .webslinger: return .middleAndRingToPalm
        case .palmer:     return .middleOrRingToPalm
        case .wristTap:   return .wristTap
        }
    }

    var title: String {
        switch self {
        case .webslinger: return "The Webslinger"
        case .palmer:     return "The Palmer"
        case .wristTap:   return "Wrist Tap"
        }
    }

    var subtitle: String {
        switch self {
        case .webslinger:
            return "Curl your middle and ring fingers to your palm — like firing a web. Index and pinky stay out."
        case .palmer:
            return "Tap your middle or ring finger to your palm. Forgiving, one-handed, and quick to recover."
        case .wristTap:
            return "Tap your wrist with your other hand. Two-handed and very hard to trigger by accident."
        }
    }

    /// Reuse the engine mode's (already symbol-validity-audited) SF Symbol so no
    /// new icon names slip in that could render blank on visionOS.
    var icon: String { mode.icon }

    /// The starter style whose `mode` matches, if any. Used to pre-select the
    /// card for the user's current setting.
    static func style(for mode: MenuToggleGestureMode) -> MenuGestureStarterStyle? {
        allCases.first { $0.mode == mode }
    }
}
