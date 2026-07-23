import Foundation

/// Apple platform families supported by Threshold. Keep this value explicit in
/// shared models so platform filtering can be tested without recompiling for a
/// different destination.
enum AppPlatform: String, CaseIterable, Codable, Sendable {
    case macOS
    case iPadOS
    case visionOS

    var displayName: String {
        switch self {
        case .macOS: return "macOS"
        case .iPadOS: return "iPadOS"
        case .visionOS: return "visionOS"
        }
    }
}

/// Runtime-visible platform features. Compile-time checks belong only in the
/// app entry point or the native adapter that creates a `PlatformProfile`.
struct PlatformCapability: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt16

    static let pointerViewport       = Self(rawValue: 1 << 0)
    static let touchViewport         = Self(rawValue: 1 << 1)
    static let hardwareKeyboard      = Self(rawValue: 1 << 2)
    static let tiltInput             = Self(rawValue: 1 << 3)
    static let handTracking          = Self(rawValue: 1 << 4)
    static let spatialMenu           = Self(rawValue: 1 << 5)
    static let gestureEditing        = Self(rawValue: 1 << 6)
    static let musicLibraryBrowsing  = Self(rawValue: 1 << 7)
    static let separateWindows       = Self(rawValue: 1 << 8)
    static let twoDimensionalRadial  = Self(rawValue: 1 << 9)
}

struct PlatformProfile: Equatable, Hashable, Sendable {
    let platform: AppPlatform
    let capabilities: PlatformCapability

    func supports(_ capability: PlatformCapability) -> Bool {
        capabilities.contains(capability)
    }

    static let macOS = PlatformProfile(
        platform: .macOS,
        capabilities: [
            .pointerViewport, .hardwareKeyboard, .separateWindows,
            .twoDimensionalRadial,
        ]
    )

    static let iPadOS = PlatformProfile(
        platform: .iPadOS,
        capabilities: [
            .touchViewport, .hardwareKeyboard, .tiltInput,
            .musicLibraryBrowsing, .twoDimensionalRadial,
        ]
    )

    static let visionOS = PlatformProfile(
        platform: .visionOS,
        capabilities: [
            .handTracking, .spatialMenu, .gestureEditing,
            .musicLibraryBrowsing, .separateWindows,
        ]
    )

    static let all: [PlatformProfile] = [.macOS, .iPadOS, .visionOS]

    static var current: PlatformProfile {
        #if os(macOS)
        .macOS
        #elseif os(visionOS)
        .visionOS
        #else
        .iPadOS
        #endif
    }
}
