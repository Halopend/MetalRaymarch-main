//
//  ContentViewHelpers.swift
//  Threshold
//
//  Helper views and types extracted from ContentView.swift.
//

import SwiftUI

enum DisplayFormat {
    static func minutesSeconds(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
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

// MARK: - Derived Value (music-reactive) Environment

/// Carries a resolver for a parameter's live (base, resolved) value plus whether
/// music-reactive modulation is currently active. Injected once at the ContentView
/// root so any EffectSliderRow can draw a derived-value ghost indicator just by
/// passing its `musicTargetID`.
struct DerivedValueProvider: Sendable {
    var resolve: @Sendable @MainActor (String) -> ParameterOperationDispatcher.LiveValue? = { _ in nil }
    var musicActive: Bool = false
}

extension DerivedValueProvider: Equatable {
    // Identity hinges on the active flag; the resolver closure is stable per session.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.musicActive == rhs.musicActive }
}

private struct DerivedValueProviderKey: EnvironmentKey {
    static let defaultValue = DerivedValueProvider()
}

extension EnvironmentValues {
    var derivedValueProvider: DerivedValueProvider {
        get { self[DerivedValueProviderKey.self] }
        set { self[DerivedValueProviderKey.self] = newValue }
    }
}

/// Non-interactive ghost marker overlaid on a slider track showing the live
/// music-modulated ("derived") value. Repaints via TimelineView only while music
/// is active, so idle UI pays nothing.
struct DerivedValueGhost: View {
    let targetID: String
    let range: ClosedRange<Float>
    @Environment(\.derivedValueProvider) private var provider

    /// Approximate half-thumb inset so the marker lines up with the slider track.
    private let thumbInset: CGFloat = 11

    var body: some View {
        if provider.musicActive {
            GeometryReader { geo in
                // 20 Hz, not display-rate: this ghost overlays EVERY music-targeted
                // effect slider, so a full-rate (~90 Hz) TimelineView per slider piles
                // up SwiftUI redraws that compete with the immersive raymarch while the
                // window is open. The marker tracks a damped value — 20 Hz reads smooth.
                TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { _ in
                    let live = provider.resolve(targetID)
                    if let live, live.isModulated {
                        let span = max(0.0001, range.upperBound - range.lowerBound)
                        let frac = CGFloat(min(1, max(0, (live.resolved - range.lowerBound) / span)))
                        let trackWidth = max(0, geo.size.width - thumbInset * 2)
                        let x = thumbInset + frac * trackWidth
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: 2.5, height: geo.size.height * 0.62)
                            .position(x: x, y: geo.size.height / 2)
                            .shadow(color: Color.accentColor.opacity(0.7), radius: 3)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
            }
        }
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
    /// When set (and `showToggle` is false), the trailing slot shows the live numeric
    /// value formatted by this closure instead of an empty spacer. Opt-in so existing
    /// rows are unchanged.
    var valueFormat: ((Float) -> String)? = nil
    /// When set, the slider shows a live "derived value" ghost marker while
    /// music-reactive modulation is driving this parameter.
    var musicTargetID: String? = nil

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
            .overlay {
                if let musicTargetID {
                    DerivedValueGhost(targetID: musicTargetID, range: range)
                }
            }
            .onChange(of: value) { _, _ in onChanged() }
            if showToggle {
                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .onChange(of: enabled) { _, _ in onChanged() }
            } else if let valueFormat {
                Text(valueFormat(value))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
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

/// Compact label/value slider used in dense settings grids.
struct CompactValueSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var step: Float?
    let display: String
    var tint: Color = .accentColor
    var helpText: String?
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                Text(display)
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(display == "Off" ? Color.secondary : tint)
            }
            if let step {
                Slider(value: $value, in: range, step: step, onEditingChanged: onEditingChanged)
                    .tint(tint)
                    .controlSize(.small)
            } else {
                Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                    .tint(tint)
                    .controlSize(.small)
            }
        }
        .help(helpText ?? "")
    }
}

struct FlashingLightIndicator: View {
    @State private var isLit = false

    var body: some View {
        ZStack {
            // No animated `.shadow` here: a repeating shadow-blur animation is
            // re-rasterized every frame, and several of these indicators live inside
            // scrollable control panels (Music/Transform), so the continuous blur
            // work stole the frame budget and made those lists scroll laggily. The
            // opacity + ring-scale pulse reads the same "flashing warning" without it.
            Circle()
                .fill(isLit ? Color.orange : Color.orange.opacity(0.28))
                .frame(width: 8, height: 8)

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
