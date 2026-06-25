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
        case .low: return 68
        case .medium: return 97
        case .high: return 107
        case .ultra: return 150
        }
    }

    var resolutionScale: Float {
        switch self {
        case .low: return 0.67
        case .medium: return 0.75
        case .high: return 0.85
        case .ultra: return 1.0
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

    func values(for fractalType: FractalModelType) -> (fractalIterations: Int, raySteps: Int) {
        // Per-type quality tiers now live on the fractal type (see
        // FractalTypeDescriptor.qualityValues); nil = use this preset's defaults.
        fractalType.descriptor.qualityValues(for: self) ?? (fractalIterations, raySteps)
    }

    /// Try to detect preset from current settings
    static func detect(fractalIterations: Int, raySteps: Int, fractalType: FractalModelType? = nil) -> QualityPreset? {
        for preset in allCases {
            let values = fractalType.map { preset.values(for: $0) } ?? (preset.fractalIterations, preset.raySteps)
            if values.0 == fractalIterations && values.1 == raySteps {
                return preset
            }
        }
        return nil
    }
}
