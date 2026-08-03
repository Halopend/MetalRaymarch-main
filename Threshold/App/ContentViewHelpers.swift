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
    var resolve: @Sendable @MainActor (String) -> ParameterPipeline.LiveValue? = { _ in nil }
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

/// Condensed effect row: icon + label | slider | on/off toggle.
/// Reflows to a two-line layout at accessibility Dynamic Type sizes.
struct EffectSliderRow: View {
    @Environment(\.menuAdjustmentActions) private var menuActions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
    /// Optional color paired with this effect. The color well is placed beside
    /// the effect name so amount and color read as one compound control.
    var pairedColor: Binding<SIMD3<Float>>? = nil

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        visualLabel(condensed: false)
                        Spacer(minLength: 8)
                        trailingAccessory(reservesEmptySpace: false)
                    }
                    sliderControl
                }
                .padding(.vertical, 4)
            } else {
                HStack(spacing: 8) {
                    visualLabel(condensed: true)
                    sliderControl
                    trailingAccessory(reservesEmptySpace: true)
                }
                .frame(minHeight: 32)
            }
        }
    }

    @ViewBuilder
    private func visualLabel(condensed: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(enabled ? .primary : .secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            if condensed {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(enabled ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                        .accessibilityHidden(true)
                    pairedColorWell
                }
                .frame(width: 135)
            } else {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(enabled ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
                if pairedColor != nil {
                    Spacer(minLength: 8)
                    pairedColorWell
                }
            }
        }
    }

    @ViewBuilder
    private var pairedColorWell: some View {
        if let pairedColor {
            EffectColorWell(
                effectName: label,
                color: pairedColor,
                onChanged: onChanged
            )
        }
    }

    private var sliderControl: some View {
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
        .accessibilityLabel(label)
        .accessibilityValue(formattedValue)
    }

    private var formattedValue: String {
        valueFormat?(value) ?? String(format: "%.2f", value)
    }

    @ViewBuilder
    private func trailingAccessory(reservesEmptySpace: Bool) -> some View {
        if showToggle {
            Toggle("Enable \(label)", isOn: $enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(dynamicTypeSize.isAccessibilitySize ? .regular : .mini)
                .onChange(of: enabled) { _, _ in onChanged() }
                .accessibilityLabel("Enable \(label)")
                .accessibilityValue(enabled ? "On" : "Off")
        } else if let valueFormat {
            Text(valueFormat(value))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: reservesEmptySpace ? 44 : nil, alignment: .trailing)
                .accessibilityHidden(true)
        } else if reservesEmptySpace {
            Spacer()
                .frame(width: 44)
                .accessibilityHidden(true)
        }
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
            .accessibilityHidden(true)

            Group {
                if let step {
                    Slider(value: $value, in: range, step: step, onEditingChanged: onEditingChanged)
                } else {
                    Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                }
            }
            .tint(tint)
            .controlSize(.small)
            .accessibilityLabel(title)
            .accessibilityValue(display)
        }
        .help(helpText ?? "")
    }
}

struct FlashingLightIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isLit = false

    private var visualIsLit: Bool { reduceMotion || isLit }

    var body: some View {
        ZStack {
            // No animated `.shadow` here: a repeating shadow-blur animation is
            // re-rasterized every frame, and several of these indicators live inside
            // scrollable control panels (Music/Transform), so the continuous blur
            // work stole the frame budget and made those lists scroll laggily. The
            // opacity + ring-scale pulse reads the same "flashing warning" without it.
            Circle()
                .fill(visualIsLit ? Color.orange : Color.orange.opacity(0.28))
                .frame(width: 8, height: 8)

            Circle()
                .stroke(Color.orange.opacity(visualIsLit ? 0.72 : 0.18), lineWidth: 1)
                .frame(width: visualIsLit ? 14 : 10, height: visualIsLit ? 14 : 10)
        }
        .frame(width: 16, height: 16)
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .onAppear {
            updatePulse(reduceMotion: reduceMotion)
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
            updatePulse(reduceMotion: shouldReduceMotion)
        }
        .accessibilityHidden(true)
    }

    private func updatePulse(reduceMotion: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isLit = reduceMotion
        }

        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.42).repeatForever(autoreverses: true)) {
            isLit = true
        }
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
