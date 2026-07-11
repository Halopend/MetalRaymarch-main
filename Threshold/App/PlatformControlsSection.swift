#if os(visionOS)
import SwiftUI

/// Shared glass-floor controls used by both the Fractal quick-adjust panel and
/// Settings > Display.
struct PlatformControlsSection: View {
    var cache: UISettingsCache

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Platform", systemImage: AppIcons.circleHexagongridFill)
                    .font(.headline)
                Spacer()
                if cache.display.platformEnabled {
                    Text(String(format: "%.1f m", cache.display.platformRadius))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Toggle("Show Platform", isOn: Binding(
                    get: { cache.display.platformEnabled },
                    set: { cache.display.platformEnabled = $0 }
                ))
                .labelsHidden()
                .tint(.cyan)
                .controlSize(.mini)
            }

            Text("Renders a glass floor in the immersive space. The fractal color blends through it so the platform reads as a thick transparent surface. Disable for a clean floor-less view.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if cache.display.platformEnabled {
                EffectSliderRow(
                    icon: "circle.dotted",
                    label: "Radius",
                    value: Binding(
                        get: { cache.display.platformRadius },
                        set: { cache.display.platformRadius = $0 }
                    ),
                    range: 0.5...2.5,
                    enabled: .constant(true),
                    onChanged: { cache.commitPlatformRadius() },
                    showToggle: false
                )
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cyan.opacity(0.07)))
    }
}
#endif
