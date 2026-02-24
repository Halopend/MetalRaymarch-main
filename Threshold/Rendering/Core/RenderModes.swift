import Foundation

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Geometry State - Stable Geometry Rendering
// ═══════════════════════════════════════════════════════════════════════════════
// Tracks whether geometry parameters (minDistance, foldingLimit, sphereRadius,
// fractalScale) are actively changing or have settled. When stable, the renderer
// can switch to an optimized path with temporal accumulation.
// ═══════════════════════════════════════════════════════════════════════════════

enum GeometryState: Int, CaseIterable {
    case dynamic   = 0  // Geometry parameters are actively changing
    case settling  = 1  // Parameters stopped changing, waiting for confirmation
    case stable    = 2  // Parameters confirmed stable, optimized rendering enabled
}

// Lighting mode controls animated light movement and audio reactivity
enum LightingMode: Int32, CaseIterable, Codable {
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
