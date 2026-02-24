import Foundation

/// Quality preset that bundles fractal iterations and ray steps.
/// Reduced to 4 presets to minimize pipeline permutations (each preset compiles
/// a specialized shader with baked loop counts).
enum QualityPreset: String, CaseIterable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case ultra = "Ultra"

    var fractalIterations: Int {
        switch self {
        case .low: return 6
        case .medium: return 8
        case .high: return 9
        case .ultra: return 12
        }
    }

    var raySteps: Int {
        switch self {
        case .low: return 32
        case .medium: return 56
        case .high: return 64
        case .ultra: return 100
        }
    }

    var displayName: String { rawValue }

    var icon: String {
        switch self {
        case .low: return "hare"
        case .medium: return "gauge.with.dots.needle.33percent"
        case .high: return "gauge.with.dots.needle.67percent"
        case .ultra: return "gauge.with.dots.needle.100percent"
        }
    }

    /// Try to detect preset from current settings
    static func detect(fractalIterations: Int, raySteps: Int) -> QualityPreset? {
        for preset in allCases {
            if preset.fractalIterations == fractalIterations && preset.raySteps == raySteps {
                return preset
            }
        }
        return nil
    }
}
