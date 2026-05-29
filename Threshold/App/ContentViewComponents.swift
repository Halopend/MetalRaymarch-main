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

struct HoldToSaveResetButton: View {
    let onTapReset: () -> Void
    let onHoldReady: () -> Void

    @State private var isPressing = false
    @State private var holdProgress: CGFloat = 0
    @State private var holdTask: Task<Void, Never>?
    @State private var holdCompleted = false

    private let holdArmDelay: TimeInterval = 0.25
    private let holdDuration: TimeInterval = 1.1

    private var totalHoldDuration: TimeInterval {
        holdArmDelay + holdDuration
    }

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.green.opacity(0.12))

            GeometryReader { geo in
                Capsule()
                    .fill(Color.green.opacity(0.28))
                    .frame(width: max(0, geo.size.width * holdProgress))
            }
            .clipShape(Capsule())

            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.15), lineWidth: 2)
                        .frame(width: 18, height: 18)
                    Circle()
                        .trim(from: 0, to: holdProgress)
                        .stroke(Color.green,
                                style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 18, height: 18)

                    Image(systemName: isPressing ? "square.and.arrow.down" : "arrow.counterclockwise")
                        .font(.system(size: 9, weight: .semibold))
                }

                Text(isPressing ? "Save" : "Reset")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 118, height: 34)
        .contentShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.green.opacity(0.45), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.15), value: holdProgress)
        .animation(.easeInOut(duration: 0.2), value: isPressing)
        .help("Tap to reset. Long press to choose where to save the current settings.")
        .onTapGesture {
            guard !isPressing else { return }
            onTapReset()
        }
        .onLongPressGesture(minimumDuration: totalHoldDuration, maximumDistance: 24, pressing: handlePressingChanged) {
            completeHold()
        }
    }

    private func handlePressingChanged(_ pressing: Bool) {
        if pressing {
            holdCompleted = false
            isPressing = true
            holdTask?.cancel()
            holdTask = Task { @MainActor in
                let start = Date()
                while !Task.isCancelled {
                    let elapsed = Date().timeIntervalSince(start)
                    let activeHoldElapsed = max(0.0, elapsed - holdArmDelay)
                    holdProgress = min(1.0, activeHoldElapsed / holdDuration)
                    if elapsed >= totalHoldDuration { break }
                    try? await Task.sleep(nanoseconds: 33_000_000)
                }
            }
        } else {
            holdTask?.cancel()
            holdTask = nil
            isPressing = false
            if !holdCompleted {
                holdProgress = 0
            }
        }
    }

    private func completeHold() {
        holdCompleted = true
        holdTask?.cancel()
        holdTask = nil
        holdProgress = 1
        isPressing = false
        onHoldReady()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            holdProgress = 0
            isPressing = false
            holdCompleted = false
        }
    }
}

struct ActivityLightButton: View {
    let title: String
    let systemImage: String
    let color: Color
    let isActive: Bool
    let count: Int?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(isActive ? color : Color.secondary.opacity(0.35))
                        .frame(width: 8, height: 8)
                        .shadow(color: isActive ? color.opacity(0.65) : .clear, radius: 4)

                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isActive ? color : .secondary)
                        .frame(width: 14, height: 14)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill((isActive ? color : Color.secondary).opacity(isHovering ? 0.2 : (isActive ? 0.14 : 0.08)))
                )
                .overlay(
                    Capsule()
                        .strokeBorder((isActive ? color : Color.secondary).opacity(isHovering ? 0.55 : (isActive ? 0.34 : 0.12)), lineWidth: 1)
                )
                .scaleEffect(isHovering ? 1.06 : 1.0)

                if let count {
                    Text("\(count)")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(minWidth: 13, minHeight: 13)
                        .padding(.horizontal, 1)
                        .background(Capsule().fill(color))
                        .offset(x: 5, y: -5)
                }
            }
        }
        .buttonStyle(.plain)
        .thresholdHoverEffect()
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.18, extraBounce: 0.05)) {
                isHovering = hovering
            }
        }
        .help("\(title): \(isActive ? "On" : "Off")")
        .accessibilityLabel(title)
        .accessibilityValue(isActive ? "On" : "Off")
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
                    systemImage: "arrow.counterclockwise"
                )

                saveChoiceButton(
                    choice: .presetCustomName,
                    title: "Preset - Custom Name",
                    subtitle: "Save with a name you enter.",
                    systemImage: "character.cursor.ibeam"
                )

                saveChoiceButton(
                    choice: .presetWithPreview,
                    title: "Save + Convert Preview",
                    subtitle: "Save a named preset with a generated image.",
                    systemImage: "photo.badge.plus"
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
                    Image(systemName: "checkmark.circle.fill")
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

    private var fileKind: String {
        switch request.payload {
        case .preset: return request.fileExtension == "threshmp" ? "Music Preset" : "Fractal Scene"
        case .animation: return request.fileExtension == "threshanimv" ? "Music Video Animation" : "Animation"
        }
    }

    private var accentColor: Color {
        switch request.payload {
        case .preset: return request.fileExtension == "threshmp" ? .blue : .purple
        case .animation: return .green
        }
    }

    private var iconName: String {
        switch request.payload {
        case .preset: return request.fileExtension == "threshmp" ? "music.note.list" : "cube.transparent"
        case .animation: return request.fileExtension == "threshanimv" ? "music.note.tv" : "film.stack"
        }
    }

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
                    .font(.system(size: 28, weight: .semibold))
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
                    Label("Cancel", systemImage: "xmark")
                }

                Spacer()

                Button {
                    onPreview()
                } label: {
                    Label("Preview", systemImage: "eye")
                }
                .buttonStyle(.bordered)

                Button {
                    onImport()
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
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

    private var indicatorColor: Color {
        let fps = appModel.renderMetrics.fps
        if fps >= 85 { return .green }
        else if fps >= 60 { return .yellow }
        else if fps >= 45 { return .orange }
        else { return .red }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: appModel.isUsingSpecializedPipeline ? "bolt.fill" : "bolt.slash")
                .font(.caption2)
                .foregroundStyle(appModel.isUsingSpecializedPipeline ? .green : .orange)
            Circle().fill(indicatorColor).frame(width: 8, height: 8)
            Text("\(appModel.renderMetrics.fps, specifier: "%.0f") FPS")
                .font(.caption.bold()).monospacedDigit()
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xxs)
        .dsGlass(in: Capsule())
    }
}
