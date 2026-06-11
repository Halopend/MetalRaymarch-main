import Foundation

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Geometry State - Stable Geometry Rendering
// ═══════════════════════════════════════════════════════════════════════════════
// Tracks whether geometry parameters (minDistance, foldingLimit, sphereRadius,
// fractalScale) are actively changing or have settled. When stable, the renderer
// can rely more heavily on temporal depth reuse and higher step multipliers.
// ═══════════════════════════════════════════════════════════════════════════════

enum GeometryState: Int, CaseIterable {
    case dynamic   = 0  // Geometry parameters are actively changing
    case settling  = 1  // Parameters stopped changing, waiting for confirmation
    case stable    = 2  // Parameters confirmed stable, temporal depth reuse can stay aggressive
}

// Lighting mode controls animated light movement and audio reactivity
enum LightingMode: Int32, CaseIterable {
    case staticLight = 0    // Lights stay fixed (no wobble, no animation)
    case animated = 1       // Original animated lighting (pulsing, moving spotlight)
    case audioReactive = 2  // Lights respond to audio/music input
    case visualizer = 3     // Dedicated audio visualizer mode (dramatic, beat-synced)

    var displayName: String {
        switch self {
        case .staticLight: return "Static"
        case .animated: return "Animated"
        case .audioReactive: return "Audio Reactive"
        case .visualizer: return "Visualizer"
        }
    }
}

enum SphericalInversionMode: Int32, CaseIterable {
    case off = 0
    case outwardIn = 1

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .outwardIn: return "Outward In"
        }
    }
}

// MARK: - Human-Readable Codable

extension LightingMode: Codable {
    private var codableString: String {
        switch self {
        case .staticLight:  return "staticLight"
        case .animated:     return "animated"
        case .audioReactive: return "audioReactive"
        case .visualizer:   return "visualizer"
        }
    }

    private static let stringMap: [String: LightingMode] = {
        var map: [String: LightingMode] = [:]
        for c in LightingMode.allCases {
            map[c.codableString] = c
            map[c.codableString.lowercased()] = c
        }
        // Backward compatibility for older scene files.
        map["static"] = .staticLight
        return map
    }()

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            let key = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Self.stringMap[key] ?? Self.stringMap[key.lowercased()] {
                self = value
                return
            }
        }

        if let raw = try? container.decode(Int32.self),
           let value = LightingMode(rawValue: raw) {
            self = value
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "Invalid LightingMode value")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(codableString)
    }
}

extension SphericalInversionMode: Codable {
    private var codableString: String {
        switch self {
        case .off: return "off"
        case .outwardIn: return "outwardIn"
        }
    }

    private static let stringMap: [String: SphericalInversionMode] = {
        var map: [String: SphericalInversionMode] = [:]
        for c in SphericalInversionMode.allCases { map[c.codableString] = c }
        return map
    }()

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self),
           let value = Self.stringMap[str] {
            self = value
        } else if let raw = try? container.decode(Int32.self),
                  let value = SphericalInversionMode(rawValue: raw) {
            self = value
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid SphericalInversionMode value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(codableString)
    }
}
