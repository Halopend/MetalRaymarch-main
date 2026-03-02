//
//  GestureSettingsView.swift
//  Threshold
//
//  Extracted from ContentView: gesture diagnostic status, finger assignments,
//  and calibration controls with progressive disclosure.
//

import SwiftUI

struct GestureSettingsView: View {
    @Environment(AppModel.self) private var appModel
    var cache: UISettingsCache

    // ── Disclosure state (expert sections collapsed by default) ──
    @State private var showMenuToggle = false
    @State private var showTwoHandTuning = false

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Gesture Controls", systemImage: "hand.draw").font(.headline)
                Spacer()
            }

            // ── Diagnostic status ────────────────────────────────────────
            HStack(spacing: 6) {
                Circle()
                    .fill(gestureStatusColor)
                    .frame(width: 8, height: 8)
                Text(appModel.gestureStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if appModel.leftHandTracked || appModel.rightHandTracked {
                    HStack(spacing: 4) {
                        if appModel.leftHandTracked {
                            Image(systemName: "hand.raised.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                        if appModel.rightHandTracked {
                            Image(systemName: "hand.raised.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
            .padding(.vertical, 2)

            Toggle("Enable Hand Gesture Controls", isOn: Binding(
                get: { appModel.handTrackingEnabled },
                set: { appModel.handTrackingEnabled = $0 }
            ))

            VStack(alignment: .leading, spacing: 0) {
                // ── Core Behavior (always visible) ───────────────────────
                VStack(alignment: .leading, spacing: 8) {
                    Label("Core Behavior", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))

                    Toggle("Relative Gestures", isOn: Binding(
                        get: { cache.useRelativeGestures },
                        set: { cache.useRelativeGestures = $0; cache.push(\.useRelativeGestures, value: $0) }
                    ))
                    Toggle("Extended Range", isOn: Binding(
                        get: { cache.extendedGestureRange },
                        set: { cache.extendedGestureRange = $0; cache.push(\.extendedGestureRange, value: $0) }
                    ))

                    EffectSliderRow(icon: "gauge.with.dots.needle.50percent", label: "Global Sensitivity",
                        value: Binding(get: { cache.gestureSensitivity }, set: { cache.gestureSensitivity = $0 }),
                        range: 1...10,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.gestureSensitivity, value: cache.gestureSensitivity) },
                        showToggle: false)

                    EffectSliderRow(icon: "move.3d", label: "Translation Sensitivity",
                        value: Binding(get: { cache.translationSensitivity }, set: { cache.translationSensitivity = $0 }),
                        range: 0.2...3.0,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.translationSensitivity, value: cache.translationSensitivity) },
                        showToggle: false)
                }

                Divider().padding(.vertical, 2)

                // ── Finger Assignments (always visible) ──────────────────
                VStack(alignment: .leading, spacing: 8) {
                    Label("Finger Assignments", systemImage: "hand.point.up.braille")
                        .font(.subheadline.weight(.semibold))

                    fingerActionPicker(finger: "Index",  icon: "1.circle.fill",
                                       selection: Binding(get: { cache.indexFingerBinding }, set: { cache.indexFingerBinding = $0 }),
                                       settingsKeyPath: \.indexFingerBinding)
                    fingerActionPicker(finger: "Middle", icon: "2.circle.fill",
                                       selection: Binding(get: { cache.middleFingerBinding }, set: { cache.middleFingerBinding = $0 }),
                                       settingsKeyPath: \.middleFingerBinding)
                    fingerActionPicker(finger: "Ring",   icon: "3.circle.fill",
                                       selection: Binding(get: { cache.ringFingerBinding }, set: { cache.ringFingerBinding = $0 }),
                                       settingsKeyPath: \.ringFingerBinding)
                    fingerActionPicker(finger: "Pinky",  icon: "4.circle.fill",
                                       selection: Binding(get: { cache.pinkyFingerBinding }, set: { cache.pinkyFingerBinding = $0 }),
                                       settingsKeyPath: \.pinkyFingerBinding)
                }

                Divider().padding(.vertical, 2)

                // ── Menu Toggle (collapsed by default) ───────────────────
                DisclosureGroup(isExpanded: $showMenuToggle) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Menu Toggle Gesture", isOn: Binding(
                            get: { cache.menuToggleGestureEnabled },
                            set: { cache.menuToggleGestureEnabled = $0; cache.push(\.menuToggleGestureEnabled, value: $0) }
                        ))

                        HStack {
                            Label("Menu Gesture", systemImage: cache.menuToggleGestureMode.icon)
                                .font(.subheadline)
                            Spacer()
                            Picker("Menu Gesture", selection: Binding(
                                get: { cache.menuToggleGestureMode },
                                set: { cache.menuToggleGestureMode = $0; cache.push(\.menuToggleGestureMode, value: $0) }
                            )) {
                                ForEach(MenuToggleGestureMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 220)
                            .disabled(!cache.menuToggleGestureEnabled)
                        }

                        EffectSliderRow(icon: "hand.tap", label: "Hold Time",
                            value: Binding(get: { cache.menuToggleHoldDuration }, set: { cache.menuToggleHoldDuration = $0 }),
                            range: 0.05...0.6,
                            enabled: .constant(cache.menuToggleGestureEnabled),
                            onChanged: { cache.push(\.menuToggleHoldDuration, value: cache.menuToggleHoldDuration) },
                            showToggle: false)

                        EffectSliderRow(icon: "timer", label: "Cooldown",
                            value: Binding(get: { cache.menuToggleCooldown }, set: { cache.menuToggleCooldown = $0 }),
                            range: 0.1...2.5,
                            enabled: .constant(cache.menuToggleGestureEnabled),
                            onChanged: { cache.push(\.menuToggleCooldown, value: cache.menuToggleCooldown) },
                            showToggle: false)

                        EffectSliderRow(icon: "bolt.horizontal", label: "Activate Threshold",
                            value: Binding(get: { cache.menuToggleActivateThreshold }, set: { cache.menuToggleActivateThreshold = $0 }),
                            range: 0.2...0.95,
                            enabled: .constant(cache.menuToggleGestureEnabled),
                            onChanged: { cache.push(\.menuToggleActivateThreshold, value: cache.menuToggleActivateThreshold) },
                            showToggle: false)

                        EffectSliderRow(icon: "arrow.down.to.line", label: "Release Threshold",
                            value: Binding(get: { cache.menuToggleReleaseThreshold }, set: { cache.menuToggleReleaseThreshold = $0 }),
                            range: 0.1...0.9,
                            enabled: .constant(cache.menuToggleGestureEnabled),
                            onChanged: { cache.push(\.menuToggleReleaseThreshold, value: cache.menuToggleReleaseThreshold) },
                            showToggle: false)
                    }
                    .padding(.top, 6)
                } label: {
                    Label("Menu Toggle", systemImage: "menucard")
                        .font(.subheadline.weight(.semibold))
                }

                Divider().padding(.vertical, 2)

                // ── Two-Hand Gesture Tuning (collapsed by default) ───────
                DisclosureGroup(isExpanded: $showTwoHandTuning) {
                    VStack(alignment: .leading, spacing: 8) {
                        // Sub-group: Distance Guards
                        Text("Distance Guards")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)

                        EffectSliderRow(icon: "dot.radiowaves.left.and.right", label: "Min Hand Distance",
                            value: Binding(get: { cache.gestureMinHandDistance }, set: { cache.gestureMinHandDistance = $0 }),
                            range: 0.02...0.25,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.gestureMinHandDistance, value: cache.gestureMinHandDistance) },
                            showToggle: false)

                        EffectSliderRow(icon: "arrow.left.and.right", label: "Max Hand Distance",
                            value: Binding(get: { cache.gestureMaxHandDistance }, set: { cache.gestureMaxHandDistance = $0 }),
                            range: 0.2...1.2,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.gestureMaxHandDistance, value: cache.gestureMaxHandDistance) },
                            showToggle: false)

                        EffectSliderRow(icon: "play.circle", label: "Start Distance Guard",
                            value: Binding(get: { cache.gestureMaxStartHandDistance }, set: { cache.gestureMaxStartHandDistance = $0 }),
                            range: 0.08...1.0,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.gestureMaxStartHandDistance, value: cache.gestureMaxStartHandDistance) },
                            showToggle: false)

                        EffectSliderRow(icon: "checkmark.circle", label: "Active Distance Guard",
                            value: Binding(get: { cache.gestureMaxActiveHandDistance }, set: { cache.gestureMaxActiveHandDistance = $0 }),
                            range: 0.1...1.5,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.gestureMaxActiveHandDistance, value: cache.gestureMaxActiveHandDistance) },
                            showToggle: false)

                        Divider().padding(.vertical, 2)

                        // Sub-group: Pinch Thresholds
                        Text("Pinch Thresholds")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        EffectSliderRow(icon: "hand.draw", label: "Pinch Activate",
                            value: Binding(get: { cache.twoHandPinchActivateThreshold }, set: { cache.twoHandPinchActivateThreshold = $0 }),
                            range: 0.2...0.98,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.twoHandPinchActivateThreshold, value: cache.twoHandPinchActivateThreshold) },
                            showToggle: false)

                        EffectSliderRow(icon: "hand.raised", label: "Pinch Release",
                            value: Binding(get: { cache.twoHandPinchReleaseThreshold }, set: { cache.twoHandPinchReleaseThreshold = $0 }),
                            range: 0.1...0.95,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.twoHandPinchReleaseThreshold, value: cache.twoHandPinchReleaseThreshold) },
                            showToggle: false)

                        EffectSliderRow(icon: "hand.point.up.left", label: "Ring Activate",
                            value: Binding(get: { cache.ringPinchActivateThreshold }, set: { cache.ringPinchActivateThreshold = $0 }),
                            range: 0.1...0.95,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.ringPinchActivateThreshold, value: cache.ringPinchActivateThreshold) },
                            showToggle: false)

                        EffectSliderRow(icon: "hand.point.up.braille", label: "Ring Release",
                            value: Binding(get: { cache.ringPinchReleaseThreshold }, set: { cache.ringPinchReleaseThreshold = $0 }),
                            range: 0.05...0.9,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.ringPinchReleaseThreshold, value: cache.ringPinchReleaseThreshold) },
                            showToggle: false)
                    }
                    .padding(.top, 6)
                } label: {
                    Label("Two-Hand Gesture Tuning", systemImage: "hands.sparkles")
                        .font(.subheadline.weight(.semibold))
                }

                Text("Gesture Lab: tune menu triggering, pinch hysteresis, and hand-distance mapping for your hands and room setup.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .disabled(!appModel.handTrackingEnabled)
            .opacity(appModel.handTrackingEnabled ? 1.0 : 0.6)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.06)))
    }

    // MARK: - Helpers

    @ViewBuilder
    private func fingerActionPicker(
        finger: String,
        icon: String,
        selection: Binding<GestureActionBinding>,
        settingsKeyPath: WritableKeyPath<RenderSettings, GestureActionBinding>
    ) -> some View {
        let bindings = GestureActionBinding.availableBindings(for: cache.fractalType)
        HStack {
            Label(finger, systemImage: icon).font(.subheadline)
            Spacer()
            Picker(finger, selection: selection) {
                ForEach(bindings, id: \.self) { binding in
                    Label(binding.contextualDisplayName(for: cache.fractalType), systemImage: binding.icon).tag(binding)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 220)
            .onChange(of: selection.wrappedValue) { _, v in
                cache.push(settingsKeyPath, value: v)
            }
        }
    }

    private var gestureStatusColor: Color {
        let status = appModel.gestureStatus
        if status.hasPrefix("Active:") { return .green }
        if status.hasPrefix("Ready") { return .cyan }
        if status.contains("Suppressed") { return .yellow }
        if status.contains("disabled") || status.contains("not authorized") || status.contains("not running") || status.contains("stopped") || status.contains("failed") {
            return .red
        }
        if status.contains("No hands") { return .orange }
        return .gray
    }
}
