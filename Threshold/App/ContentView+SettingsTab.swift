//
//  ContentView+SettingsTab.swift
//  Threshold
//
//  Settings tab UI extracted from ContentView.swift (Phase C refactor).
//  Stored properties remain on the main `ContentView` struct; only computed
//  views and helper methods live here.
//

import SwiftUI

/// Identifiable wrapper so the export share sheet is presented via
/// `sheet(item:)` — guarantees the URL exists when the sheet body builds.
struct ExportShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

extension ContentView {
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Settings Tab
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Settings tab — split into five inner sub-tabs (Display, Gestures,
    /// Sharing, Export, Advanced) for faster navigation. Driven by
    /// `@AppStorage("ContentView.settingsSubTab") settingsSubTab` on
    /// `ContentView` so the user's last selection persists across launches.
    var settingsTabContent: some View {
        VStack(spacing: 0) {
            // Segmented tab picker. Wrapped in a top bar with a small
            // "Show Welcome Again" affordance on the trailing edge so users
            // can replay the onboarding from settings.
            HStack(spacing: 12) {
                Picker("Settings section", selection: $settingsSubTab) {
                    ForEach(SettingsSubTab.visibleCases) { tab in
                        Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Choose a settings section")

                Button {
                    openWindow(id: AppModel.onboardingWindowID)
                } label: {
                    Label("Show Welcome", systemImage: AppIcons.questionmarkCircle)
                        .labelStyle(.iconOnly)
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help("Replay the welcome and onboarding")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                Group {
                    switch settingsSubTab {
                    case .display:   settingsDisplayContent
                    case .gestures:  settingsDisplayContent
                    case .sharing:   settingsSharingContent
                    case .export:    settingsExportContent
                    case .advanced:  settingsAdvancedContent
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: - Quick Toggles pane

    /// A standalone pane (selected from the section rail) holding a flat,
    /// scannable page of master on/off switches for feature categories whose
    /// controls are otherwise scattered across the Effects, Shape, and Advanced
    /// tabs. Each switch binds to the same underlying enable flag the detailed
    /// control surfaces use, so flipping one here is identical to toggling it on
    /// its home tab — this is just one place to find them all.
    var quickTogglesTabContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("Quick Toggles", systemImage: SidebarTab.quickToggles.icon)
                        .font(.headline)
                    Spacer()
                }
                Text("Tap a tile to flip a feature on or off. Lit tiles are on. Each tile drives the same switch as its home tab.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Formula section auto-populates from the active fractal type's
                // capabilities — empty for fractals with no formula-specific knobs.
                quickToggleFormulaSection

                quickToggleSection("Lighting & Color", icon: "lightbulb", rows: quickToggleLightingRows)
                quickToggleSection("Space", icon: "globe.asia.australia", rows: quickToggleSpaceRows)
                quickToggleSection("Audio", icon: "waveform", rows: quickToggleAudioRows,
                                   footnote: "Bands are quick mutes — turning one back on restores full sensitivity. Available while Audio Reactive is on.")
                quickToggleSection("Performance", icon: AppIcons.boltFill, rows: quickTogglePerformanceRows)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // ── Row models, grouped by section ──────────────────────────────────────

    /// Fractal-type-specific toggles. Built dynamically from
    /// `cache.fractalType.supports(_:)` so the section reflects the active
    /// formula (e.g. Julia Drift only on Mandelbulb Julia).
    private var quickToggleFormulaRows: [QuickToggleRow] {
        var rows: [QuickToggleRow] = []
        if cache.fractalType.supports(.polarRotation) {
            rows.append(QuickToggleRow("Polar Rotation", AppIcons.arrowTriangleheadCounterclockwiseRotate90,
                home: .effectsDynamic,
                get: { cache.lighting.polarRotationEffect.enabled },
                set: { v in
                    cache.lighting.polarRotationEffect.enabled = v
                    cache.push(\.polarRotationEffect, value: cache.lighting.polarRotationEffect)
                }))
        }
        if cache.fractalType.supports(.juliaDrift) {
            rows.append(QuickToggleRow("Julia Drift", "wind",
                home: .effectsDynamic,
                get: { cache.lighting.juliaDriftEffect.enabled },
                set: { cache.lighting.juliaDriftEffect.enabled = $0; cache.commitJuliaDriftEffect() }))
        }
        return rows
    }

    private var quickToggleLightingRows: [QuickToggleRow] {
        [
            QuickToggleRow("Glow", "sun.max", home: .effectsAtmosphere,
                get: { cache.lighting.glowEffect.enabled },
                set: { cache.lighting.glowEffect.enabled = $0; cache.commitGlowEffect() }),
            QuickToggleRow("Bloom", "sparkles", home: .effectsAtmosphere,
                get: { cache.lighting.bloomEffect.enabled },
                set: { cache.lighting.bloomEffect.enabled = $0; cache.commitBloomEffect() }),
            QuickToggleRow("Fog", "cloud.fog", home: .effectsAtmosphere,
                get: { cache.lighting.fogEffect.enabled },
                set: { cache.lighting.fogEffect.enabled = $0; cache.commitFogEffect() }),
            QuickToggleRow("Hue Rotation", "paintpalette", home: .effectsDynamic,
                get: { cache.lighting.hueRotationEffect.enabled },
                set: { cache.lighting.hueRotationEffect.enabled = $0; cache.commitHueRotationEffect() }),
            QuickToggleRow("Pulse", "waveform.path.ecg", home: .effectsDynamic,
                get: { cache.lighting.pulseEffect.enabled },
                set: { cache.lighting.pulseEffect.enabled = $0; cache.commitPulseEffect() }),
            QuickToggleRow("Gradient Cycle", "circle.hexagongrid", home: .effectsDynamic,
                get: { cache.lighting.gradientCycleEffect.enabled },
                set: { cache.lighting.gradientCycleEffect.enabled = $0; cache.commitGradientCycleEffect() }),
            QuickToggleRow("Linear Rail", "slider.horizontal.below.rectangle", home: .effectsDynamic,
                get: { cache.lighting.linearRailEffect.enabled },
                set: { cache.lighting.linearRailEffect.enabled = $0; cache.commitLinearRailEffect() }),
        ]
    }

    private var quickToggleSpaceRows: [QuickToggleRow] {
        [
            // Sphere Projection now lives in the Transformations section (Shape →
            // Transform) alongside the warp stack, so long-press jumps there.
            QuickToggleRow("Sphere Projection", "globe.asia.australia",
                home: .shapeTransformations,
                available: { cache.fractalType.supports(.sphereProjection) },
                get: { cache.display.sphereProjectionEnabled },
                set: { cache.display.sphereProjectionEnabled = $0; cache.commitSphereProjection() }),
            QuickToggleRow("Shape", "circle.dashed", home: .shapeBounding,
                // Independent toggle — does NOT turn Scrunch off.
                get: { cache.quality.boundingSphereSkipEnabled },
                set: { cache.setBoundingShapeEnabled($0) }),
            QuickToggleRow("Surroundings Containment", "square.3.layers.3d",
                home: .shapeBounding,
                // Independent toggle — does NOT turn the Bounding shape off.
                get: { cache.quality.envScrunchEnabled },
                set: { cache.setScrunchEnabled($0) }),
        ]
    }

    /// Individual audio components: the master reactive switch, beat-driven
    /// flash, and per-band quick mutes (bass/mid/treble/beat). Bands map an
    /// on/off tile to full (1.0) / muted (0.0) sensitivity.
    private var quickToggleAudioRows: [QuickToggleRow] {
        let masterOn: @MainActor () -> Bool = { cache.audioReactive.fractalAudioReactiveEnabled }
        func band(_ label: String, _ icon: String,
                  get: @escaping @MainActor () -> Float,
                  set: @escaping @MainActor (Float) -> Void) -> QuickToggleRow {
            // No `home`: bands are quick on/off mutes with no dedicated slider to
            // jump to (per-band sensitivity is only set via reactivity presets),
            // so they don't get a "go to controls" affordance.
            QuickToggleRow(label, icon, available: masterOn,
                get: { get() > 0 },
                set: { set($0 ? 1.0 : 0.0) })
        }
        return [
            QuickToggleRow("Audio Reactive", "waveform", home: .audioReactive,
                get: masterOn,
                set: { v in
                    cache.audioReactive.fractalAudioReactiveEnabled = v
                    cache.push(\.fractalAudioReactiveEnabled, value: v)
                }),
            QuickToggleRow("Beat Flash", "bolt", home: .effectsDynamic,
                get: { cache.lighting.beatFlashEffect.enabled },
                set: { cache.lighting.beatFlashEffect.enabled = $0; cache.commitBeatFlashEffect() }),
            band("Bass", "speaker.wave.1",
                get: { cache.audioReactive.bassSensitivity },
                set: { cache.audioReactive.bassSensitivity = $0; cache.push(\.bassSensitivity, value: $0) }),
            band("Mid", "speaker.wave.2",
                get: { cache.audioReactive.midSensitivity },
                set: { cache.audioReactive.midSensitivity = $0; cache.push(\.midSensitivity, value: $0) }),
            band("Treble", "speaker.wave.3",
                get: { cache.audioReactive.trebleSensitivity },
                set: { cache.audioReactive.trebleSensitivity = $0; cache.push(\.trebleSensitivity, value: $0) }),
            band("Beat", "metronome",
                get: { cache.audioReactive.beatSensitivity },
                set: { cache.audioReactive.beatSensitivity = $0; cache.push(\.beatSensitivity, value: $0) }),
        ]
    }

    private var quickTogglePerformanceRows: [QuickToggleRow] {
        [
            QuickToggleRow("Smart Advance", "bolt", home: .shapePerformance,
                get: { appModel.renderSettings.smartAdvanceEnabled },
                set: { appModel.renderSettings.smartAdvanceEnabled = $0 }),
            QuickToggleRow("Coherent Packet", "square.grid.3x3", home: .shapePerformance,
                get: { appModel.renderSettings.coherentPacketEnabled },
                set: { appModel.renderSettings.coherentPacketEnabled = $0 }),
            QuickToggleRow("Self-Shadows", "moon", home: .shapePerformance,
                get: { cache.quality.shadowsEnabled },
                set: { cache.quality.shadowsEnabled = $0; cache.push(\.shadowsEnabled, value: $0) }),
            // Bounding Shape moved to the Space section (it's a containment
            // control, not a raw perf knob) — see `quickToggleSpaceRows`.
            QuickToggleRow("Zoom Fog Comp", "cloud.fog",
                get: { cache.quality.zoomFogCompensationEnabled },
                set: { cache.quality.zoomFogCompensationEnabled = $0; cache.push(\.zoomFogCompensationEnabled, value: $0) }),
        ]
    }

    /// Formula section — its own view because it may be empty (some fractal
    /// types expose no formula-specific toggles) and shows a hint instead.
    private var quickToggleFormulaSection: some View {
        let rows = quickToggleFormulaRows
        return VStack(alignment: .leading, spacing: 10) {
            Label("Formula — \(cache.fractalType.displayName)", systemImage: "function")
                .font(.headline)
            if rows.isEmpty {
                Text("This fractal type has no formula-specific toggles. Switch to Mandelbulb, a Julia, or Quaternion type to reveal polar rotation and Julia drift.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                quickToggleGrid(rows)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One row of the quick-toggles page. `available` gates whether the toggle
    /// is interactive for the current fractal (disabled + dimmed when not).
    /// `home` is where the control's full slider lives — long-pressing the tile
    /// jumps there.
    struct QuickToggleRow: Identifiable {
        var id: String { label }
        let label: String
        let icon: String
        let home: QuickToggleHome?
        let available: @MainActor () -> Bool
        let get: @MainActor () -> Bool
        let set: @MainActor (Bool) -> Void

        init(_ label: String, _ icon: String,
             home: QuickToggleHome? = nil,
             available: @escaping @MainActor () -> Bool = { true },
             get: @escaping @MainActor () -> Bool,
             set: @escaping @MainActor (Bool) -> Void) {
            self.label = label; self.icon = icon; self.home = home
            self.available = available; self.get = get; self.set = set
        }
    }

    /// A titled section: header + a responsive grid of toggle tiles.
    private func quickToggleSection(_ title: String, icon: String,
                                    rows: [QuickToggleRow],
                                    footnote: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            quickToggleGrid(rows)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Responsive grid of toggle tiles — fills the available width, wrapping
    /// into as many columns as fit.
    private func quickToggleGrid(_ rows: [QuickToggleRow]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
            ForEach(rows) { quickToggleTile($0) }
        }
    }

    /// Rainbow fill used to mark a tile as ON. Diagonal so adjacent tiles read
    /// as a continuous spectrum block of "live" features.
    private var quickToggleOnFill: LinearGradient {
        LinearGradient(
            colors: [.red, .orange, .yellow, .green, .blue, .purple],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// A single tile: the whole rectangle is both the button and the toggle.
    /// Tap flips it (rainbow = on, grey = off); long-press jumps to where the
    /// control's full slider lives (`row.home`). Dimmed + non-interactive when
    /// the feature isn't available for the current fractal / audio state.
    ///
    /// Uses a tap + long-press gesture pair: a completed long press navigates,
    /// a quick tap toggles. For assistive tech the toggle is exposed as the
    /// default accessibility action and the navigation as a named action, since
    /// raw gestures aren't surfaced to VoiceOver/keyboard.
    private func quickToggleTile(_ row: QuickToggleRow) -> some View {
        let available = row.available()
        let on = row.get()
        let tile = VStack(spacing: 6) {
            Image(systemName: row.icon)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
            Text(row.label)
                .font(.caption)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 72)
        .padding(8)
        .foregroundStyle(on ? Color.white : Color.secondary)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(on ? AnyShapeStyle(quickToggleOnFill)
                         : AnyShapeStyle(Color.gray.opacity(0.16)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(on ? Color.white.opacity(0.35) : Color.white.opacity(0.08),
                              lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            // Subtle hint that the tile has a "go to controls" affordance.
            if row.home != nil {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(on ? Color.white.opacity(0.7) : Color.secondary.opacity(0.5))
                    .padding(6)
            }
        }
        .shadow(color: on ? .black.opacity(0.18) : .clear, radius: 4, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .opacity(available ? 1 : 0.3)
        .animation(.easeInOut(duration: 0.18), value: on)
        // Long-press first so a completed hold navigates instead of toggling;
        // a quick tap falls through to the toggle.
        .onLongPressGesture(minimumDuration: 0.4) {
            if let home = row.home { openQuickToggleHome(home) }
        }
        .onTapGesture {
            row.set(!row.get())
        }
        .disabled(!available)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.label)
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
        // VoiceOver/keyboard activation → toggle; raw gestures aren't surfaced to
        // assistive tech, so back the tap with an explicit default action.
        .accessibilityAction { row.set(!row.get()) }
        .help(row.home != nil ? "\(row.label) — long-press to open its controls" : row.label)

        // Expose the long-press navigation as a discrete VoiceOver/keyboard action
        // (only when there's somewhere to go), since long-press isn't reachable by
        // assistive tech.
        if let home = row.home {
            return AnyView(tile.accessibilityAction(named: Text("Open controls")) {
                openQuickToggleHome(home)
            })
        }
        return AnyView(tile)
    }

    // MARK: - Display sub-view

    /// Display-focused settings: Platform (visionOS), handedness, lighting,
    /// HUD toggles, and resolution. Extracted from the old "General" tab
    /// so the user has one place to find visual / display-related knobs.
    private var settingsDisplayContent: some View {
        VStack(spacing: 12) {
            // Platform — only relevant on visionOS. On iOS/macOS the
            // immersive floor field is never rendered, so the section is
            // hidden entirely.
#if os(visionOS)
            platformSection
#endif

            // Handedness lives in display, not gestures: it affects which
            // hand the renderer treats as the dominant one and the user
            // expects to find it next to other "how I look at the scene"
            // controls.
            handednessSection

            // Text size — Dynamic Type for the menu. visionOS only: Mac/iPad
            // already honor the system text-size setting, so an in-app knob would
            // be redundant there.
#if os(visionOS)
            textSizeSection
#endif

            // Touch indicators — only meaningful where fingers touch the
            // render view directly.
#if os(iOS)
            touchIndicatorsSection
#endif

#if os(macOS)
            macLauncherSection
#endif

            // Experimental display features (kept here, not in Advanced,
            // because they're visual toggles the user can flip while the
            // scene is running).
            experimentalDisplaySection
        }
    }

#if os(macOS)
    private var macLauncherSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Viewport Control Launcher", systemImage: "circle.grid.cross")
                .font(.headline)
            Toggle("Enable radial and grid launcher", isOn: $isMacTabLauncherEnabled)
            Text("When enabled, click the viewport or push right at the screen edge to reveal the launcher. Disable it to use the standard controls sidebar only.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
#endif

    /// VisionOS-only glass-floor platform settings. Mirrors the
    /// `ContentView+FractalTab` block but is the canonical home for these
    /// controls now that Settings has a Display sub-tab.
#if os(visionOS)
    private var platformSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Platform", systemImage: AppIcons.circleHexagongridFill)
                    .font(.headline)
                Spacer()
                if cache.display.platformEnabled {
                    Text(String(format: "%.1f m", cache.display.platformRadius))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Toggle("Show Platform", isOn: Binding(
                    get: { cache.display.platformEnabled },
                    set: { cache.display.platformEnabled = $0 }
                ))
                .labelsHidden()
                .tint(.cyan)
            }

            Text("Renders a glass floor in the immersive space. The fractal color blends through it so the platform reads as a thick transparent surface. Disable for a clean floor-less view.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if cache.display.platformEnabled {
                EffectSliderRow(icon: "circle.dotted", label: "Radius",
                    value: Binding(
                        get: { cache.display.platformRadius },
                        set: { cache.display.platformRadius = $0 }
                    ), range: 0.5...2.5,
                    enabled: .constant(true),
                    onChanged: { cache.commitPlatformRadius() },
                    showToggle: false)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cyan.opacity(0.07)))
    }
#endif

    /// iOS-only toggle for the fingertip glow indicators drawn over the
    /// render view (cyan = orbit, violet = pan/zoom).
#if os(iOS)
    private var touchIndicatorsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $showTouchIndicators) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Touch Indicators", systemImage: AppIcons.handTapFill)
                        .font(.headline)
                    Text("Shows a glowing dot under each finger on the fractal view, tinted by gesture: cyan while orbiting, violet while panning or zooming.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(.cyan)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cyan.opacity(0.07)))
    }
#endif

    /// Hand-dominance picker. Affects which hand the renderer treats as
    /// the dominant one for asymmetric controls (e.g. the "menu" hand).
    private var handednessSection: some View {
        let handedBinding = Binding<Bool>(
            get: { appModel.renderSettings.leftHandedMode },
            set: { appModel.renderSettings.leftHandedMode = $0 }
        )
        return VStack(alignment: .leading, spacing: 8) {
            Label("Handedness", systemImage: AppIcons.handPointUpLeftFill)
                .font(.headline)
            Picker("Dominant hand", selection: handedBinding) {
                Label("Right", systemImage: AppIcons.handRaisedFingersSpreadFill).tag(false)
                Label("Left",  systemImage: AppIcons.handRaisedFingersSpread).tag(true)
            }
            .pickerStyle(.segmented)
            Text("Choose your dominant hand. Some per-finger tap defaults are mirrored automatically.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.indigo.opacity(0.07)))
    }

    /// Menu text size (visionOS). Enlarges the menu's text via Dynamic Type so it
    /// stays crisp and reflows — icons and chrome geometry are left alone. Backed
    /// by `@AppStorage(DS.textSizeStorageKey)` on `ContentView` and applied on the
    /// menu body via `.dynamicTypeSize`, so text resizes live as the slider moves.
#if os(visionOS)
    private var textSizeSection: some View {
        // Discrete slider over DS.textSizeSteps via a Double proxy binding.
        let stepBinding = Binding<Double>(
            get: { Double(uiMenuTextSizeIndex) },
            set: { uiMenuTextSizeIndex = Int($0.rounded()) }
        )
        let lastIndex = DS.textSizeSteps.count - 1
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Text Size", systemImage: "textformat.size")
                    .font(.headline)
                Spacer()
                Text(DS.textSizeLabel(forIndex: uiMenuTextSizeIndex))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Slider(value: stepBinding, in: 0...Double(lastIndex), step: 1)
                .tint(.indigo)

            HStack {
                Text("Enlarges the menu's text while keeping it sharp; the panels reflow to fit. Icons and buttons are left at their normal size.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Reset") { uiMenuTextSizeIndex = DS.defaultTextSizeIndex }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                    .disabled(uiMenuTextSizeIndex == DS.defaultTextSizeIndex)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.indigo.opacity(0.07)))
    }
#endif

    /// Display-flavored experimental toggles. The custom-shenes enable is
    /// a display-runtime knob (it gates whether the renderer tries to
    /// compile user-supplied shaders), so it lives here.
    private var experimentalDisplaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Experimental Display", systemImage: AppIcons.flaskFill)
                    .font(.headline)
                Text("BETA")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.25)))
                    .foregroundStyle(.orange)
                Spacer()
            }

            Toggle(isOn: $allowCustomScenes) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow custom scenes")
                        .font(.subheadline.weight(.semibold))
                    Text("Enables loading .threshfx files and custom shader formulas. Default parameters may not be ideal and some scenes may not render correctly yet.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(.orange)

            VStack(alignment: .leading, spacing: 4) {
                CompactValueSlider(
                    title: "Sphere Projection Mismatch (δ)",
                    value: Binding(
                        get: { cache.display.deIterationMismatch },
                        set: {
                            cache.display.deIterationMismatch = $0
                            cache.push(\.deIterationMismatch, value: $0)
                        }
                    ),
                    range: -8...8,
                    display: String(format: "%+.2f", cache.display.deIterationMismatch),
                    tint: .orange
                )
                Text("δ biases the geometry fold loop (FC_FRACTAL_ITERATIONS) while the distance estimator stays normalized to the base count — the faithful \"Accidental Sphere Projection\" under-fold. Negative → fewer folds → sphere. 0 = off. Saves with the scene.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.06)))
    }

    // MARK: - Gestures sub-view

    // MARK: - Sharing sub-view

    /// Sharing sub-view: Community Sharing (analytics + username) and
    /// iCloud Drive backup. Sharing is **on by default** — the user must
    /// opt out by turning the toggle off. The username is independent
    /// and is always shown so the user can set an attribution handle
    /// without enabling sharing.
    private var settingsSharingContent: some View {
        VStack(spacing: 12) {
            storageLocationSection
            communitySharingSection
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: Storage Location (On This Device / iCloud Drive)
    // ─────────────────────────────────────────────────────────────────

    @ViewBuilder
    private var storageLocationSection: some View {
        let mode = StorageLocation.shared.mode
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Storage Location", systemImage: AppIcons.folder).font(.headline)
                Spacer()
                if mode == .iCloud && !StorageLocation.shared.isICloudAvailable {
                    ProgressView().controlSize(.small)
                }
            }

            Text("Where your scenes, animations, and presets live. Pick **iCloud Drive** to browse them in Files and sync across your devices; **On This Device** keeps them private to this device. A local safety backup is always kept either way, and switching merges both stores so nothing is lost.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Storage", selection: Binding(
                get: { StorageLocation.shared.mode },
                set: { newMode in appModel.switchStorageMode(to: newMode) }
            )) {
                ForEach(StorageMode.allCases, id: \.self) { m in
                    Label(m.displayName, systemImage: m.iconName).tag(m)
                }
            }
            .pickerStyle(.segmented)

            if mode == .iCloud {
                if StorageLocation.shared.isICloudAvailable {
                    Text("Browse in Files → iCloud Drive → **Threshold**.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("iCloud Drive isn't available yet — sign in to iCloud in System Settings. Your data stays on this device until it resolves.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(DS.Spacing.md)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.cyan.opacity(0.07)))
    }

    private var communitySharingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Community Sharing", systemImage: AppIcons.person3Fill)
                    .font(.headline)
                Spacer()
                Image(systemName: UsageAnalytics.shared.analyticsEnabled
                      ? "checkmark.circle.fill"
                      : "minus.circle")
                    .foregroundStyle(UsageAnalytics.shared.analyticsEnabled ? .green : .secondary)
                    .help(UsageAnalytics.shared.analyticsEnabled
                          ? "Sharing is on"
                          : "Sharing is off")
            }

            // Flipped copy: "on by default" is the headline.
            Text("On by default. Disable below to opt out. No account is created and no Apple ID, email, or location is required.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: Binding(
                get: { UsageAnalytics.shared.analyticsEnabled },
                set: { UsageAnalytics.shared.analyticsEnabled = $0 }
            )) {
                Label(
                    UsageAnalytics.shared.analyticsEnabled ? "Sharing with the community" : "Sharing is off",
                    systemImage: UsageAnalytics.shared.analyticsEnabled ? AppIcons.person3Fill : AppIcons.personSlash
                )
            }
            .tint(.blue)

            VStack(alignment: .leading, spacing: 6) {
                Text("Display Name (optional)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Leave blank to share anonymously", text: Binding(
                    get: { UsageAnalytics.shared.communityDisplayName },
                    set: { UsageAnalytics.shared.communityDisplayName = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                Text("Used only for community credits. Stays on this device — never leaves your Mac. Leave blank to share anonymously.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("What you're opting into:", systemImage: AppIcons.checkmarkCircle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("• Your settings can be reviewed for future community features\n• Shared setups may appear later in original or altered form\n• If you add a user name, it can be used for attribution\n• Aggregated usage stats help us improve performance and features")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(DS.Spacing.md)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.07)))
    }

    // (Old `settingsGeneralContent` removed — the settings tab now
    // dispatches to `settingsDisplayContent` / `settingsGesturesContent`
    // / `settingsSharingContent` / `settingsExportContent` /
    // `settingsAdvancedContent` based on the segmented sub-tab picker.)

    private var themeColor: Color {
        // Derive theme color from the current gradient preset
        switch cache.color.gradientState.gradientPreset {
        case .classic:    return Color(red: 0.8, green: 0.5, blue: 0.2)
        case .ocean:      return Color(red: 0.1, green: 0.5, blue: 0.9)
        case .fire:       return Color(red: 1.0, green: 0.4, blue: 0.1)
        case .forest:     return Color(red: 0.2, green: 0.7, blue: 0.3)
        case .nebula:     return Color(red: 0.6, green: 0.3, blue: 0.9)
        case .mono:       return Color(red: 0.5, green: 0.5, blue: 0.55)
        case .aurora:     return Color(red: 0.2, green: 0.9, blue: 0.6)
        case .volcanic:   return Color(red: 0.9, green: 0.3, blue: 0.1)
        case .neonCyber:  return Color(red: 1.0, green: 0.2, blue: 0.8)
        case .neonSunset: return Color(red: 1.0, green: 0.5, blue: 0.3)
        case .neonMatrix: return Color(red: 0.0, green: 1.0, blue: 0.4)
        case .rainbow:    return Color(red: 0.9, green: 0.4, blue: 0.5)
        case .infrared:   return Color(red: 0.8, green: 0.2, blue: 0.2)
        case .twilight:   return Color(red: 0.5, green: 0.3, blue: 0.7)
        case .none:       return Color(red: 0.6, green: 0.3, blue: 0.9)  // default nebula
        }
    }


    
    // MARK: - Export & Share Tab

    private var settingsExportContent: some View {
        VStack(spacing: 12) {
            // ── Current Preset Export ────────────────────────────────────
            VStack(spacing: 8) {
                HStack {
                    Label("Current Preset", systemImage: AppIcons.squareAndArrowUp)
                        .font(.headline)
                    Spacer()
                }
                Text("Export the current render settings as a shareable preset file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    Button {
                        let preset = FractalPreset.fromSettings(
                            appModel.renderSettings,
                            name: "Export",
                            embeddedFormula: appModel.activeEmbeddedFormula
                        )
                        exportOffMain({ PresetManager.exportPresetFile(preset) }) { url in
                            exportShareItem = ExportShareItem(url: url)
                        }
                    } label: {
                        Label("Export Preset (.threshscene)", systemImage: AppIcons.docBadgeArrowUp)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(themeColor)
                }

                let hasMusicMappings = !(appModel.renderSettings.musicReactiveMappings.isEmpty)
                if hasMusicMappings {
                    Button {
                        var preset = FractalPreset.fromSettings(
                            appModel.renderSettings,
                            name: "Music Export",
                            embeddedFormula: appModel.activeEmbeddedFormula
                        )
                        preset.musicReactiveMappings = appModel.renderSettings.musicReactiveMappings
                        let musicPreset = preset
                        exportOffMain({ PresetManager.exportPresetFile(musicPreset) }) { url in
                            exportShareItem = ExportShareItem(url: url)
                        }
                    } label: {
                        Label("Export Music Preset (.threshmp)", systemImage: AppIcons.musicNoteList)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(themeColor.opacity(0.06)))

            // ── Saved Presets Export ─────────────────────────────────────
            VStack(spacing: 8) {
                HStack {
                    Label("Saved Presets", systemImage: AppIcons.squareStack3dUp)
                        .font(.headline)
                    Spacer()
                }
                Text("Export saved presets. Presets with audio mappings export as music presets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if appModel.presetManager.presets.isEmpty {
                    Text("No saved presets.")
                        .foregroundStyle(.tertiary)
                        .font(.subheadline)
                        .padding(.vertical, 4)
                } else {
                    ForEach(appModel.presetManager.presets) { preset in
                        let hasMusic = !(preset.musicReactiveMappings?.isEmpty ?? true)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name).font(.subheadline.weight(.medium))
                                HStack(spacing: 6) {
                                    Text(".\(ThresholdExportFormat.preset(hasMusic: hasMusic).ext)")
                                    if hasMusic {
                                        Label("Music", systemImage: AppIcons.musicNote)
                                    }
                                    if preset.embeddedFormula != nil {
                                        Label("Formula", systemImage: AppIcons.function)
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                exportOffMain({ PresetManager.exportPresetFile(preset) }) { url in
                                    exportShareItem = ExportShareItem(url: url)
                                }
                            } label: {
                                Image(systemName: AppIcons.squareAndArrowUp)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(themeColor.opacity(0.06)))

            // ── Custom Formula Export ────────────────────────────────────
            if let formula = appModel.activeEmbeddedFormula {
                VStack(spacing: 8) {
                    HStack {
                        Label("Custom Formula", systemImage: AppIcons.function)
                            .font(.headline)
                        Spacer()
                    }
                    Text("Export the active custom formula as a standalone shader file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(formula.name).font(.subheadline.weight(.medium))
                            if let author = formula.author, !author.isEmpty {
                                Text("by \(author)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            let container = EmbeddedFormulaContainer(formula: formula)
                            exportOffMain({ container.exportToFile() }) { url in
                                exportShareItem = ExportShareItem(url: url)
                            }
                        } label: {
                            Label("Export Formula (.threshfx)", systemImage: AppIcons.docBadgeArrowUp)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.06)))
            }

            // ── Animation Scene Export ───────────────────────────────────
            VStack(spacing: 8) {
                HStack {
                    Label("Animation Scenes", systemImage: AppIcons.filmStack)
                        .font(.headline)
                    Spacer()
                }
                Text("Export animation scenes. Scenes with attached songs export as music videos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let mgr = appModel.animationManager {
                    if mgr.scenes.isEmpty {
                        Text("No scenes available.")
                            .foregroundStyle(.tertiary)
                            .font(.subheadline)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(mgr.scenes) { scene in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(scene.name).font(.subheadline.weight(.medium))
                                    HStack(spacing: 6) {
                                        Text("\(scene.keyframes.count) keyframes")
                                        if scene.attachedSong != nil {
                                            Label("Music", systemImage: AppIcons.musicNote)
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    exportOffMain({ AnimationManager.exportSceneFile(scene) }) { url in
                                        exportShareItem = ExportShareItem(url: url)
                                    }
                                } label: {
                                    Image(systemName: AppIcons.squareAndArrowUp)
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } else {
                    Text("Animation manager not available.")
                        .foregroundStyle(.tertiary)
                        .font(.subheadline)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.06)))

            // ── File Format Reference ───────────────────────────────────
            VStack(spacing: 8) {
                HStack {
                    Label("File Formats", systemImage: AppIcons.docText)
                        .font(.headline)
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 4) {
                    // Single source of truth shared with the export writers.
                    ForEach(ThresholdExportFormat.allCases, id: \.ext) { format in
                        formatRow(ext: ".\(format.ext)", desc: format.summary)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))
        }
        .sheet(item: $exportShareItem) { item in
            // Use the same native share UI as the Presets library so the two
            // export paths behave identically. UIActivityViewController /
            // NSSharingServicePicker dismiss themselves once the user picks a
            // destination or cancels — the previous custom ShareLink sheet had
            // no dismiss control and could get stuck on visionOS/macOS.
            ShareSheet(activityItems: [item.url])
        }
        #if os(macOS)
        // NSSharingServicePicker presents as a child window, pulling the
        // pointer off the sidebar's hover region — hold the panel open while
        // it's up, same as the other Mac sheets/popovers.
        .onChange(of: exportShareItem != nil) { _, isPresented in
            updateMacSheetMenuAdjustment(isPresented, holding: &isHoldingExportSheetAdjustment)
        }
        #endif
    }

    private func formatRow(ext: String, desc: String) -> some View {
        HStack(spacing: 8) {
            Text(ext)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(themeColor)
                .frame(width: 110, alignment: .leading)
            Text(desc)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
    
    /// Reusable "EXPERIMENTAL" pill. Single source of truth for the badge that
    /// previously appeared copy-pasted on each Advanced raymarcher card.
    private var experimentalBadge: some View {
        Text("EXPERIMENTAL")
            .font(.caption2.bold())
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
    }

    /// Grouped raymarcher acceleration controls (Advanced tab). Collects the
    /// distance-field march knobs — Smart Advance, Coherent Packet, and
    /// Foveation — into a single card with subtle dividers, replacing the three
    /// loose, badge-duplicating blocks that used to float in the Advanced list.
    private var raymarcherSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: AppIcons.boltFill).foregroundStyle(themeColor)
                Text("Raymarcher").font(.headline)
                Spacer()
                experimentalBadge
            }
            Text("Acceleration controls for the distance-field raymarcher. Each trades a little detail for speed in a different way — safe to flip while the scene is running.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().opacity(0.4)

            // ── Smart Advance — every render path ────────────────────────
            Toggle(isOn: Binding(
                get: { appModel.renderSettings.smartAdvanceEnabled },
                set: { appModel.renderSettings.smartAdvanceEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart Advance")
                    Text("Reads the gradient of the march to spot rays skimming nearly parallel to a surface, then leads ahead with larger steps where plain tracing would creep. Faster through open and grazing regions; can soften fine silhouette detail. Works on every render path.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.tint(themeColor)

            Divider().opacity(0.4)

            // ── Coherent Packet — 8×8 compute path only ──────────────────
            Toggle(isOn: Binding(
                get: { appModel.renderSettings.coherentPacketEnabled },
                set: { appModel.renderSettings.coherentPacketEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Coherent Packet")
                    Text("Predict-validate warm-start: a single DE-eval safety probe with a normal-coherence shadow gate. Shows a layer-of-acceptance debug overlay while on (magenta = hit, green = tight, red = rejected, cyan = shadow fallback). 8×8 compute path only.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.tint(themeColor)

            Divider().opacity(0.4)

            // ── Foveation — 8×8 compute path only ────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                CompactValueSlider(
                    title: "Foveation",
                    value: Binding(
                        get: { appModel.renderSettings.foveationStrength },
                        set: { appModel.renderSettings.foveationStrength = $0 }
                    ),
                    range: 0...1,
                    display: appModel.renderSettings.foveationStrength < 0.01 ? "Off" : "\(Int((appModel.renderSettings.foveationStrength * 100).rounded()))%",
                    tint: themeColor
                )
                Text("Peripheral 8×8 tiles march fewer ray steps, ramping from the center outward. 0 = off. Cuts GPU cost where peripheral vision can't resolve detail. 8×8 compute path only.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .background(themeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var settingsAdvancedContent: some View {
        @Bindable var appModel = appModel
        return VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: AppIcons.chartBarFill).foregroundStyle(themeColor)
                    Text("Performance in Menu").font(.headline)
                    Spacer()
                    Toggle("Show", isOn: $showPerformanceInMenu)
                        .labelsHidden()
                }
                Text("Keeps compact FPS, GPU frame time, and render quality visible in the bottom menu bar.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    StatBox(label: "FPS", value: String(format: "%.0f", cache.liveFPS), color: liveFPSColor)
                    StatBox(label: "Iterations", value: "\(cache.liveFractalIterations)", color: themeColor)
                    StatBox(label: "Ray Steps", value: "\(cache.liveMaxRaySteps)", color: themeColor.opacity(0.8))
                    StatBox(label: "Scale", value: String(format: "%.2f", cache.liveFractalScale), color: themeColor.opacity(0.6))
                }
            }.padding().background(themeColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))

            // Raymarcher acceleration toggles — Smart Advance, Coherent Packet,
            // and Foveation grouped into one card (see `raymarcherSection`).
            raymarcherSection

            VStack(alignment: .leading, spacing: 8) {
                RenderDiagnosticsView()
                Text("Live from the renderer. 'Drawable' is the actual per-eye render-target size the compositor granted — at 100% render quality it should reach the panel's native resolution. Render quality tracks the resolution slider.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }.padding().background(themeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

            // ── Performance Sweep (per-build Vision Pro perf log) ──
            VStack(alignment: .leading, spacing: 8) {
                HStack { Image(systemName: AppIcons.timer).foregroundStyle(themeColor); Text("Performance Sweep").font(.headline) }
                let runner = appModel.perfSweepRunner
                Button {
                    if runner.isRunning { runner.cancel() }
                    else { runner.start(appModel: appModel) }
                } label: {
                    HStack {
                        Image(systemName: runner.isRunning ? AppIcons.stopCircleFill : AppIcons.playCircleFill)
                        Text(runner.isRunning ? "Cancel Sweep" : "Run Benchmark Sweep")
                    }
                }.buttonStyle(.borderedProminent).tint(runner.isRunning ? .red : themeColor)

                if runner.isRunning, runner.totalScenes > 0 {
                    ProgressView(value: Double(runner.currentScene), total: Double(runner.totalScenes))
                        .tint(themeColor)
                }
                Text(runner.progressText)
                    .font(.caption2).foregroundStyle(.secondary)
                Text("Loads a curated set of scenes, measures GPU/CPU/FPS on this device, and appends one record to Documents/PerfLog/perf-log.jsonl (+ perf-log.md). Run it with the immersive view up. Pull the files via the Files app and append them to the repo's PERF_LOG.jsonl to track performance across builds.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding().background(themeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
