import Foundation

/// Quality preset that bundles fractal iterations and ray steps.
/// Reduced to 4 presets to minimize pipeline permutations (each preset compiles
/// a specialized shader with baked loop counts).
enum QualityPreset: String, CaseIterable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case ultra = "Ultra"

    private var defaults: (fractalIterations: Int, raySteps: Int, icon: String) {
        switch self {
        case .low: return (6, 68, "hare")
        case .medium: return (8, 97, "gauge.with.dots.needle.33percent")
        case .high: return (9, 107, "gauge.with.dots.needle.67percent")
        case .ultra: return (12, 150, "gauge.with.dots.needle.100percent")
        }
    }

    var fractalIterations: Int { defaults.fractalIterations }

    var raySteps: Int { defaults.raySteps }

    var displayName: String { rawValue }

    var icon: String { defaults.icon }

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
