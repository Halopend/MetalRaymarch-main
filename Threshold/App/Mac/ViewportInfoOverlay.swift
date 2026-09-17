#if os(macOS)
import SwiftUI

/// The non-modal info card toggled by the Mac viewport's I key. Press I to
/// show it, press I again to hide it. Summarizes what is actually on screen:
/// the active formula, its iteration/ray-step budget, the live presentation
/// path, headline performance, and the running build.
///
/// Observation is deliberately narrow: only `RenderMetrics` (≈2 Hz churn) and
/// a couple of `RenderSettings` integers are read, so the card invalidates
/// itself without disturbing the rest of the window.
struct ViewportInfoOverlay: View {
    @Environment(AppModel.self) private var appModel

    private var fps: Double { appModel.renderMetrics.fps }
    private var gpuMs: Double { appModel.renderMetrics.gpuFrameMs }

    private var fpsColor: Color {
        if fps >= 85 { return .green }
        else if fps >= 60 { return .yellow }
        else if fps >= 45 { return .orange }
        else { return .red }
    }

    /// GPU-cost color by frame-time budget: green = ample headroom, yellow =
    /// fits a 60 fps frame, orange = only a 30 fps frame, red = over even that.
    private var gpuColor: Color {
        if gpuMs <= 0 { return .secondary }
        if gpuMs < 8 { return .green }
        else if gpuMs < 16.6 { return .yellow }
        else if gpuMs < 33 { return .orange }
        else { return .red }
    }

    /// The active formula's display name. Custom (.threshfx) scenes show the
    /// embedded formula's own name so the card identifies what is running.
    private var formulaName: String {
        let type = appModel.renderSettings.fractalType
        if type == .custom, let formula = appModel.activeEmbeddedFormula {
            return formula.name
        }
        return type.displayName
    }

    private var buildLine: String {
        var line = "Version \(BuildStamp.marketingVersion) (\(BuildStamp.buildNumber))"
        let sha = BuildStamp.gitSHA
        if sha != "unknown" {
            line += " · \(sha)\(BuildStamp.gitDirty ? " dirty" : "")"
        }
        return line
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: appModel.renderSettings.fractalType.icon)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.purple)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Threshold")
                        .font(.headline)
                    Text("Viewport Info")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text("TOGGLE I")
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Divider()
                .overlay(Color.white.opacity(0.12))

            // ── Scene ──
            infoRow(icon: "function", label: "Formula") {
                Text(formulaName)
            }
            infoRow(icon: "gauge.with.needle", label: "Budget") {
                Text("\(appModel.renderSettings.fractalIterations) iterations · \(appModel.renderSettings.maxRaySteps) ray steps")
            }

            // ── Presentation ──
            infoRow(icon: "rectangle.landscape.rotate",
                    label: "Pipeline") {
                Label(appModel.isUsingSpecializedPipeline ? "Specialized" : "Generic",
                      systemImage: appModel.isUsingSpecializedPipeline
                          ? AppIcons.boltFill
                          : AppIcons.boltSlash)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appModel.isUsingSpecializedPipeline ? .green : .orange)
            }
            infoRow(icon: "arrow.up.left.and.arrow.down.right",
                    label: "Path") {
                Text(appModel.renderMetrics.upscalerPath)
            }
            if appModel.renderMetrics.drawableWidth > 0 {
                infoRow(icon: "viewfinder", label: "Draw") {
                    Text("\(appModel.renderMetrics.drawableWidth) × \(appModel.renderMetrics.drawableHeight)")
                }
            }

            // ── Live performance ──
            infoRow(icon: "speedometer", label: "FPS") {
                Text("\(fps, specifier: "%.0f")")
                    .foregroundStyle(fpsColor)
            }
            if gpuMs > 0 {
                infoRow(icon: "cpu", label: "GPU") {
                    Text("\(gpuMs, specifier: "%.1f") ms")
                        .foregroundStyle(gpuColor)
                }
            }

            Divider()
                .overlay(Color.white.opacity(0.12))

            Text(buildLine)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Label("Press I again to hide", systemImage: "keyboard")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 360, alignment: .leading)
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
        .accessibilityLabel("Viewport info. Press I again to dismiss.")
    }

    @ViewBuilder
    private func infoRow<Content: View>(
        icon: String,
        label: String,
        @ViewBuilder value: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(label, systemImage: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            value()
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(.primary)
        }
    }
}
#endif