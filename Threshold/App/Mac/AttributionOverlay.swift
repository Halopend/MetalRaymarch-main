#if os(macOS)
import SwiftUI

/// A non-modal acknowledgement card shown while the Mac viewport's I key is held.
struct AttributionOverlay: View {
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
        .accessibilityLabel("Threshold acknowledgements. Release I to dismiss.")
    }
}
#endif
