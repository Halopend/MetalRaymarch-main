//
//  ContentViewHelpers.swift
//  Threshold
//
//  Helper views and types extracted from ContentView.swift.
//

import SwiftUI

enum AdvancedTestScene {
    static func create(startPosition: SIMD3<Float>) -> AnimationScene {
        var scene = AnimationScene(name: "Dev Test")
        scene.isLooping = true
        scene.keyframes.append(AnimationKeyframe(name: "Start", duration: 0, minDistance: 0.8, foldingLimit: 1.0, sphereRadius: 0.5, fractalScale: 2.8, position: startPosition))
        scene.keyframes.append(AnimationKeyframe(name: "Open", duration: 2.0, minDistance: 2.0, foldingLimit: 3.0, sphereRadius: 0.8, fractalScale: 2.5, position: startPosition + SIMD3<Float>(0.1, 0, 0)))
        scene.keyframes.append(AnimationKeyframe(name: "Tight", duration: 2.0, minDistance: 0.5, foldingLimit: 0.8, sphereRadius: 0.3, fractalScale: 3.2, position: startPosition + SIMD3<Float>(0, 0.1, 0)))
        scene.keyframes.append(AnimationKeyframe(name: "Wild", duration: 2.0, minDistance: 1.5, foldingLimit: 5.0, sphereRadius: 1.2, fractalScale: 2.2, position: startPosition + SIMD3<Float>(-0.1, 0, 0.1)))
        scene.keyframes.append(AnimationKeyframe(name: "Return", duration: 2.0, minDistance: 0.8, foldingLimit: 1.0, sphereRadius: 0.5, fractalScale: 2.8, position: startPosition))
        return scene
    }
}

// MARK: - SharePlay Controls View

struct SharePlayControlsView: View {
    @Bindable var shareSession: FractalShareSession
    var appModel: AppModel
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 10, height: 10)
                    Text(statusText).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task {
                        switch shareSession.state {
                        case .inactive: await shareSession.startSharing()
                        default: shareSession.stopSharing()
                        }
                    }
                } label: { Label(buttonText, systemImage: buttonIcon) }
                .buttonStyle(.borderedProminent).tint(buttonTint)
            }
            if case .connected = shareSession.state {
                HStack {
                    Text("Role:").font(.caption).foregroundStyle(.secondary)
                    Picker("Role", selection: $shareSession.role) {
                        ForEach(SharePlayRole.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).frame(maxWidth: 220)
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    
    private var statusColor: Color { switch shareSession.state { case .inactive: return .gray; case .waiting: return .yellow; case .connected: return .green; case .error: return .red } }
    private var statusText: String { switch shareSession.state { case .inactive: return "Not sharing"; case .waiting: return "Waiting for others..."; case .connected(let c): return "\(c) connected"; case .error(let m): return "Error: \(m)" } }
    private var buttonText: String { switch shareSession.state { case .inactive: return "Share via FaceTime"; default: return "Stop Sharing" } }
    private var buttonIcon: String { switch shareSession.state { case .inactive: return "shareplay"; default: return "shareplay.slash" } }
    private var buttonTint: Color { switch shareSession.state { case .inactive: return .blue; default: return .red } }
}

// MARK: - Condensed Effect Slider Row

/// Single-line effect row: icon + label | slider | on/off toggle
struct EffectSliderRow: View {
    @Environment(AppModel.self) private var appModel
    let icon: String
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    @Binding var enabled: Bool
    let onChanged: () -> Void
    var showToggle: Bool = true
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(enabled ? .primary : .secondary)
                .frame(width: 16)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(enabled ? .primary : .secondary)
                .frame(width: 135, alignment: .leading)
                .lineLimit(1)
            Slider(value: $value, in: range, onEditingChanged: { editing in
                if editing {
                    appModel.beginMenuAdjustment()
                } else {
                    appModel.endMenuAdjustment()
                    onChanged()
                }
            })
            .disabled(!enabled)
            if showToggle {
                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .onChange(of: enabled) { _, _ in onChanged() }
            } else {
                Spacer().frame(width: 44)
            }
        }
        .frame(height: 32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "%.2f", value))
    }
}

// MARK: - StatBox

struct StatBox: View {
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.monospacedDigit())
                .fontWeight(.semibold)
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

