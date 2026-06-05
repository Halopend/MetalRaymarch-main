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

// NOTE: SharePlay UI (formerly `SharePlayControlsView`) is intentionally not
// shipped. The backend (`FractalShareSession` / `FractalShareActivity`) is kept
// for future use but no view exposes it, so the feature is dormant.

// MARK: - Menu Adjustment Environment

/// Lightweight environment value carrying only the begin/end slider-editing
/// callbacks so EffectSliderRow doesn't subscribe to the full AppModel.
struct MenuAdjustmentActions: Sendable {
    var begin: @Sendable @MainActor () -> Void = {}
    var end: @Sendable @MainActor () -> Void = {}
}

extension MenuAdjustmentActions: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

private struct MenuAdjustmentActionsKey: EnvironmentKey {
    static let defaultValue = MenuAdjustmentActions()
}

extension EnvironmentValues {
    var menuAdjustmentActions: MenuAdjustmentActions {
        get { self[MenuAdjustmentActionsKey.self] }
        set { self[MenuAdjustmentActionsKey.self] = newValue }
    }
}

// MARK: - Condensed Effect Slider Row

/// Single-line effect row: icon + label | slider | on/off toggle
struct EffectSliderRow: View {
    @Environment(\.menuAdjustmentActions) private var menuActions
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
                    menuActions.begin()
                } else {
                    menuActions.end()
                }
            })
            .disabled(!enabled)
            .onChange(of: value) { _, _ in onChanged() }
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

struct FlashingLightIndicator: View {
    @State private var isLit = false

    var body: some View {
        ZStack {
            Circle()
                .fill(isLit ? Color.orange : Color.orange.opacity(0.28))
                .frame(width: 8, height: 8)
                .shadow(color: Color.orange.opacity(isLit ? 0.9 : 0.0), radius: isLit ? 6 : 0)

            Circle()
                .stroke(Color.orange.opacity(isLit ? 0.72 : 0.18), lineWidth: 1)
                .frame(width: isLit ? 14 : 10, height: isLit ? 14 : 10)
        }
        .frame(width: 16, height: 16)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.42).repeatForever(autoreverses: true)) {
                isLit = true
            }
        }
        .accessibilityHidden(true)
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
        .padding(.vertical, DS.Spacing.sm)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: DS.Radius.inset))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

