//
//  ContentView+GesturesTab.swift
//  Threshold
//
//  Gestures tab UI extracted from ContentView.swift (Phase C refactor).
//  Stored properties remain on the main `ContentView` struct.
//

import SwiftUI

extension ContentView {
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Gestures Tab
    // ═══════════════════════════════════════════════════════════════════════════

    var gesturesTabContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 8) {
                HStack {
                    Label("Gesture Controls", systemImage: AppIcons.handDraw).font(.headline)
                    Spacer()
                }

                HandTrackingStatusView(state: appModel.handTrackingState)
                    .padding(.vertical, 2)

                Toggle("Enable Hand Gesture Controls", isOn: Binding(
                    get: { appModel.handTrackingEnabled },
                    set: { appModel.handTrackingEnabled = $0 }
                ))

                gestureAssignmentsSection

                VStack(alignment: .leading, spacing: 12) {
                    gestureCoreBehaviorSection
                    Divider().padding(.vertical, 2)
                    gestureMenuToggleSection
                    Divider().padding(.vertical, 2)
                    gesturePerFingerTapSection
                    Divider().padding(.vertical, 2)
                    gestureLabSection
                }
                .disabled(!appModel.handTrackingEnabled)
                .opacity(appModel.handTrackingEnabled ? 1.0 : 0.6)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.06)))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // ── Hand Assignments ───────────────────────────────────────────────────────

    private var gestureAssignmentsSection: some View {
        gestureHandConstellationPanel
    }

    // ── Core Behavior ──────────────────────────────────────────────────────────

    private var gestureCoreBehaviorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Core Behavior", systemImage: AppIcons.sliderHorizontal3)
                .font(.subheadline.weight(.semibold))

            // Compact 2-column grid of boolean behavior toggles
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                alignment: .leading,
                spacing: 6
            ) {
                Toggle("Relative Gestures", isOn: $cache.gesture.useRelativeGestures)
                    .onChange(of: cache.gesture.useRelativeGestures) { _, v in cache.push(\.useRelativeGestures, value: v) }
                Toggle("Spring Blob", isOn: $cache.gesture.useSpringBlob)
                    .onChange(of: cache.gesture.useSpringBlob) { _, v in cache.push(\.useSpringBlob, value: v) }
                Toggle("Menu + Movement Only", isOn: $cache.gesture.menuAndMovementOnly)
                    .onChange(of: cache.gesture.menuAndMovementOnly) { _, v in cache.push(\.menuAndMovementOnly, value: v) }
                Toggle("Extended Range", isOn: $cache.gesture.extendedGestureRange)
                    .onChange(of: cache.gesture.extendedGestureRange) { _, v in cache.push(\.extendedGestureRange, value: v) }
                Toggle("Rotation Auto-Snap", isOn: $cache.gesture.rotationAutoSnap)
                    .onChange(of: cache.gesture.rotationAutoSnap) { _, v in cache.push(\.rotationAutoSnap, value: v) }
            }
            .toggleStyle(.switch)
            .font(.subheadline)

            if cache.gesture.menuAndMovementOnly {
                Text("Skips shape and parameter gesture scans, keeping only menu trigger and movement gestures active.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if cache.gesture.rotationAutoSnap {
                EffectSliderRow(icon: "arrow.up.left.and.arrow.down.right", label: "Breakaway Angle (°)",
                    value: $cache.gesture.rotationBreakawayDegrees, range: 0...45,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.rotationBreakawayDegrees, value: cache.gesture.rotationBreakawayDegrees) },
                    showToggle: false)
                Text("Rotation stays locked until your hands rotate past this angle, then engages smoothly.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            EffectSliderRow(icon: "gauge.with.dots.needle.50percent", label: "Global Sensitivity",
                value: $cache.gesture.gestureSensitivity, range: 1...10,
                enabled: .constant(true),
                onChanged: { cache.push(\.gestureSensitivity, value: cache.gesture.gestureSensitivity) },
                showToggle: false)

            EffectSliderRow(icon: "wind", label: "Gesture Smoothing (s)",
                value: $cache.gesture.gestureSmoothing, range: GestureDefaults.gestureSmoothingRange,
                enabled: .constant(true),
                onChanged: { cache.push(\.gestureSmoothing, value: cache.gesture.gestureSmoothing) },
                showToggle: false)
            Text("How long gesture changes take to play out. Higher = smoother and more gradual; lower = snappier and more direct.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            #if os(macOS)
            Toggle("Tilt to Orbit (Motion Sensor)", isOn: Binding(
                get: { appModel.renderSettings.macTiltControlEnabled },
                set: { appModel.renderSettings.macTiltControlEnabled = $0 }
            ))
            .toggleStyle(.switch)
            .font(.subheadline)
            Text("Tilt the laptop to orbit the fractal using the built-in Sudden Motion Sensor. Available on Intel MacBooks only.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            #endif

            EffectSliderRow(icon: "move.3d", label: "Translation Sensitivity",
                value: $cache.gesture.translationSensitivity, range: 0.2...3.0,
                enabled: .constant(true),
                onChanged: { cache.push(\.translationSensitivity, value: cache.gesture.translationSensitivity) },
                showToggle: false)

            if cache.gesture.rotationAutoSnap {
                EffectSliderRow(icon: "rotate.3d", label: "Snap Window (°)",
                    value: $cache.gesture.rotationSnapWindowDegrees, range: 2...30,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.rotationSnapWindowDegrees, value: cache.gesture.rotationSnapWindowDegrees) },
                    showToggle: false)
            }
        }
    }

    // ── Menu Toggle (compact) ──────────────────────────────────────────────────

    private var gestureMenuToggleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Menu Toggle Gesture", isOn: $cache.gesture.menuToggleGestureEnabled)
                .onChange(of: cache.gesture.menuToggleGestureEnabled) { _, v in
                    cache.push(\.menuToggleGestureEnabled, value: v)
                }

            if cache.gesture.menuToggleGestureEnabled {
                HStack {
                    Label("Gesture", systemImage: cache.gesture.menuToggleGestureMode.icon)
                        .font(.subheadline)
                    Spacer()
                    Picker("", selection: $cache.gesture.menuToggleGestureMode) {
                        ForEach(MenuToggleGestureMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 180)
                    .onChange(of: cache.gesture.menuToggleGestureMode) { _, v in
                        cache.push(\.menuToggleGestureMode, value: v)
                    }
                }
            }
        }
    }

    // ── Per-Finger Tap (compact) ───────────────────────────────────────────────

    private var gesturePerFingerTapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Per-Finger Tap", isOn: $cache.gesture.perFingerTapGestureEnabled)
                .onChange(of: cache.gesture.perFingerTapGestureEnabled) { _, v in
                    cache.push(\.perFingerTapGestureEnabled, value: v)
                }

            if cache.gesture.perFingerTapGestureEnabled {
                HStack {
                    Text("Middle → Menu")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    // ── Gesture Lab (collapsed by default) ─────────────────────────────────────

    private var gestureLabSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Label("Menu Toggle Tuning", systemImage: AppIcons.menucard)
                    .font(.caption.weight(.semibold))

                EffectSliderRow(icon: "hand.tap", label: "Hold Time",
                    value: $cache.gesture.menuToggleHoldDuration, range: 0.05...0.6,
                    enabled: .constant(cache.gesture.menuToggleGestureEnabled),
                    onChanged: { cache.push(\.menuToggleHoldDuration, value: cache.gesture.menuToggleHoldDuration) },
                    showToggle: false)

                EffectSliderRow(icon: "timer", label: "Cooldown",
                    value: $cache.gesture.menuToggleCooldown, range: 0.1...2.5,
                    enabled: .constant(cache.gesture.menuToggleGestureEnabled),
                    onChanged: { cache.push(\.menuToggleCooldown, value: cache.gesture.menuToggleCooldown) },
                    showToggle: false)

                EffectSliderRow(icon: "bolt.horizontal", label: "Activate",
                    value: $cache.gesture.menuToggleActivateThreshold, range: 0.2...0.95,
                    enabled: .constant(cache.gesture.menuToggleGestureEnabled),
                    onChanged: { cache.push(\.menuToggleActivateThreshold, value: cache.gesture.menuToggleActivateThreshold) },
                    showToggle: false)

                EffectSliderRow(icon: "arrow.down.to.line", label: "Release",
                    value: $cache.gesture.menuToggleReleaseThreshold, range: 0.1...0.9,
                    enabled: .constant(cache.gesture.menuToggleGestureEnabled),
                    onChanged: { cache.push(\.menuToggleReleaseThreshold, value: cache.gesture.menuToggleReleaseThreshold) },
                    showToggle: false)

                Divider()

                Label("Two-Hand Pinch Tuning", systemImage: AppIcons.handsSparkles)
                    .font(.caption.weight(.semibold))

                EffectSliderRow(icon: "dot.radiowaves.left.and.right", label: "Min Distance",
                    value: $cache.gesture.gestureMinHandDistance, range: 0.02...0.25,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.gestureMinHandDistance, value: cache.gesture.gestureMinHandDistance) },
                    showToggle: false)

                EffectSliderRow(icon: "arrow.left.and.right", label: "Max Distance",
                    value: $cache.gesture.gestureMaxHandDistance, range: 0.2...1.2,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.gestureMaxHandDistance, value: cache.gesture.gestureMaxHandDistance) },
                    showToggle: false)

                EffectSliderRow(icon: "hand.draw", label: "Pinch Activate",
                    value: $cache.gesture.twoHandPinchActivateThreshold, range: 0.2...0.98,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.twoHandPinchActivateThreshold, value: cache.gesture.twoHandPinchActivateThreshold) },
                    showToggle: false)

                EffectSliderRow(icon: "hand.raised", label: "Pinch Release",
                    value: $cache.gesture.twoHandPinchReleaseThreshold, range: 0.1...0.95,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.twoHandPinchReleaseThreshold, value: cache.gesture.twoHandPinchReleaseThreshold) },
                    showToggle: false)

                EffectSliderRow(icon: "hand.point.up.left", label: "Ring Activate",
                    value: $cache.gesture.ringPinchActivateThreshold, range: 0.1...0.95,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.ringPinchActivateThreshold, value: cache.gesture.ringPinchActivateThreshold) },
                    showToggle: false)

                EffectSliderRow(icon: "hand.point.up.braille", label: "Ring Release",
                    value: $cache.gesture.ringPinchReleaseThreshold, range: 0.05...0.9,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.ringPinchReleaseThreshold, value: cache.gesture.ringPinchReleaseThreshold) },
                    showToggle: false)

                EffectSliderRow(icon: "play.circle", label: "Start Guard",
                    value: $cache.gesture.gestureMaxStartHandDistance, range: 0.08...1.0,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.gestureMaxStartHandDistance, value: cache.gesture.gestureMaxStartHandDistance) },
                    showToggle: false)

                EffectSliderRow(icon: "checkmark.circle", label: "Active Guard",
                    value: $cache.gesture.gestureMaxActiveHandDistance, range: 0.1...1.5,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.gestureMaxActiveHandDistance, value: cache.gesture.gestureMaxActiveHandDistance) },
                    showToggle: false)
            }
        } label: {
            Label("Gesture Lab", systemImage: AppIcons.wrenchAndScrewdriver)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
