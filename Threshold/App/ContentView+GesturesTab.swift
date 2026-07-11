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
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Label("Gesture Controls", systemImage: AppIcons.handDraw).font(.headline)
                    Spacer()
                    Toggle("Enable", isOn: Binding(
                        get: { appModel.handTrackingEnabled },
                        set: { appModel.handTrackingEnabled = $0 }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }

                HandTrackingStatusView(state: appModel.handTrackingState)

                gestureAssignmentsSection

                VStack(alignment: .leading, spacing: 8) {
                    gestureCoreBehaviorSection
                    Divider()
                    gestureMenuToggleSection
                    Divider()
                    gesturePerFingerTapSection
                }
                .disabled(!appModel.handTrackingEnabled)
                .opacity(appModel.handTrackingEnabled ? 1.0 : 0.6)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.06)))
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    // ── Hand Assignments ───────────────────────────────────────────────────────

    private var gestureAssignmentsSection: some View {
        gestureHandConstellationPanel
    }

    // ── Core Behavior ──────────────────────────────────────────────────────────

    private var gestureCoreBehaviorSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Core Behavior", systemImage: AppIcons.sliderHorizontal3)
                .font(.subheadline.weight(.semibold))

            Toggle("Relative Gestures", isOn: $cache.gesture.useRelativeGestures)
                .onChange(of: cache.gesture.useRelativeGestures) { _, v in cache.push(\.useRelativeGestures, value: v) }
                .toggleStyle(.switch)
                .font(.subheadline)
            Text("Adjust by how far you move from where you started, instead of jumping to an absolute value.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            #if os(macOS)
            Toggle("Tilt to Orbit (Motion Sensor)", isOn: Binding(
                get: { appModel.renderSettings.macTiltControlEnabled },
                set: { appModel.renderSettings.macTiltControlEnabled = $0 }
            ))
            .toggleStyle(.switch)
            .font(.subheadline)
            Text("Tilt the laptop to orbit the fractal (Sudden Motion Sensor — Intel MacBooks only).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            #endif
        }
    }

    // ── Menu Toggle (compact) ──────────────────────────────────────────────────

    private var gestureMenuToggleSection: some View {
        VStack(alignment: .leading, spacing: 4) {
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
        VStack(alignment: .leading, spacing: 4) {
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

}
