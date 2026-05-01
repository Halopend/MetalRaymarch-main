import Foundation

/// Estimated user posture inferred from the Apple Vision Pro's world-space head height.
///
/// ARKit's `WorldTrackingProvider` builds a persistent world map; the device's Y coordinate
/// in that map typically reflects the user's eye height above the room floor, so it can
/// discriminate sitting from standing across sessions.
///
/// Values near zero indicate that world tracking has not yet produced a valid fix
/// (e.g. world-sensing permission not granted, session just started).
enum UserPosture: String, Codable, Sendable {
    /// World-tracking data not yet available or head height too small to be meaningful.
    case unknown
    /// Head height below the sitting/standing threshold — user is likely seated.
    case sitting
    /// Head height at or above the sitting/standing threshold — user is likely standing.
    case standing

    // MARK: - Detection

    /// Metres below which a tracked height is classified as sitting.
    static let sittingThreshold: Float = 1.38

    /// Minimum height (m) that indicates world tracking has produced a real fix.
    static let minimumTrackedHeight: Float = 0.30

    /// Classify posture from the device's world-space Y position.
    /// - Parameter headHeightMeters: Y component of `deviceAnchor.originFromAnchorTransform.columns.3`.
    static func detect(headHeightMeters: Float) -> UserPosture {
        guard headHeightMeters > minimumTrackedHeight else { return .unknown }
        return headHeightMeters < sittingThreshold ? .sitting : .standing
    }

    // MARK: - Display

    var displayName: String {
        switch self {
        case .unknown:  return "Unknown"
        case .sitting:  return "Sitting"
        case .standing: return "Standing"
        }
    }

    var icon: String {
        switch self {
        case .unknown:  return "questionmark.circle"
        case .sitting:  return "chair"
        case .standing: return "figure.stand"
        }
    }
}
