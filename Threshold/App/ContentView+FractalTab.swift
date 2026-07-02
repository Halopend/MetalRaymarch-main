//
//  ContentView+FractalTab.swift
//  Threshold
//
//  Fractal tab UI extracted from ContentView.swift (Phase C refactor).
//  Stored properties and computed helpers remain on the main `ContentView` struct.
//

import SwiftUI
import simd

extension ContentView {
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Fractal Tab
    // ═══════════════════════════════════════════════════════════════════════════
    
    var fractalTabContent: some View {
        VStack(spacing: 0) {
            switch fractalSubTab {
            case .browse:
                FractalGridView(
                    animationManager: appModel.animationManager,
                    presetManager: appModel.presetManager,
                    tabSelection: $fractalBrowseTab,
                    onEditScene: openAnimationEditor,
                    onLoadAnimationScene: { _ in
                        appModel.dismissMenuWindowForSceneLoad()
                    },
                    onLoadStaticScene: { preset in
                        appModel.loadStaticScene(preset)
                        appModel.dismissMenuWindowForSceneLoad()
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .shape:
                ScrollView(.vertical, showsIndicators: true) {
                    Group {
                        switch shapeInnerTab {
                        case .parameters:
                            fractalShapeContent
                        case .formula:
                            fractalFormulaContent
                        case .hands:
                            fractalHandsContent
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

            case .space:
                ScrollView(.vertical, showsIndicators: true) {
                    fractalSpaceContent
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }

            case .transform:
                ScrollView(.vertical, showsIndicators: true) {
                    fractalTransformContent
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }

            case .bounding:
                ScrollView(.vertical, showsIndicators: true) {
                    fractalBoundingContent
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }

            case .render:
                ScrollView(.vertical, showsIndicators: true) {
                    performanceTabContent
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            }
        }
    }
    
    private var fractalShapeContent: some View {
        VStack(spacing: 12) {
            HStack {
                Label(cache.fractalType.displayName, systemImage: cache.fractalType.icon)
                    .font(.headline)
                Spacer()
            }

            Divider()

            // Formula-specific parameters (auto-generated from catalog.json)
            FormulaParamsEditor(cache: cache)

            if hasShapeMusicMapping {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Label("Music Shape Control", systemImage: AppIcons.waveformPath)
                            .font(.headline)
                        if hasFlashingMusicVisuals {
                            FlashingLightIndicator()
                                .help("Current music mappings can produce flashing or rapidly changing light.")
                        }
                        Spacer()
                    }

                    Text("Global music amount for iteration and shape-parameter mappings.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    EffectSliderRow(icon: "waveform.circle", label: "Music Amount",
                        value: Binding(
                            get: { cache.audioReactive.fractalAudioAmount },
                            set: { newValue in
                                cache.audioReactive.fractalAudioAmount = newValue
                                cache.push(\.fractalAudioAmount, value: newValue)
                            }
                        ), range: 0...1,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.fractalAudioAmount, value: cache.audioReactive.fractalAudioAmount) },
                        showToggle: false)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.indigo.opacity(0.08)))
            }

            // Scale slider — only visible for Mandelbox (the only fractal whose
            // distance estimator uses this uniform).
            if cache.fractalType == .mandelbox {
                Divider()
                EffectSliderRow(icon: "arrow.up.left.and.arrow.down.right", label: "Scale",
                    value: $cache.fractalScale, range: ControlCatalog.fractalScale.range,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.targetFractalScale, value: cache.fractalScale) },
                    showToggle: false,
                    musicTargetID: ParameterTargetID.Core.fractalScale)
            }
        }
    }

    private var fractalFormulaContent: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Fractal Formula", systemImage: AppIcons.function)
                    .font(.headline)
                Spacer()
                Text(cache.fractalType.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text("Pick the distance estimator. Switching formulas resets shape parameters to that formula's defaults.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            FractalFormulaGrid(cache: cache, gestureController: appModel.gestureController)
        }
    }

    // ── Hands ────────────────────────────────────────────────────────────────
    // Per-hand interaction sphere on each tracked ARKit palm. Signed strength:
    // negative (default) makes the surface recoil from the hand, positive makes
    // it reach toward it. Pocket mode layers a small repel hollow at the hand
    // on top of an Attract shell, so geometry still pulls toward the hand's
    // vicinity while leaving a hollow where the hand physically sits.
    // visionOS only (needs hand tracking).
    private var fractalHandsContent: some View {
        VStack(spacing: 12) {
#if os(visionOS)
            VStack(spacing: 8) {
                HStack {
                    Label("Hand Attraction", systemImage: "hand.raised.fingers.spread")
                        .font(.headline)
                    Spacer()
                    Toggle("", isOn: $cache.handAttraction.enabled)
                        .labelsHidden()
                        .onChange(of: cache.handAttraction.enabled) { _, val in
                            cache.push(\.handAttractionEnabled, value: val)
                        }
                }
                Text("An interaction sphere on each tracked hand. Negative strength pushes the fractal surface away as you reach out; positive strength pulls it toward your palm.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if cache.handAttraction.enabled {
                    EffectSliderRow(icon: "circle.dashed", label: "Radius",
                        value: $cache.handAttraction.radius, range: 0.05...1.0,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.handAttractionRadius, value: cache.handAttraction.radius) },
                        showToggle: false)

                    EffectSliderRow(icon: "arrow.left.and.right", label: "Repel \u{2190}\u{2192} Attract",
                        value: $cache.handAttraction.strength, range: -1.0...1.0,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.handAttractionStrength, value: cache.handAttraction.strength) },
                        showToggle: false,
                        valueFormat: { v in
                            if abs(v) < 0.02 { return "Off" }
                            return v < 0 ? String(format: "Repel %.0f%%", -v * 100) : String(format: "Attract %.0f%%", v * 100)
                        })

                    // Fine-tuning lives behind Advanced so the everyday
                    // controls stay to Radius + Strength. Print Settings dumps
                    // the whole config as JSON for locking values in as defaults.
                    DisclosureGroup {
                        VStack(spacing: 8) {
                            EffectSliderRow(icon: "circle.fill", label: "Ball Size",
                                value: $cache.handAttraction.ballScale, range: 0.1...1.0,
                                enabled: .constant(true),
                                onChanged: { cache.push(\.handAttractionBallScale, value: cache.handAttraction.ballScale) },
                                showToggle: false,
                                valueFormat: { v in String(format: "%.0f%% of radius", v * 100) })

                            EffectSliderRow(icon: "aqi.medium", label: "Blend Softness",
                                value: $cache.handAttraction.softness, range: 0.05...2.0,
                                enabled: .constant(true),
                                onChanged: { cache.push(\.handAttractionSoftness, value: cache.handAttraction.softness) },
                                showToggle: false,
                                valueFormat: { v in String(format: "%.2f\u{00D7}", v) })

                            EffectSliderRow(icon: "arrow.up.forward", label: "Reach Offset",
                                value: $cache.handAttraction.projectionDistance, range: 0.0...1.0,
                                enabled: .constant(true),
                                onChanged: { cache.push(\.handAttractionProjectionDistance, value: cache.handAttraction.projectionDistance) },
                                showToggle: false,
                                valueFormat: { v in v < 0.005 ? "At hand" : String(format: "%.0f cm ahead", v * 100) })
                            Text("Reach Offset projects the ball outward from your body through the hand, so it floats in front of the palm instead of on it.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)

                            Divider()
                            HStack {
                                Label("Forearms", systemImage: "figure.wave")
                                    .font(.subheadline)
                                Spacer()
                                Toggle("", isOn: $cache.handAttraction.forearmEnabled)
                                    .labelsHidden()
                                    .onChange(of: cache.handAttraction.forearmEnabled) { _, val in
                                        cache.push(\.handAttractionForearmEnabled, value: val)
                                    }
                            }
                            Text("Extends the effect along each wrist\u{2192}elbow segment, so the whole forearm carves or pulls space, not just the palm.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            if cache.handAttraction.forearmEnabled {
                                EffectSliderRow(icon: "capsule", label: "Forearm Radius",
                                    value: $cache.handAttraction.forearmRadius, range: 0.02...0.3,
                                    enabled: .constant(true),
                                    onChanged: { cache.push(\.handAttractionForearmRadius, value: cache.handAttraction.forearmRadius) },
                                    showToggle: false,
                                    valueFormat: { v in String(format: "%.0f cm", v * 100) })
                            }

                            if cache.handAttraction.strength > 0.02 {
                                Divider()
                                HStack {
                                    Label("Pocket", systemImage: "circle.circle")
                                        .font(.subheadline)
                                    Spacer()
                                    Toggle("", isOn: $cache.handAttraction.pocketEnabled)
                                        .labelsHidden()
                                        .onChange(of: cache.handAttraction.pocketEnabled) { _, val in
                                            cache.push(\.handAttractionPocketEnabled, value: val)
                                        }
                                }
                                Text("Hollows out a small pocket right at the hand while the wider surface still pulls toward it — a place for the hand to sit.")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)

                                if cache.handAttraction.pocketEnabled {
                                    EffectSliderRow(icon: "circle.circle", label: "Pocket Size",
                                        value: $cache.handAttraction.pocketSize, range: 0.1...1.5,
                                        enabled: .constant(true),
                                        onChanged: { cache.push(\.handAttractionPocketSize, value: cache.handAttraction.pocketSize) },
                                        showToggle: false,
                                        valueFormat: { v in String(format: "%.0f%% of ball", v * 100) })

                                    EffectSliderRow(icon: "aqi.low", label: "Pocket Softness",
                                        value: $cache.handAttraction.pocketSoftness, range: 0.1...1.5,
                                        enabled: .constant(true),
                                        onChanged: { cache.push(\.handAttractionPocketSoftness, value: cache.handAttraction.pocketSoftness) },
                                        showToggle: false,
                                        valueFormat: { v in String(format: "%.2f\u{00D7}", v) })
                                }
                            }

                            Divider()
                            Button {
                                let config = appModel.renderSettings.handAttractionConfig
                                let encoder = JSONEncoder()
                                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                                if let data = try? encoder.encode(config),
                                   let json = String(data: data, encoding: .utf8) {
                                    print("\u{1F590} HandAttractionConfig — current values (paste into defaults):\n\(json)")
                                }
                            } label: {
                                Label("Print Settings to Console", systemImage: "printer")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.top, 6)
                    } label: {
                        Label("Advanced", systemImage: "slider.horizontal.3")
                            .font(.subheadline)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.pink.opacity(0.07)))
#else
            Text("Hand Attraction needs ARKit hand tracking and is available on visionOS only.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
#endif
        }
    }

    @ViewBuilder
    // Composable domain-transform stack (Twist / Bend / folds / inversion / kaleido /
    // ripple / Coxeter), reorderable + stackable — its own "Transform" rail section.
    private var fractalTransformContent: some View {
        VStack(spacing: 12) {
            TransformationsSection(renderSettings: appModel.renderSettings)
        }
    }

    private var fractalSpaceContent: some View {
        let rotationEuler = eulerAngles(from: cache.liveWorldRotation)

        return VStack(spacing: 12) {
            // ── Safety Bubble ────────────────────────────────────────────────
            VStack(spacing: 8) {
                HStack {
                    Label("Safety Bubble", systemImage: AppIcons.shieldLefthalfFilled).font(.headline)
                    Spacer()
                    Toggle("", isOn: $cache.safetyBubble.enabled)
                        .labelsHidden()
                        .onChange(of: cache.safetyBubble.enabled) { _, val in
                            cache.push(\.safetyBubbleEnabled, value: val)
                        }
                }
                Text("Prevents the camera from entering the fractal geometry. Works with all fractal types.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if cache.safetyBubble.enabled {
                    EffectSliderRow(icon: "circle.dashed", label: "Inner Radius",
                        value: $cache.safetyBubble.radius, range: 0.5...2.5,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.safetyBubbleRadius, value: cache.safetyBubble.radius) },
                        showToggle: false)

#if os(visionOS)
                    HStack {
                        Label("Shrink in Mixed", systemImage: "arrow.down.right.and.arrow.up.left")
                            .font(.subheadline)
                        Spacer()
                        Toggle("", isOn: $cache.safetyBubble.mixedAutoShrinkEnabled)
                            .labelsHidden()
                            .onChange(of: cache.safetyBubble.mixedAutoShrinkEnabled) { _, val in
                                cache.push(\.safetyBubbleMixedAutoShrink, value: val)
                            }
                    }
                    Text("While Mixed immersion is active, caps the bubble at the radius below — in Mixed you're outside the fractal, so a large bubble mostly hollows it out. Your saved radius returns when you leave Mixed.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if cache.safetyBubble.mixedAutoShrinkEnabled {
                        EffectSliderRow(icon: "circle.dashed", label: "Mixed Radius",
                            value: $cache.safetyBubble.mixedRadius, range: 0.05...1.0,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.safetyBubbleMixedRadius, value: cache.safetyBubble.mixedRadius) },
                            showToggle: false,
                            valueFormat: { v in String(format: "%.2f m", v) })
                    }
#endif
                    let selectedBubbleFamily = SafetyBubbleShapePreset.family(for: cache.safetyBubble.shape)
                    HStack {
                        Text("Shape"); Spacer()
                        Picker("Shape", selection: Binding<SafetyBubbleShapeFamily>(
                            get: { selectedBubbleFamily },
                            set: { family in
                                let newValue = SafetyBubbleShapePreset.storedValue(for: family, currentValue: cache.safetyBubble.shape)
                                cache.safetyBubble.shape = newValue
                                cache.push(\.safetyBubbleShape, value: newValue)
                            }
                        )) {
                            ForEach(SafetyBubbleShapeFamily.allCases) { family in
                                Text(family.rawValue).tag(family)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 260)
                    }
                    if selectedBubbleFamily == .platonic {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Platonic")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                                ForEach(SafetyBubbleShapePreset.platonicOptions) { preset in
                                    let isSelected = SafetyBubbleShapePreset(storedValue: cache.safetyBubble.shape) == preset

                                    Button {
                                        cache.safetyBubble.shape = preset.storedValue
                                        cache.push(\.safetyBubbleShape, value: preset.storedValue)
                                    } label: {
                                        Text(preset.displayName)
                                            .font(.caption.weight(.semibold))
                                            .frame(maxWidth: .infinity)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 8)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(isSelected ? Color.black : Color.primary)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(isSelected ? Color.white.opacity(0.88) : Color.white.opacity(0.08))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(Color.white.opacity(isSelected ? 0.14 : 0.08), lineWidth: 1)
                                    )
                                }
                            }
                        }
                    }
                    
                    Divider()
                    
                    Text("Controls how strongly the bubble masks fractal geometry. Fine control at low values.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Label("Blend mode cost varies by scene/fractal/zoom — different values can be expensive in different conditions (Mandelbox often runs better with Blend off, but can behave differently when zoomed in).", systemImage: AppIcons.exclamationmarkTriangle)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    EffectSliderRow(icon: "circle.righthalf.filled", label: "Blend",
                        value: Binding<Float>(
                            get: { 1.0 - UISettingsCache.blendValueToSlider(cache.safetyBubble.strength) },
                            set: { cache.safetyBubble.strength = UISettingsCache.blendSliderToValue(1.0 - $0) }
                        ), range: 0.0...1.0,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.safetyBubbleBlend, value: cache.safetyBubble.strength) },
                        showToggle: false)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.06)))

            // Platform section: only relevant on visionOS. The same controls
            // also live in Settings > Display, which is the canonical home
            // (and includes a "Show Platform" toggle). The in-Fractal copy
            // is a quick-adjust affordance while tweaking in the immersive
            // scene and is hidden entirely on iOS / macOS.
#if os(visionOS)
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
                    Toggle("Show", isOn: Binding(
                        get: { cache.display.platformEnabled },
                        set: { cache.display.platformEnabled = $0 }
                    ))
                    .labelsHidden()
                    .tint(.cyan)
                    .controlSize(.mini)
                }

                Text("Controls the glass floor field in the immersive space. The fractal color blends through it so the platform reads as a thick transparent surface. Toggle off for a clean floor-less view.")
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
#endif

            sphericalInversionSection

            sphereProjectionSection

            // (Transformations stack moved to its own rail section → fractalTransformContent.)

            // ── Detail (Grab Gesture Transform) ──────────────────────────────
            VStack(spacing: 8) {
                HStack {
                    Label("Detail", systemImage: AppIcons.move3d).font(.headline)
                    Spacer()
                    Button {
                        appModel.renderSettings.resetDetailTransform()
                    } label: {
                        Label("Reset", systemImage: AppIcons.arrowCounterclockwise)
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .controlSize(.small)
                }
                Text("Orientation and zoom controlled by the grab gesture (both hands pinch).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                
                HStack {
                    Label("Zoom", systemImage: AppIcons.magnifyingglass).font(.caption)
                    Spacer()
                    Text(String(format: "%.2f×", cache.liveDetailScale))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                EffectSliderRow(icon: "arrow.up.left.and.arrow.down.right", label: "Stretch",
                    value: Binding(
                        get: { cache.liveDetailScale },
                        set: { setDetailScale($0) }
                    ), range: 0.05...20.0,
                    enabled: .constant(true),
                    onChanged: {},
                    showToggle: false)
                
                HStack {
                    Label("Rotation", systemImage: AppIcons.rotate3d).font(.caption)
                    Spacer()
                    Text(String(format: "%.0f° %.0f° %.0f°", rotationEuler.x, rotationEuler.y, rotationEuler.z))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                EffectSliderRow(icon: "arrow.left.and.right", label: "Pitch",
                    value: Binding(
                        get: { rotationEuler.x },
                        set: { newValue in
                            var e = rotationEuler
                            e.x = newValue
                            setDetailRotationEuler(e)
                        }
                    ), range: -180...180,
                    enabled: .constant(true),
                    onChanged: {},
                    showToggle: false)

                EffectSliderRow(icon: "arrow.clockwise", label: "Yaw",
                    value: Binding(
                        get: { rotationEuler.y },
                        set: { newValue in
                            var e = rotationEuler
                            e.y = newValue
                            setDetailRotationEuler(e)
                        }
                    ), range: -180...180,
                    enabled: .constant(true),
                    onChanged: {},
                    showToggle: false)

                EffectSliderRow(icon: "arrow.up.and.down", label: "Roll",
                    value: Binding(
                        get: { rotationEuler.z },
                        set: { newValue in
                            var e = rotationEuler
                            e.z = newValue
                            setDetailRotationEuler(e)
                        }
                    ), range: -180...180,
                    enabled: .constant(true),
                    onChanged: {},
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.06)))
        }
    }

    private var sphericalInversionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Spherical Inversion", systemImage: AppIcons.circleDashedInsetFilled)
                    .font(.headline)
                Spacer()
            }

            Text("Warp space around a radius before the fractal is sampled. Useful for folded-inside-out spatial compositions.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Picker("Spherical Inversion", selection: Binding(
                get: { cache.display.sphericalInversionMode },
                set: { newValue in
                    cache.display.sphericalInversionMode = newValue
                    cache.commitSphericalInversion()
                }
            )) {
                ForEach(SphericalInversionMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if cache.display.sphericalInversionMode != .off {
                EffectSliderRow(icon: "circle", label: "Inversion Radius",
                    value: Binding(get: { cache.display.sphericalInversionRadius }, set: { cache.display.sphericalInversionRadius = $0 }),
                    range: ControlCatalog.sphericalInversionRadius.range,
                    enabled: Binding(get: { cache.display.sphericalInversionMode != .off }, set: { isEnabled in
                        cache.display.sphericalInversionMode = isEnabled ? .outwardIn : .off
                        cache.commitSphericalInversion()
                    }),
                    onChanged: { cache.commitSphericalInversion() })
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.indigo.opacity(0.06)))
    }

    // Data-driven (Stage 4): these boxes render SpaceModule's params at its route
    // via the shared `ModuleSectionView`, replacing the hand-written scaffolding.
    // The section content lives as data in ModuleSectionView.swift.
    private var sphereProjectionSection: some View {
        ModuleSectionView(section: .sphereProjection(cache: cache))
    }

    /// Custom space warp (the cross-platform space-module seam). The built-in
    /// default is a "Twist" about the vertical axis; a loaded `.threshfx`
    /// space-warp effect will override the GPU function (Stage 2). 0 = off.
    private var spaceWarpSection: some View {
        ModuleSectionView(section: .spaceWarp(renderSettings: appModel.renderSettings))
    }

    // ── Acceleration panel: the gamut of march speedup techniques ──
    // Each control trades a little quality for frame rate in a different way.
    // Bindings write the live RenderSettings (via cache.push) and the UI cache.
    // Defaults reproduce the renderer's prior behavior, so an untouched panel is
    // a no-op.

    /// Compact slider for the 2-column Acceleration grid: title + value on one
    /// line, slider below. The longer explanation moves to a hover/gaze tooltip
    /// so the panel stays short.
    private func accelSliderCompact(_ title: String,
                                    value: Float,
                                    range: ClosedRange<Float>,
                                    display: String,
                                    help: String,
                                    onChange: @escaping (Float) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                Text(display).font(.caption.weight(.bold)).monospacedDigit()
                    .foregroundStyle(display == "Off" ? Color.secondary : Color.cyan)
            }
            Slider(value: Binding(get: { value }, set: onChange), in: range)
                .tint(.cyan)
                .controlSize(.small)
        }
        .help(help)
    }

    /// Compact toggle for the horizontal toggle grid. Explanation in a tooltip.
    private func accelToggleCompact(_ title: String,
                                    isOn: Bool,
                                    help: String,
                                    onChange: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: onChange)) {
            Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.85)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(.cyan)
        .help(help)
    }

    private var fractalAccelerationSection: some View {
        // Two equal columns drive both the slider grid and the toggle ("checkmark")
        // grid so the whole panel reads side-by-side instead of one tall stack.
        let twoCol = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
        let isCompute = cache.quality.tileSize == 8
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: AppIcons.boltFill).foregroundStyle(.cyan)
                Text("Acceleration").font(.headline)
                Spacer()
                if !isCompute {
                    Text("Some need Adaptive Compute")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

            // ── Sliders, two per row. Foveation is Adaptive-Compute-only. ──
            LazyVGrid(columns: twoCol, alignment: .leading, spacing: 10) {
                accelSliderCompact("Over-Relaxation",
                            value: cache.quality.overRelaxationMax, range: 1.0...1.6,
                            display: String(format: "%.2f×", cache.quality.overRelaxationMax),
                            help: "How big a step the march takes in open space (Keinert enhanced sphere tracing). Higher = faster; lower = sharper on thin features. 1.0 = plain conservative tracing.") { v in
                    cache.quality.overRelaxationMax = v; cache.push(\.overRelaxationMax, value: v)
                }

                accelSliderCompact("Cone Marching",
                            value: cache.quality.coneMarchStrength, range: 0...1,
                            display: cache.quality.coneMarchStrength < 0.01 ? "Off" : "\(Int((cache.quality.coneMarchStrength * 100).rounded()))%",
                            help: "Stops each ray within its on-screen pixel footprint, so distant geometry needs far fewer steps. Higher = faster, but inflates distant silhouettes.") { v in
                    cache.quality.coneMarchStrength = v; cache.push(\.coneMarchStrength, value: v)
                }

                accelSliderCompact("Distance Falloff",
                            value: cache.quality.distanceLODStrength, range: 0...1,
                            display: cache.quality.distanceLODStrength < 0.01 ? "Off" : "\(Int((cache.quality.distanceLODStrength * 100).rounded()))%",
                            help: "Faraway geometry uses fewer fractal iterations, where the lost detail is already sub-pixel. Speeds up deep scenes without inflating silhouettes the way cone marching does.") { v in
                    cache.quality.distanceLODStrength = v; cache.push(\.distanceLODStrength, value: v)
                }

                accelSliderCompact("Foveation",
                            value: cache.quality.foveationStrength, range: 0...1,
                            display: cache.quality.foveationStrength < 0.01 ? "Off" : "\(Int((cache.quality.foveationStrength * 100).rounded()))%",
                            help: "Peripheral tiles march fewer steps, ramping from the center outward. Adaptive Compute renderer mode only.") { v in
                    cache.quality.foveationStrength = v; cache.push(\.foveationStrength, value: v)
                }
                .disabled(!isCompute)
                .opacity(isCompute ? 1 : 0.45)
            }

            Divider().opacity(0.4)

            // ── Toggles ("checkmarks"), arranged horizontally two per row. ──
            LazyVGrid(columns: twoCol, alignment: .leading, spacing: 8) {
                accelToggleCompact("Smart Advance",
                            isOn: cache.quality.smartAdvanceEnabled,
                            help: "Leads ahead with larger steps through grazing/receding regions where plain tracing creeps. Faster on open and grazing angles; can soften fine silhouettes.") { v in
                    cache.quality.smartAdvanceEnabled = v; cache.push(\.smartAdvanceEnabled, value: v)
                }

                accelToggleCompact("Self-Shadows",
                            isOn: cache.quality.shadowsEnabled,
                            help: "Soft self-shadowing from the spotlight and sun. Turning it off skips two extra marches on every lit pixel — a large saving — for flatter, faster lighting.") { v in
                    cache.quality.shadowsEnabled = v; cache.push(\.shadowsEnabled, value: v)
                }

                accelToggleCompact("Coherent Packet",
                            isOn: cache.quality.coherentPacketEnabled,
                            help: "Predict-validate warm-start probe with a normal-coherence shadow gate; shows a debug overlay while on. Adaptive Compute renderer mode only.") { v in
                    cache.quality.coherentPacketEnabled = v; cache.push(\.coherentPacketEnabled, value: v)
                }
                .disabled(!isCompute)
                .opacity(isCompute ? 1 : 0.45)

                accelToggleCompact("Temporal Reproject",
                            isOn: cache.quality.computeTemporalReprojectionEnabled,
                            help: "Reuses last frame's depth to skip most of the march — the path's main speedup. Currently can blank disoccluded 8×8/32×32 tiles, so it's off by default for a correct, comparable image. Adaptive Compute renderer mode only.") { v in
                    cache.quality.computeTemporalReprojectionEnabled = v; cache.push(\.computeTemporalReprojectionEnabled, value: v)
                }
                .disabled(!isCompute)
                .opacity(isCompute ? 1 : 0.45)

                accelToggleCompact("Cone Warm-Start",
                            isOn: cache.quality.coarsePrepassWarmStartEnabled,
                            help: "A low-res cone pre-pass marches one cone per 8×8 block and writes a provable lower bound on the nearest surface distance; the full march starts there, skipping empty space without ever skipping a surface. Conservative and exact (box/fold fractals, un-warped domain only). Fragment renderer path; off by default.") { v in
                    cache.quality.coarsePrepassWarmStartEnabled = v; cache.push(\.coarsePrepassWarmStartEnabled, value: v)
                }
            }
        }
        .padding()
        .background(Color.cyan.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Shape tab (rail sub-tab: Bounding)

    /// Bounding Shape/Radius/Fog controls, moved out of Acceleration into their
    /// own Shape rail tab — these are shape/framing choices, not perf knobs.
    var fractalBoundingContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "circle.dashed").foregroundStyle(.cyan)
                Text("Bounding").font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { cache.quality.boundingSphereSkipEnabled },
                    set: { v in
                        cache.quality.boundingSphereSkipEnabled = v; cache.push(\.boundingSphereSkipEnabled, value: v)
                    }
                ))
                .labelsHidden()
                .help("Bounds the visible fractal to the shape below: rays that miss it skip the march entirely. Large sizes just cull background; tight sizes deliberately clip the fractal to the shape (nice for Mixed immersion).")
            }

            let selectedBoundingFamily = SafetyBubbleShapePreset.family(for: cache.quality.boundingShapeType)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Bounding Shape"); Spacer()
                    Picker("Bounding Shape", selection: Binding<SafetyBubbleShapeFamily>(
                        get: { selectedBoundingFamily },
                        set: { family in
                            let newValue = SafetyBubbleShapePreset.storedValue(for: family, currentValue: cache.quality.boundingShapeType)
                            cache.quality.boundingShapeType = newValue
                            cache.push(\.boundingShapeType, value: newValue)
                        }
                    )) {
                        ForEach(SafetyBubbleShapeFamily.allCases) { family in
                            Text(family.rawValue).tag(family)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }
                if selectedBoundingFamily == .platonic {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                        ForEach(SafetyBubbleShapePreset.platonicOptions) { preset in
                            let isSelected = SafetyBubbleShapePreset(storedValue: cache.quality.boundingShapeType) == preset

                            Button {
                                cache.quality.boundingShapeType = preset.storedValue
                                cache.push(\.boundingShapeType, value: preset.storedValue)
                            } label: {
                                Text(preset.displayName)
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(isSelected ? Color.black : Color.primary)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(isSelected ? Color.white.opacity(0.88) : Color.white.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.white.opacity(isSelected ? 0.14 : 0.08), lineWidth: 1)
                            )
                        }
                    }
                }
            }
            .disabled(!cache.quality.boundingSphereSkipEnabled)
            .opacity(cache.quality.boundingSphereSkipEnabled ? 1 : 0.45)

            accelSliderCompact("Bounding Size",
                        value: cache.quality.boundingShapeRadius, range: 0.05...30,
                        display: String(format: "%.1f", cache.quality.boundingShapeRadius),
                        help: "Size of the bounding shape in model units. Only active while Bounding is on.") { v in
                cache.quality.boundingShapeRadius = v; cache.push(\.boundingShapeRadius, value: v)
            }
            .disabled(!cache.quality.boundingSphereSkipEnabled)
            .opacity(cache.quality.boundingSphereSkipEnabled ? 1 : 0.45)

            VStack(alignment: .leading, spacing: 6) {
                Text("Bounding Fog").font(.caption)
                Picker("Bounding Fog", selection: Binding(
                    get: { BoundingFogMode(rawValue: cache.quality.boundingShapeFogMode) ?? .off },
                    set: { mode in
                        cache.quality.boundingShapeFogMode = mode.rawValue
                        cache.push(\.boundingShapeFogMode, value: mode.rawValue)
                    }
                )) {
                    ForEach(BoundingFogMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(BoundingFogMode(rawValue: cache.quality.boundingShapeFogMode)?.help ?? BoundingFogMode.off.help)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!cache.quality.boundingSphereSkipEnabled)
            .opacity(cache.quality.boundingSphereSkipEnabled ? 1 : 0.45)

            if cache.quality.boundingShapeFogMode == BoundingFogMode.innerShadow.rawValue {
                accelSliderCompact("Shadow Depth",
                            value: cache.quality.boundingShapeShadowDepth, range: 0.02...0.95,
                            display: "\(Int((cache.quality.boundingShapeShadowDepth * 100).rounded()))%",
                            help: "How far the darkening reaches in from the bounding shape's edge, as a fraction of its radius.") { v in
                    cache.quality.boundingShapeShadowDepth = v; cache.push(\.boundingShapeShadowDepth, value: v)
                }
                .disabled(!cache.quality.boundingSphereSkipEnabled)
                .opacity(cache.quality.boundingSphereSkipEnabled ? 1 : 0.45)
            }
        }
        .padding()
        .background(Color.cyan.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Developer "Force Recompile" card for the Performance tab. Clears the
    /// renderer's specialized pipeline cache (rebuilds lazily on the next frames)
    /// and recompiles the active custom `.threshfx` formula from source.
    private var shaderRecompileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: AppIcons.wrenchAndScrewdriver).foregroundStyle(.cyan)
                Text("Shaders").font(.headline)
            }
            Button {
                isRecompilingShaders = true; shaderRecompileStatus = nil
                Task {
                    let result = await appModel.forceShaderRecompile()
                    await MainActor.run { shaderRecompileStatus = result; isRecompilingShaders = false }
                }
            } label: {
                HStack {
                    if isRecompilingShaders {
                        ProgressView().scaleEffect(0.7).frame(width: 16, height: 16)
                    } else {
                        Image(systemName: AppIcons.arrowTriangle2Circlepath)
                    }
                    Text(isRecompilingShaders ? "Recompiling..." : "Force Recompile")
                }
            }
            .buttonStyle(.borderedProminent).tint(.cyan).disabled(isRecompilingShaders)

            if let status = shaderRecompileStatus {
                Text(status).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Clears the specialized pipeline cache (rebuilds on the next frames) and recompiles the active custom .threshfx formula from source. Built-in fractals have no runtime source, so for them this only rebuilds pipeline states.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(Color.cyan.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Performance tab (rail sub-tabs: Budget / Acceleration — Acceleration
    // also hosts the live metrics readout and the render-quality controls)

    /// Dispatches the Performance tab's content based on the selected rail
    /// sub-section, so each panel is short instead of one long dense scroll.
    @ViewBuilder
    var performanceTabContent: some View {
        switch performanceRailSection {
        case .acceleration: performanceAccelerationContent
        case .budget:       performanceBudgetContent
        }
    }

    /// Shared header for the Performance sub-tabs. Keeps the live FPS pill visible
    /// on every sub-tab so the headline metric is always one glance away.
    private func performanceSectionHeader(_ title: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage).font(.headline)
            Spacer()
            FPSIndicatorView()
        }
    }

    private var performanceAccelerationContent: some View {
        VStack(spacing: 12) {
            performanceSectionHeader("Acceleration", systemImage: AppIcons.boltFill)

            // ── Live metrics (merged in from the former Metrics sub-tab) ──
            PerformanceMetricsView(cache: cache)

            // ── Renderer Mode ──
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Renderer Mode")
                    Spacer()
                    Text(RendererModeOption.from(tileSize: cache.quality.tileSize).rawValue)
                        .fontWeight(.bold)
                }

                Picker("Renderer Mode", selection: Binding(
                    get: { RendererModeOption.from(tileSize: cache.quality.tileSize) },
                    set: { newMode in
                        guard cache.quality.tileSize != newMode.tileSize else { return }
                        cache.quality.tileSize = newMode.tileSize
                        cache.push(\.tileSize, value: newMode.tileSize)

                        // Default to full detail budget when switching render modes.
                        cache.quality.resolutionScale = 1.0
                        cache.push(\.resolutionScale, value: 1.0)
                        appModel.preparePipeline(
                            iterations: cache.quality.baseFractalIterations,
                            raySteps: cache.quality.baseMaxRaySteps
                        )
                    }
                )) {
                    ForEach(RendererModeOption.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(RendererModeOption.from(tileSize: cache.quality.tileSize).helperText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // ── Render Quality (resolution / framerate headroom) ──
            performanceQualityControls

            // (Render Distance slider removed 2026-07-01: measured to have almost
            // no perf effect — the multiplier is hardcoded to 1× in the renderers.)

            // ── Acceleration (the gamut of march speedup techniques) ──
            fractalAccelerationSection
        }
    }

    /// Render-quality controls — the quality slider plus the auto-adjust-to-hold-FPS
    /// toggle. Lives in the Acceleration sub-tab (these are framerate-headroom levers,
    /// not detail-budget choices). Per-platform: Mac/iOS = MetalFX detail budget,
    /// visionOS = the compositor's native Render Quality.
    @ViewBuilder
    private var performanceQualityControls: some View {
        // ── Detail/Framerate Budget ──
        // visionOS uses the compositor's Render Quality (below) for resolution;
        // the MetalFX-driven detail budget only applies on Mac/iOS.
        #if os(macOS) || os(iOS)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(effectiveDirectBudgetLabel)
                Spacer()
                Text("\(Int(cache.quality.resolutionScale * 100))%")
                    .fontWeight(.bold)
                    .monospacedDigit()
            }

            if qualityGoalPreference != .advanced {
                HStack(spacing: 8) {
                    // Shared labels (must match Iteration Budget wording): Low / Medium / High / Full.
                    // Dashed screen outline + inner grid conveys pixel density; increasing detail
                    // left-to-right. Low is 0.34 (not 0.33) so it stays under MetalFX temporal's 3× cap.
                    let presets: [(label: String, scale: Float, icon: String)] = [
                        ("Low", 0.34, "circle.grid.2x2"),
                        ("Medium", 0.50, "circle.grid.3x3"),
                        ("High", 0.75, "circle.grid.3x3.fill"),
                        ("Full", 1.0, "circle.grid.3x3.circle.fill")
                    ]

                    ForEach(presets, id: \.label) { preset in
                        Button {
                            cache.quality.resolutionScale = preset.scale
                            cache.push(\.resolutionScale, value: preset.scale)
                        } label: {
                            VStack(spacing: 2) {
                                ZStack {
                                    Image(systemName: AppIcons.rectangleDashed)
                                        .font(.caption)
                                    Image(systemName: preset.icon)
                                        .font(.caption2)
                                }
                                Text(preset.label).font(.caption2)
                                Text("\(Int(preset.scale * 100))%").font(.caption.monospacedDigit())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .tint(abs(cache.quality.resolutionScale - preset.scale) < 0.01 ? .blue : .secondary)
                        .disabled(cache.quality.tileSize == 8)
                    }
                }
            }

            if qualityGoalPreference == .advanced {
                Slider(value: Binding(
                    get: { cache.quality.resolutionScale },
                    set: { newValue in
                        let snapped = (newValue * 100).rounded() / 100
                        cache.quality.resolutionScale = snapped
                        cache.push(\.resolutionScale, value: snapped)
                    }
                ), in: ControlCatalog.resolutionScale.range, step: 0.01)
                .disabled(cache.quality.tileSize == 8)
            }

            if cache.quality.tileSize == 8 {
                Text(effectiveDirectBudgetUnavailableText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("MetalFX uses temporal upscaling when available. 50% to 75% is the usual quality/performance sweet spot.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        #endif

        #if os(visionOS)
        // ── Render Quality (Vision Pro compositor native resolution) ──
        VStack(alignment: .leading, spacing: 8) {
            Text("Priority")

            // Custom layout instead of Slider's built-in min/max value labels:
            // `.lineLimit(1).fixedSize()` guarantees the end labels render at their
            // full intrinsic width with no wrap or truncation — so longer localized
            // words ("Lisse"/"Net", "なめらか"/"くっきり", …) always show in full — and the
            // slider bar takes whatever space is left between them.
            HStack(spacing: 10) {
                Text("Smooth")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Slider(value: Binding(
                    get: { cache.quality.renderQuality },
                    set: { newValue in
                        let snapped = (newValue * 20).rounded() / 20   // 5% steps
                        cache.quality.renderQuality = snapped
                        cache.push(\.renderQuality, value: snapped)
                    }
                ), in: QualityConfig.visionMinRenderQuality...QualityConfig.visionMaxRenderQuality, step: 0.05)
                .accessibilityLabel(Text("Priority"))
                Text("Sharp")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }

            Toggle("Auto-adjust to hold FPS", isOn: Binding(
                get: { cache.quality.adaptiveRenderQualityEnabled },
                set: { v in
                    cache.quality.adaptiveRenderQualityEnabled = v
                    cache.push(\.adaptiveRenderQualityEnabled, value: v)
                }
            ))
            .tint(.cyan)
            .help("When the frame rate sags, the compositor's render quality steps down to recover headroom, then climbs back toward your slider setting (the ceiling) once FPS is comfortable. Adjustments are infrequent and the compositor tweens between them, so the change reads as a gentle ramp.")

            Text("Vision Pro: the compositor's native, gaze-foveated resolution. The slider sets the sharpest quality (the ceiling, a memory/quality balance); lower trades crispness for GPU headroom with a smoothed transition. Very low values probe max framerate.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        #endif
    }

    private var performanceBudgetContent: some View {
        VStack(spacing: 12) {
            performanceSectionHeader("Budget", systemImage: "slider.horizontal.3")

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Target Condition")
                    Spacer()
                    Picker("Budget Goal", selection: Binding(
                        get: { qualityGoalPreference },
                        set: { newValue in
                            qualityGoalPreferenceRaw = newValue.rawValue
                        }
                    )) {
                        ForEach(QualityGoalPreference.allCases, id: \.rawValue) { goal in
                            Text(goal.displayName).tag(goal)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 340)
                }
                Text("Simplified uses curated presets. Advanced unlocks free-form sliders for fine-tuning.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("Iteration Budget")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            if qualityGoalPreference != .advanced {
                HStack(spacing: 8) {
                    ForEach(QualityPreset.allCases, id: \.rawValue) { preset in
                        Button {
                            let values = preset.values(for: cache.fractalType)
                            cache.quality.baseFractalIterations = values.fractalIterations
                            cache.quality.baseMaxRaySteps = values.raySteps
                            cache.push(\.baseFractalIterations, value: values.fractalIterations)
                            cache.push(\.baseMaxRaySteps, value: values.raySteps)
                            appModel.animationManager?.markIterationBudgetUserOverridden()
                            appModel.preparePipeline(iterations: values.fractalIterations, raySteps: values.raySteps)
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: preset.icon).font(.caption)
                                Text(preset.displayName).font(.caption2)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .tint(QualityPreset.detect(
                            fractalIterations: cache.quality.baseFractalIterations,
                            raySteps: cache.quality.baseMaxRaySteps,
                            fractalType: cache.fractalType
                        ) == preset ? .blue : .secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Fractal Iterations"); Spacer(); Text("\(cache.quality.baseFractalIterations)").fontWeight(.bold).monospacedDigit() }
                        Slider(value: Binding(
                            get: { Float(cache.quality.baseFractalIterations) },
                            set: {
                                cache.quality.baseFractalIterations = Int($0)
                                cache.push(\.baseFractalIterations, value: Int($0))
                                appModel.animationManager?.markIterationBudgetUserOverridden()
                            }
                        ), in: 4...32, step: 1, onEditingChanged: { isEditing in
                            guard !isEditing else { return }
                            appModel.preparePipeline(
                                iterations: cache.quality.baseFractalIterations,
                                raySteps: cache.quality.baseMaxRaySteps
                            )
                        })
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Max Ray Steps"); Spacer(); Text("\(cache.quality.baseMaxRaySteps)").fontWeight(.bold).monospacedDigit() }
                        Slider(value: Binding(
                            get: { Float(cache.quality.baseMaxRaySteps) },
                            set: {
                                cache.quality.baseMaxRaySteps = Int($0)
                                cache.push(\.baseMaxRaySteps, value: Int($0))
                                appModel.animationManager?.markIterationBudgetUserOverridden()
                            }
                        ), in: 32...200, step: 8, onEditingChanged: { isEditing in
                            guard !isEditing else { return }
                            appModel.preparePipeline(
                                iterations: cache.quality.baseFractalIterations,
                                raySteps: cache.quality.baseMaxRaySteps
                            )
                        })
                    }
                }
            }

            // ── Force Recompile (developer/debug) ──
            shaderRecompileSection
        }
    }
    
    private func setDetailScale(_ value: Float) {
        let clamped = max(0.05, min(20.0, value))
        appModel.renderSettings.detailScale = clamped
        appModel.renderSettings.targetDetailScale = clamped
        cache.liveDetailScale = clamped
    }

    private func setDetailRotationEuler(_ eulerDegrees: SIMD3<Float>) {
        let q = quaternionFromEulerDegrees(eulerDegrees)
        appModel.renderSettings.worldRotation = q
        appModel.renderSettings.targetWorldRotation = q
        cache.liveWorldRotation = q
    }
    
    /// Extract Euler angles (degrees) from a quaternion for display.
    private func eulerAngles(from q: simd_quatf) -> SIMD3<Float> {
        let sinP = 2.0 * (q.real * q.imag.y - q.imag.z * q.imag.x)
        let pitch: Float
        if abs(sinP) >= 1 {
            pitch = copysign(.pi / 2, sinP)
        } else {
            pitch = asin(sinP)
        }
        let sinYCosP = 2.0 * (q.real * q.imag.z + q.imag.x * q.imag.y)
        let cosYCosP = 1.0 - 2.0 * (q.imag.y * q.imag.y + q.imag.z * q.imag.z)
        let yaw = atan2(sinYCosP, cosYCosP)
        let sinRCosP = 2.0 * (q.real * q.imag.x + q.imag.y * q.imag.z)
        let cosRCosP = 1.0 - 2.0 * (q.imag.x * q.imag.x + q.imag.y * q.imag.y)
        let roll = atan2(sinRCosP, cosRCosP)
        let toDeg: Float = 180.0 / .pi
        return SIMD3<Float>(pitch * toDeg, yaw * toDeg, roll * toDeg)
    }

    /// Build quaternion from Euler angles in degrees using the same convention
    /// as eulerAngles(from:): x=pitch(Y-axis), y=yaw(Z-axis), z=roll(X-axis).
    private func quaternionFromEulerDegrees(_ euler: SIMD3<Float>) -> simd_quatf {
        let toRad: Float = .pi / 180.0
        let pitchY = euler.x * toRad
        let yawZ = euler.y * toRad
        let rollX = euler.z * toRad

        let qx = simd_quatf(angle: rollX, axis: SIMD3<Float>(1, 0, 0))
        let qy = simd_quatf(angle: pitchY, axis: SIMD3<Float>(0, 1, 0))
        let qz = simd_quatf(angle: yawZ, axis: SIMD3<Float>(0, 0, 1))

        return (qz * qy * qx).normalized
    }
}
