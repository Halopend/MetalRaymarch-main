//
//  ContentViewComponents.swift
//  MetalProject
//
//  Self-contained helper views used by ContentView. Extracted from
//  ContentView.swift during the Phase 3 architecture refactor to reduce the
//  size of the main view file. These types take plain values/closures and do
//  not reference ContentView internals.
//

import SwiftUI
#if os(visionOS) || os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A plain Reset button that restores the current fractal to its saved settings.
/// Lives beside the record control on the opposite end of the bottom bar from
/// the "+" save button, so it doesn't read as one control with Save.
struct ResetControl: View {
    let onReset: () -> Void

    var body: some View {
        Button(action: onReset) {
            HStack(spacing: 6) {
                Image(systemName: AppIcons.arrowCounterclockwise)
                    .font(.system(size: IconSize.small, weight: .semibold))
                Text("Reset")
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(Capsule().fill(Color.secondary.opacity(0.10)))
        .overlay(Capsule().stroke(Color.secondary.opacity(0.35), lineWidth: 1))
        .help("Reset the current fractal to its saved settings.")
    }
}

/// The "+" button that opens the save-destination flow.
struct SaveControl: View {
    let onAdd: () -> Void

    var body: some View {
        Button(action: onAdd) {
            Image(systemName: AppIcons.plus)
                .font(.system(size: 15, weight: .bold))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(Circle().fill(Color.green))
        .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
        .help("Save the current settings as a new scene.")
    }
}

enum PresetPreviewGenerator {
    @MainActor
    static func makePNGData(
        name: String,
        fractalType: FractalModelType,
        gradientState: GradientState,
        lightingPreset: LightingPreset
    ) -> Data? {
        let content = PresetPreviewCard(
            name: name,
            fractalType: fractalType,
            gradientState: gradientState,
            lightingPreset: lightingPreset
        )
        .frame(width: 512, height: 320)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2

        #if os(visionOS) || os(iOS)
        return renderer.uiImage?.pngData()
        #elseif os(macOS)
        guard let image = renderer.nsImage,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
        #else
        return nil
        #endif
    }
}

struct PresetPreviewCard: View {
    let name: String
    let fractalType: FractalModelType
    let gradientState: GradientState
    let lightingPreset: LightingPreset

    private var gradientStops: [Gradient.Stop] {
        let stops = gradientState.gradient.stops
        guard !stops.isEmpty else {
            return [
                .init(color: .blue, location: 0),
                .init(color: .purple, location: 1)
            ]
        }

        return stops.map { stop in
            Gradient.Stop(
                color: Color(
                    red: Double(max(0, min(1, stop.color.x))),
                    green: Double(max(0, min(1, stop.color.y))),
                    blue: Double(max(0, min(1, stop.color.z)))
                ),
                location: CGFloat(max(0, min(1, stop.position)))
            )
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(stops: gradientStops),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [.white.opacity(0.42), .clear],
                center: .center,
                startRadius: 20,
                endRadius: 260
            )

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Image(systemName: fractalType.icon)
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(Circle().fill(.black.opacity(0.22)))

                    Spacer()

                    Text(lightingPreset.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(.black.opacity(0.24)))
                }

                Spacer()

                VStack(alignment: .leading, spacing: 5) {
                    Text(name)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(fractalType.displayName)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)
                }
            }
            .padding(26)
        }
    }
}

struct SaveDestinationSheet: View {
    let onSave: (SaveChoice, String?) -> Void
    let onCancel: () -> Void

    @State private var choice: SaveChoice = .resetLocation
    @State private var manualPresetName = ""

    private var canSave: Bool {
        if choice != .presetCustomName && choice != .presetWithPreview { return true }
        return !manualPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Save Current Settings")
                    .font(.headline)
                Text("Choose one destination.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                saveChoiceButton(
                    choice: .resetLocation,
                    title: "Reset Location",
                    subtitle: "Replace the current reset/default state.",
                    systemImage: AppIcons.arrowCounterclockwise
                )

                saveChoiceButton(
                    choice: .presetCustomName,
                    title: "Preset - Custom Name",
                    subtitle: "Save with a name you enter.",
                    systemImage: AppIcons.characterCursorIbeam
                )

                saveChoiceButton(
                    choice: .presetWithPreview,
                    title: "Save + Convert Preview",
                    subtitle: "Save a named preset with a generated image.",
                    systemImage: AppIcons.photoBadgePlus
                )
            }

            if choice == .presetCustomName || choice == .presetWithPreview {
                TextField("Preset name", text: $manualPresetName)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                Spacer()

                Button("Save") {
                    let trimmed = manualPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(choice, trimmed.isEmpty ? nil : trimmed)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func saveChoiceButton(choice: SaveChoice, title: String, subtitle: String, systemImage: String) -> some View {
        Button {
            self.choice = choice
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if self.choice == choice {
                    Image(systemName: AppIcons.checkmarkCircleFill)
                        .foregroundStyle(.blue)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(self.choice == choice ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(self.choice == choice ? Color.blue.opacity(0.4) : Color.secondary.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct ExternalFileImportSheet: View {
    let request: ExternalFileImportRequest
    let onPreview: () -> Void
    let onImport: () -> Void
    let onCancel: () -> Void

    // Label / colour / icon all derive from the imported file's format, resolved
    // once through ThresholdExportFormat (the single file-type registry) instead
    // of hand-checking the extension string in three places.
    private var format: ThresholdExportFormat? {
        ThresholdExportFormat(fileExtension: request.fileExtension)
    }

    private var fileKind: String { format?.displayName ?? "Threshold File" }
    private var accentColor: Color { format?.accentColor ?? .accentColor }
    private var iconName: String { format?.iconName ?? "doc" }

    private var title: String {
        switch request.payload {
        case .preset(let preset): return preset.name
        case .animation(let scene): return scene.name
        }
    }

    private var subtitle: String {
        switch request.payload {
        case .preset(let preset): return preset.fractalType.displayName
        case .animation(let scene):
            let duration = Self.durationFormatter.string(from: scene.totalDuration) ?? String(format: "%.1fs", scene.totalDuration)
            return "\(scene.keyframes.count) keyframes, \(duration)"
        }
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: IconSize.xlarge, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(accentColor.opacity(0.14)))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Open Threshold File")
                        .font(.headline)
                    Text(request.fileName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(fileKind)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(accentColor.opacity(0.13)))
                }

                VStack(spacing: 7) {
                    ForEach(detailRows, id: \.0) { label, value in
                        HStack(alignment: .firstTextBaseline) {
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            Text(value)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(accentColor.opacity(0.07)))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(accentColor.opacity(0.18), lineWidth: 1)
            )

            HStack(spacing: 10) {
                Button(role: .cancel) {
                    onCancel()
                } label: {
                    Label("Cancel", systemImage: AppIcons.xmark)
                }
                // The sheet uses .interactiveDismissDisabled(), so wire Esc
                // explicitly to the Cancel action as the keyboard escape hatch.
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    onPreview()
                } label: {
                    Label("Preview", systemImage: AppIcons.eye)
                }
                .buttonStyle(.bordered)

                Button {
                    onImport()
                } label: {
                    Label("Import", systemImage: AppIcons.squareAndArrowDown)
                }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    private var detailRows: [(String, String)] {
        switch request.payload {
        case .preset(let preset):
            let musicEnabled = preset.audioReactiveConfig?.fractalAudioReactiveEnabled ?? !(preset.musicReactiveMappings?.isEmpty ?? true)
            return [
                ("Format", ".\(request.fileExtension)"),
                ("Iterations", "\(preset.fractalIterations)"),
                ("Ray Steps", "\(preset.maxRaySteps)"),
                ("Music Reactive", musicEnabled ? "Yes" : "No")
            ]
        case .animation(let scene):
            return [
                ("Format", ".\(request.fileExtension)"),
                ("Looping", scene.isLooping ? "Yes" : "No"),
                ("Fractal", scene.fractalType?.displayName ?? "Scene default"),
                ("Song", scene.attachedSong.map { "\($0.title) - \($0.artist)" } ?? "None")
            ]
        }
    }
}

// MARK: - FPS Indicator (isolated to prevent 90Hz invalidation of ContentView)

/// Standalone view that reads `renderMetrics.fps` so the ~2Hz render-loop updates
/// only invalidate this small capsule, not the entire ContentView tree.
struct FPSIndicatorView: View {
    @Environment(AppModel.self) private var appModel

    private var fps: Double { appModel.renderMetrics.fps }
    private var gpuMs: Double { appModel.renderMetrics.gpuFrameMs }

    private var fpsColor: Color {
        if fps >= 85 { return .green }
        else if fps >= 60 { return .yellow }
        else if fps >= 45 { return .orange }
        else { return .red }
    }

    /// GPU-cost color by frame-time budget: green = ample headroom, yellow = fits
    /// a 60 fps frame, orange = only a 30 fps frame, red = over even that.
    private var gpuColor: Color {
        if gpuMs <= 0 { return .secondary }
        if gpuMs < 8 { return .green }
        else if gpuMs < 16.6 { return .yellow }
        else if gpuMs < 33 { return .orange }
        else { return .red }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: appModel.isUsingSpecializedPipeline ? AppIcons.boltFill : AppIcons.boltSlash)
                .font(.caption2)
                .foregroundStyle(appModel.isUsingSpecializedPipeline ? .green : .orange)
            HStack(spacing: 5) {
                Circle().fill(fpsColor).frame(width: 8, height: 8)
                Text("\(fps, specifier: "%.0f") FPS")
                    .font(.caption.bold()).monospacedDigit()
            }
            // GPU ms is the signal that actually moves when you tune the
            // acceleration settings — FPS is quantized by the display refresh.
            if gpuMs > 0 {
                Text("\(gpuMs, specifier: "%.1f") ms")
                    .font(.caption.bold()).monospacedDigit()
                    .foregroundStyle(gpuColor)
                    .help("GPU time per frame. Lower = faster; this moves continuously as you tune the acceleration settings even when the FPS number is pinned by vsync. Under ~16.6 ms is needed for 60 fps.")
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xxs)
        // Solid capsule rather than `.dsGlass` (which blurs its backdrop): this
        // indicator sits over the live Metal view as an always-on HUD, so a blur
        // here would be a per-frame cost on the render thread.
        .background(Color.black.opacity(0.6), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }
}

// MARK: - Render Diagnostics (isolated to RenderMetrics observation)

/// Live readout of the actual render resolution and quality. Reads
/// `renderMetrics` so its low-frequency updates only invalidate this view.
/// Lets the user confirm in-headset that the drawable is at native resolution
/// and watch the render quality track the resolution slider.
struct RenderDiagnosticsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let metrics = appModel.renderMetrics
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: AppIcons.viewfinder).font(.caption)
                Text("Render diagnostics").font(.headline)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    Text("Drawable").foregroundStyle(.secondary)
                    Text(metrics.drawableWidth > 0
                         ? "\(metrics.drawableWidth) × \(metrics.drawableHeight) px"
                         : "—")
                }
                GridRow {
                    Text("Render quality").foregroundStyle(.secondary)
                    Text(metrics.renderQuality > 0 ? "\(Int((metrics.renderQuality * 100).rounded()))%" : "—")
                }
                GridRow {
                    Text("Path").foregroundStyle(.secondary)
                    Text(metrics.renderPath)
                }
                GridRow {
                    Text("Foveation").foregroundStyle(.secondary)
                    Text(metrics.foveationEnabled ? "on" : "off")
                }
            }
            .font(.caption.monospacedDigit())
        }
    }
}

/// Live performance dashboard for the Performance ▸ Metrics sub-tab. Reads
/// `renderMetrics` + `cache.live*` directly (like RenderDiagnosticsView) so only
/// this view re-renders each frame — the surrounding controls stay static.
struct PerformanceMetricsView: View {
    @Environment(AppModel.self) private var appModel
    var cache: UISettingsCache

    // Force Recompile — embedded in this card (developer/debug).
    @State private var isRecompilingShaders = false
    @State private var shaderRecompileStatus: String?

    private func fpsColor(_ fps: Double) -> Color {
        if fps >= 85 { return .green }
        if fps >= 60 { return .yellow }
        return .orange
    }

    /// Drives `BenchmarkManager.liveStepMeasurement` (arms the in-kernel counter)
    /// alongside the observable UI flag. Clears the stale reading when turned off.
    private var stepProfilingBinding: Binding<Bool> {
        Binding(
            get: { appModel.renderMetrics.stepProfilingEnabled },
            set: { on in
                appModel.renderMetrics.stepProfilingEnabled = on
                BenchmarkManager.shared.liveStepMeasurement = on
                if !on { appModel.renderMetrics.avgStepsPerPixel = 0 }
            }
        )
    }

    var body: some View {
        let m = appModel.renderMetrics
        let mode = RendererModeOption.from(tileSize: cache.quality.tileSize)
        VStack(alignment: .leading, spacing: 12) {
            // Hero: big FPS + the headline frame numbers beside it.
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(m.fps > 0 ? String(format: "%.0f", m.fps) : "—")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(fpsColor(m.fps))
                    Text("FPS")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Divider().frame(height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    metricLine("GPU frame", m.gpuFrameMs > 0 ? String(format: "%.1f ms", m.gpuFrameMs) : "—")
                    metricLine("Mode", mode.rawValue)
                    metricLine("Path", m.renderPath)
                }
                .font(.caption.monospacedDigit())
                Spacer(minLength: 0)
            }

            // Tiles — the marching/shape numbers people tune against.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                StatBox(label: "Iterations", value: "\(cache.liveFractalIterations)", color: .cyan)
                StatBox(label: "Ray Steps", value: "\(cache.liveMaxRaySteps)", color: .cyan)
                StatBox(label: "Scale", value: String(format: "%.2f", cache.liveFractalScale), color: .teal)
                StatBox(label: "Detail", value: String(format: "%.1f×", cache.liveDetailScale), color: .teal)
                StatBox(label: "Quality",
                        value: m.renderQuality > 0 ? "\(Int((m.renderQuality * 100).rounded()))%" : "—",
                        color: .blue)
                StatBox(label: "Foveation",
                        value: m.foveationEnabled ? "On" : "Off",
                        color: m.foveationEnabled ? .green : .gray)
            }

            // Foveation decode dims — the coordinate spaces the compute ray
            // reconstruction works in. Always shown (no console needed) to diagnose
            // the compute distortion / black-square holes. Most relevant in Adaptive
            // Compute mode; in Fragment it just reports the current drawable state.
            VStack(alignment: .leading, spacing: 2) {
                Text("Foveation decode (eye 0)")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(m.foveationDecode)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(m.foveationDecode.contains("MISMATCH") ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Measured cost — the headline benchmark: how many march steps a
            // converged pixel actually took to reach the surface, averaged over
            // the frame's hit rays. This is what you weigh against visual quality;
            // "Ray Steps" above is only the budget/ceiling, not what happened.
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Avg steps to converge")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Profile", isOn: stepProfilingBinding)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(m.stepProfilingEnabled
                         ? (m.avgStepsPerPixel > 0 ? String(format: "%.1f", m.avgStepsPerPixel) : "…")
                         : "—")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                    Text("/ \(cache.liveMaxRaySteps) budget")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Text(m.stepProfilingEnabled
                     ? "Live GPU step count — adds per-ray atomic overhead, so the frame-time above is inflated while profiling is on."
                     : "Off. Enable to measure the real march steps per converged pixel.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            // Drawable resolution — the actual per-eye/window render-target size.
            HStack {
                Text("Drawable").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(m.drawableWidth > 0 ? "\(m.drawableWidth) × \(m.drawableHeight) px" : "—")
                    .font(.caption.monospacedDigit())
            }

            Divider()

            // Force Recompile — developer/debug, embedded in the dashboard card.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: AppIcons.wrenchAndScrewdriver).foregroundStyle(.cyan)
                    Text("Shaders").font(.headline)
                }
                Button {
                    isRecompilingShaders = true; shaderRecompileStatus = nil
                    Task {
                        let result = await appModel.forceShaderRecompile()
                        await MainActor.run { shaderRecompileStatus = result; isRecompilingShaders = false }
                    }
                } label: {
                    HStack {
                        if isRecompilingShaders {
                            ProgressView().scaleEffect(0.7).frame(width: 16, height: 16)
                        } else {
                            Image(systemName: AppIcons.arrowTriangle2Circlepath)
                        }
                        Text(isRecompilingShaders ? "Recompiling..." : "Force Recompile")
                    }
                }
                .buttonStyle(.borderedProminent).tint(.cyan).disabled(isRecompilingShaders)

                if let status = shaderRecompileStatus {
                    Text(status).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Rebuilds pipeline states and recompiles the active custom .threshfx formula from source.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(Color.cyan.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func metricLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value).fontWeight(.semibold).lineLimit(1)
        }
    }
}
