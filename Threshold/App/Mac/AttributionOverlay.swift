#if os(macOS)
import SwiftUI

struct BaseDistanceEstimatorInfo: Equatable {
    let name: String
    let author: String?

    static func resolve(
        fractalType: FractalModelType,
        formulaParams: FormulaParams,
        embeddedFormula: EmbeddedFormula?
    ) -> Self {
        if fractalType == .custom,
           let embeddedFormula,
           embeddedFormula.effectKind == .fractal {
            return Self(
                name: normalizedName(embeddedFormula.name, fallback: fractalType.displayName),
                author: normalizedAuthor(embeddedFormula.author)
            )
        }

        if fractalType == .constructionPrimitive,
           let primitive = FractalPrimitiveKind(
               rawSelector: FormulaCatalog.getParam(formulaParams, index: 0)
           ) {
            return Self(
                name: primitive.name,
                author: normalizedAuthor(primitive.formula.author)
            )
        }

        let descriptor = FormulaCatalog.shared.descriptor(for: fractalType)
        return Self(
            name: normalizedName(descriptor?.name, fallback: fractalType.displayName),
            author: normalizedAuthor(descriptor?.author)
        )
    }

    var accessibilityDescription: String {
        if let author {
            return "Base fractal distance estimator: \(name), by \(author)."
        }
        return "Base fractal distance estimator: \(name)."
    }

    private static func normalizedName(_ name: String?, fallback: String) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func normalizedAuthor(_ author: String?) -> String? {
        let trimmed = author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A non-modal acknowledgement card shown while the Mac viewport's I key is held.
struct AttributionOverlay: View {
    let baseDistanceEstimator: BaseDistanceEstimatorInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.purple)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Threshold")
                        .font(.headline)
                    Text("Acknowledgements")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text("HOLD I")
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text("With gratitude to the fractal-art, signed-distance-field, ray-marching, shader, real-time graphics, Metal, Apple-platform, and open-source communities.")
                .font(.subheadline)
                .foregroundStyle(.primary.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: 12) {
                Label("Base DE", systemImage: "function")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(baseDistanceEstimator.name)
                        .font(.subheadline.weight(.semibold))
                    if let author = baseDistanceEstimator.author {
                        Text("by \(author)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))

            Divider()
                .overlay(Color.white.opacity(0.12))

            Text("Imported formulas, shaders, artwork, and other third-party material keep their own attribution and license notices. Threshold’s application code is GPL-3.0-or-later.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label("Release I to return", systemImage: "keyboard")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 430, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.055, green: 0.018, blue: 0.09).opacity(0.98),
                            Color(red: 0.10, green: 0.028, blue: 0.15).opacity(0.98)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.purple.opacity(0.7), .white.opacity(0.16)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(0.36), radius: 20, y: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Threshold acknowledgements. \(baseDistanceEstimator.accessibilityDescription) Release I to dismiss."
        )
    }
}
#endif
