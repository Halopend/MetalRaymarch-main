//
//  GestureSettingsView.swift
//  Threshold
//
//  Extracted from ContentView: gesture diagnostic status, finger assignments,
//  and controls with progressive disclosure.
//

import SwiftUI

struct GestureSettingsView: View {
    @Environment(AppModel.self) private var appModel
    var cache: UISettingsCache

    // ── Disclosure state (expert sections collapsed by default) ──
    @State private var showMenuToggle = false
    @State private var showPerFingerTap = false
    @State private var showTwoHandTuning = false
    @State private var showControlPresets = false
    @State private var newPresetName = ""
    @State private var controlPresets: [GestureBindingPreset] = GestureBindingPresetStore.loadAll()

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Gesture Controls", systemImage: "hand.draw").font(.headline)
                Spacer()
            }

            HandTrackingStatusView(state: appModel.handTrackingState)
                .padding(.vertical, 2)

            Toggle("Enable Hand Gesture Controls", isOn: Binding(
                get: { appModel.handTrackingEnabled },
                set: { appModel.handTrackingEnabled = $0 }
            ))

            VStack(alignment: .leading, spacing: 0) {
                // ── Control Presets (save/restore bindings) ───────────────
                DisclosureGroup(isExpanded: $showControlPresets) {
                    VStack(spacing: 8) {
                        if controlPresets.isEmpty {
                            Text("No saved presets")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(controlPresets) { preset in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(preset.name).font(.subheadline)
                                        Text(preset.createdAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    Button("Load") {
                                        for (key, binding) in preset.bindings {
                                            if let slot = GestureSlot.allSlots.first(where: { $0.persistenceKey == key }) {
                                                cache.setGestureBinding(binding, for: slot)
                                            }
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    Button(role: .destructive) {
                                        GestureBindingPresetStore.remove(id: preset.id)
                                        controlPresets = GestureBindingPresetStore.loadAll()
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                        HStack {
                            TextField("Preset name", text: $newPresetName)
                                .textFieldStyle(.roundedBorder)
                            Button("Save Current") {
                                let name = newPresetName.trimmingCharacters(in: .whitespaces)
                                guard !name.isEmpty else { return }
                                let preset = GestureBindingPreset(name: name, bindings: cache.gesture.gestureBindings)
                                GestureBindingPresetStore.add(preset)
                                controlPresets = GestureBindingPresetStore.loadAll()
                                newPresetName = ""
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Label("Control Presets", systemImage: "tray.2")
                        .font(.subheadline.weight(.semibold))
                }

                Divider().padding(.vertical, 2)

                // ── Hand Assignments (per-hand × per-finger) ──────────────
                VStack(alignment: .leading, spacing: 8) {
                    Label("Hand Assignments", systemImage: "hand.point.up.braille")
                        .font(.subheadline.weight(.semibold))

                    handSection(mode: .left)
                    handSection(mode: .right)
                    handSection(mode: .both)
                }

                Divider().padding(.vertical, 2)

                // ── Core Behavior ─────────────────────────────────────────
                VStack(alignment: .leading, spacing: 8) {
                    Label("Core Behavior", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))

                    Toggle("Spring Blob Navigation", isOn: Binding(
                        get: { cache.gesture.useSpringBlob },
                        set: { cache.gesture.useSpringBlob = $0; cache.push(\.useSpringBlob, value: $0) }
                    ))

                    Toggle("Relative Gestures", isOn: Binding(
                        get: { cache.gesture.useRelativeGestures },
                        set: { cache.gesture.useRelativeGestures = $0; cache.push(\.useRelativeGestures, value: $0) }
                    ))
                    Toggle("Extended Range", isOn: Binding(
                        get: { cache.gesture.extendedGestureRange },
                        set: { cache.gesture.extendedGestureRange = $0; cache.push(\.extendedGestureRange, value: $0) }
                    ))

                    EffectSliderRow(icon: "gauge.with.dots.needle.50percent", label: "Global Sensitivity",
                        value: Binding(get: { cache.gesture.gestureSensitivity }, set: { cache.gesture.gestureSensitivity = $0 }),
                        range: 1...10,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.gestureSensitivity, value: cache.gesture.gestureSensitivity) },
                        showToggle: false)

                    EffectSliderRow(icon: "move.3d", label: "Translation Sensitivity",
                        value: Binding(get: { cache.gesture.translationSensitivity }, set: { cache.gesture.translationSensitivity = $0 }),
                        range: 0.2...3.0,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.translationSensitivity, value: cache.gesture.translationSensitivity) },
                        showToggle: false)
                }

                Divider().padding(.vertical, 2)

                // ── Menu Toggle (collapsed by default) ───────────────────
                DisclosureGroup(isExpanded: $showMenuToggle) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Menu Toggle Gesture", isOn: Binding(
                            get: { cache.gesture.menuToggleGestureEnabled },
                            set: { cache.gesture.menuToggleGestureEnabled = $0; cache.push(\.menuToggleGestureEnabled, value: $0) }
                        ))

                        HStack {
                            Label("Menu Gesture", systemImage: cache.gesture.menuToggleGestureMode.icon)
                                .font(.subheadline)
                            Spacer()
                            Picker("Menu Gesture", selection: Binding(
                                get: { cache.gesture.menuToggleGestureMode },
                                set: { cache.gesture.menuToggleGestureMode = $0; cache.push(\.menuToggleGestureMode, value: $0) }
                            )) {
                                ForEach(MenuToggleGestureMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 220)
                            .disabled(!cache.gesture.menuToggleGestureEnabled)
                        }

                        EffectSliderRow(icon: "hand.tap", label: "Hold Time",
                            value: Binding(get: { cache.gesture.menuToggleHoldDuration }, set: { cache.gesture.menuToggleHoldDuration = $0 }),
                            range: 0.05...0.6,
                            enabled: .constant(cache.gesture.menuToggleGestureEnabled),
                            onChanged: { cache.push(\.menuToggleHoldDuration, value: cache.gesture.menuToggleHoldDuration) },
                            showToggle: false)

                        EffectSliderRow(icon: "timer", label: "Cooldown",
                            value: Binding(get: { cache.gesture.menuToggleCooldown }, set: { cache.gesture.menuToggleCooldown = $0 }),
                            range: 0.1...2.5,
                            enabled: .constant(cache.gesture.menuToggleGestureEnabled),
                            onChanged: { cache.push(\.menuToggleCooldown, value: cache.gesture.menuToggleCooldown) },
                            showToggle: false)

                        EffectSliderRow(icon: "bolt.horizontal", label: "Activate Threshold",
                            value: Binding(get: { cache.gesture.menuToggleActivateThreshold }, set: { cache.gesture.menuToggleActivateThreshold = $0 }),
                            range: 0.2...0.95,
                            enabled: .constant(cache.gesture.menuToggleGestureEnabled),
                            onChanged: { cache.push(\.menuToggleActivateThreshold, value: cache.gesture.menuToggleActivateThreshold) },
                            showToggle: false)

                        EffectSliderRow(icon: "arrow.down.to.line", label: "Release Threshold",
                            value: Binding(get: { cache.gesture.menuToggleReleaseThreshold }, set: { cache.gesture.menuToggleReleaseThreshold = $0 }),
                            range: 0.1...0.9,
                            enabled: .constant(cache.gesture.menuToggleGestureEnabled),
                            onChanged: { cache.push(\.menuToggleReleaseThreshold, value: cache.gesture.menuToggleReleaseThreshold) },
                            showToggle: false)
                    }
                    .padding(.top, 6)
                } label: {
                    Label("Menu Toggle", systemImage: "menucard")
                        .font(.subheadline.weight(.semibold))
                }

                Divider().padding(.vertical, 2)

                // ── Per-Finger Tap (collapsed by default) ────────────────
                DisclosureGroup(isExpanded: $showPerFingerTap) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Enable Per-Finger Tap", isOn: Binding(
                            get: { cache.gesture.perFingerTapGestureEnabled },
                            set: { cache.gesture.perFingerTapGestureEnabled = $0; cache.push(\.perFingerTapGestureEnabled, value: $0) }
                        ))

                        perFingerTapHandSection(handName: "Left Hand", actions: cache.gesture.perFingerTapLeftActions, keyPrefix: "perFingerTapLeft")
                        perFingerTapHandSection(handName: "Right Hand", actions: cache.gesture.perFingerTapRightActions, keyPrefix: "perFingerTapRight")

                        EffectSliderRow(icon: "hand.tap", label: "Hold Time",
                            value: Binding(get: { cache.gesture.perFingerTapHoldDuration }, set: { cache.gesture.perFingerTapHoldDuration = $0 }),
                            range: 0.05...0.6,
                            enabled: .constant(cache.gesture.perFingerTapGestureEnabled),
                            onChanged: { cache.push(\.perFingerTapHoldDuration, value: cache.gesture.perFingerTapHoldDuration) },
                            showToggle: false)

                        EffectSliderRow(icon: "timer", label: "Cooldown",
                            value: Binding(get: { cache.gesture.perFingerTapCooldown }, set: { cache.gesture.perFingerTapCooldown = $0 }),
                            range: 0.1...2.5,
                            enabled: .constant(cache.gesture.perFingerTapGestureEnabled),
                            onChanged: { cache.push(\.perFingerTapCooldown, value: cache.gesture.perFingerTapCooldown) },
                            showToggle: false)

                        EffectSliderRow(icon: "bolt.horizontal", label: "Activate Threshold",
                            value: Binding(get: { cache.gesture.perFingerTapActivateThreshold }, set: { cache.gesture.perFingerTapActivateThreshold = $0 }),
                            range: 0.2...0.95,
                            enabled: .constant(cache.gesture.perFingerTapGestureEnabled),
                            onChanged: { cache.push(\.perFingerTapActivateThreshold, value: cache.gesture.perFingerTapActivateThreshold) },
                            showToggle: false)

                        EffectSliderRow(icon: "arrow.down.to.line", label: "Release Threshold",
                            value: Binding(get: { cache.gesture.perFingerTapReleaseThreshold }, set: { cache.gesture.perFingerTapReleaseThreshold = $0 }),
                            range: 0.1...0.9,
                            enabled: .constant(cache.gesture.perFingerTapGestureEnabled),
                            onChanged: { cache.push(\.perFingerTapReleaseThreshold, value: cache.gesture.perFingerTapReleaseThreshold) },
                            showToggle: false)
                    }
                    .padding(.top, 6)
                } label: {
                    Label("Per-Finger Tap", systemImage: "hand.point.up.left.fill")
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
                            value: Binding(get: { cache.gesture.gestureMinHandDistance }, set: { cache.gesture.gestureMinHandDistance = $0 }),
                            range: 0.02...0.25,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.gestureMinHandDistance, value: cache.gesture.gestureMinHandDistance) },
                            showToggle: false)

                        EffectSliderRow(icon: "arrow.left.and.right", label: "Max Hand Distance",
                            value: Binding(get: { cache.gesture.gestureMaxHandDistance }, set: { cache.gesture.gestureMaxHandDistance = $0 }),
                            range: 0.2...1.2,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.gestureMaxHandDistance, value: cache.gesture.gestureMaxHandDistance) },
                            showToggle: false)

                        EffectSliderRow(icon: "play.circle", label: "Start Distance Guard",
                            value: Binding(get: { cache.gesture.gestureMaxStartHandDistance }, set: { cache.gesture.gestureMaxStartHandDistance = $0 }),
                            range: 0.08...1.0,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.gestureMaxStartHandDistance, value: cache.gesture.gestureMaxStartHandDistance) },
                            showToggle: false)

                        EffectSliderRow(icon: "checkmark.circle", label: "Active Distance Guard",
                            value: Binding(get: { cache.gesture.gestureMaxActiveHandDistance }, set: { cache.gesture.gestureMaxActiveHandDistance = $0 }),
                            range: 0.1...1.5,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.gestureMaxActiveHandDistance, value: cache.gesture.gestureMaxActiveHandDistance) },
                            showToggle: false)

                        Divider().padding(.vertical, 2)

                        // Sub-group: Pinch Thresholds
                        Text("Pinch Thresholds")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        EffectSliderRow(icon: "hand.draw", label: "Pinch Activate",
                            value: Binding(get: { cache.gesture.twoHandPinchActivateThreshold }, set: { cache.gesture.twoHandPinchActivateThreshold = $0 }),
                            range: 0.2...0.98,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.twoHandPinchActivateThreshold, value: cache.gesture.twoHandPinchActivateThreshold) },
                            showToggle: false)

                        EffectSliderRow(icon: "hand.raised", label: "Pinch Release",
                            value: Binding(get: { cache.gesture.twoHandPinchReleaseThreshold }, set: { cache.gesture.twoHandPinchReleaseThreshold = $0 }),
                            range: 0.1...0.95,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.twoHandPinchReleaseThreshold, value: cache.gesture.twoHandPinchReleaseThreshold) },
                            showToggle: false)

                        EffectSliderRow(icon: "hand.point.up.left", label: "Ring Activate",
                            value: Binding(get: { cache.gesture.ringPinchActivateThreshold }, set: { cache.gesture.ringPinchActivateThreshold = $0 }),
                            range: 0.1...0.95,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.ringPinchActivateThreshold, value: cache.gesture.ringPinchActivateThreshold) },
                            showToggle: false)

                        EffectSliderRow(icon: "hand.point.up.braille", label: "Ring Release",
                            value: Binding(get: { cache.gesture.ringPinchReleaseThreshold }, set: { cache.gesture.ringPinchReleaseThreshold = $0 }),
                            range: 0.05...0.9,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.ringPinchReleaseThreshold, value: cache.gesture.ringPinchReleaseThreshold) },
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

    // MARK: - Hand Section Helpers

    @ViewBuilder
    private func handSection(mode: GestureHandMode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(mode.displayName, systemImage: mode.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            if mode == .both {
                // Both-hand: no direction — one slot per finger
                ForEach(FingerDigit.allCases, id: \.self) { finger in
                    let slot = GestureSlot(hand: mode, finger: finger)
                    slotPicker(slot: slot, handMode: mode, directionLabel: nil)
                }
            } else {
                // Single-hand: V + H sub-slots per finger
                ForEach(FingerDigit.allCases, id: \.self) { finger in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finger.displayName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        let vSlot = GestureSlot(hand: mode, finger: finger, direction: .vertical)
                        slotPicker(slot: vSlot, handMode: mode, directionLabel: "↕")
                        let hSlot = GestureSlot(hand: mode, finger: finger, direction: .horizontal)
                        slotPicker(slot: hSlot, handMode: mode, directionLabel: "↔")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func slotPicker(slot: GestureSlot, handMode: GestureHandMode, directionLabel: String?) -> some View {
        let bindings = GestureActionBinding.availableBindings(for: cache.fractalType, handMode: handMode)
        let currentBinding = Binding<GestureActionBinding>(
            get: { cache.gestureBinding(for: slot) },
            set: { cache.setGestureBinding($0, for: slot) }
        )
        HStack {
            if let dir = directionLabel {
                Text(dir)
                    .font(.caption2)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
            }
            if handMode == .both {
                Label(slot.finger.displayName, systemImage: slot.finger.icon).font(.subheadline)
            }
            Spacer()
            Picker(slot.finger.displayName, selection: currentBinding) {
                ForEach(bindings, id: \.self) { binding in
                    Label(binding.contextualDisplayName(for: cache.fractalType), systemImage: binding.icon).tag(binding)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 220)
        }
    }

    // MARK: - Per-Finger Tap UI Helpers

    private let perFingerNames = ["Thumb", "Index", "Middle", "Ring", "Pinky"]
    private let perFingerIcons = ["hand.thumbsup.fill", "1.circle.fill", "2.circle.fill", "3.circle.fill", "4.circle.fill"]

    @ViewBuilder
    private func perFingerTapHandSection(handName: String, actions: [PerFingerTapAction], keyPrefix: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(handName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            ForEach(0..<5, id: \.self) { finger in
                let actionBinding = Binding<PerFingerTapAction>(
                    get: {
                        if keyPrefix.contains("Left") {
                            return cache.gesture.perFingerTapLeftActions[finger]
                        } else {
                            return cache.gesture.perFingerTapRightActions[finger]
                        }
                    },
                    set: { newValue in
                        if keyPrefix.contains("Left") {
                            cache.gesture.perFingerTapLeftActions[finger] = newValue
                            GestureDefaults.savePerFingerTapActions(cache.gesture.perFingerTapLeftActions, keyPrefix: keyPrefix)
                            cache.push(\.perFingerTapLeftActions, value: cache.gesture.perFingerTapLeftActions)
                        } else {
                            cache.gesture.perFingerTapRightActions[finger] = newValue
                            GestureDefaults.savePerFingerTapActions(cache.gesture.perFingerTapRightActions, keyPrefix: keyPrefix)
                            cache.push(\.perFingerTapRightActions, value: cache.gesture.perFingerTapRightActions)
                        }
                    }
                )
                HStack {
                    Label(perFingerNames[finger], systemImage: perFingerIcons[finger])
                        .font(.subheadline)
                    Spacer()
                    Picker(perFingerNames[finger], selection: actionBinding) {
                        ForEach(PerFingerTapAction.allCases, id: \.self) { action in
                            Label(action.displayName, systemImage: action.icon).tag(action)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220)
                    .disabled(!cache.gesture.perFingerTapGestureEnabled)
                }
            }
        }
    }

}
