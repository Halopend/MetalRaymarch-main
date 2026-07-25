//
//  ContentView+FractalTab.swift
//  Threshold
//
//  Fractal tab UI extracted from ContentView.swift (Phase C refactor).
//  Stored properties and computed helpers remain on the main `ContentView` struct.
//

import SwiftUI
import simd

private struct TransformationGroupBudget: Identifiable {
    let id: UUID
    let steps: Int
    let passes: Int
    let isMandelboxRecurrence: Bool

    var workPerSample: Int { steps * passes }
}

extension ContentView {
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Fractal Tab
    // ═══════════════════════════════════════════════════════════════════════════
    
    var fractalTabContent: some View {
        VStack(spacing: 0) {
            switch currentRoute {
            case .explore:
                FractalGridView(
                    animationManager: appModel.animationManager,
                    presetManager: appModel.presetManager,
                    tabSelection: fractalBrowseTabBinding,
                    onCreateAnimation: { openAnimationEditor() },
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

            case .shape(.parameters), .shape(.formula), .shape(.primitives), .shape(.hands):
                ScrollView(.vertical, showsIndicators: true) {
                    Group {
                        switch currentRoute {
                        case .shape(.parameters):
                            fractalShapeContent
                        case .shape(.formula):
                            fractalFormulaContent
                        case .shape(.primitives):
                            PrimitivesSection(cache: cache)
                        case .shape(.hands):
                            fractalHandsContent
                        default:
                            EmptyView()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

            case .shape(.space):
                ScrollView(.vertical, showsIndicators: true) {
                    fractalSpaceContent
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }

            case .shape(.transformations):
                ScrollView(.vertical, showsIndicators: true) {
                    fractalTransformContent
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }

            case .shape(.bounding):
                ScrollView(.vertical, showsIndicators: true) {
                    fractalBoundingContent
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }

            case .quality, .shape(.performance):
                ScrollView(.vertical, showsIndicators: true) {
                    performanceTabContent
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            default:
                EmptyView()
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
                    value: cacheBinding(\.fractalScale), range: ControlCatalog.fractalScale.range,
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

            FractalFormulaGrid(cache: cache, presetManager: appModel.presetManager)
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
                    Toggle("", isOn: cacheBinding(\.handAttraction.enabled))
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
                        value: cacheBinding(\.handAttraction.radius),
                        range: ControlCatalog.handAttractionRadius.range,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.handAttractionRadius, value: cache.handAttraction.radius) },
                        showToggle: false)

                    EffectSliderRow(icon: "arrow.left.and.right", label: "Repel \u{2190}\u{2192} Attract",
                        value: cacheBinding(\.handAttraction.strength),
                        range: ControlCatalog.handAttractionStrength.range,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.handAttractionStrength, value: cache.handAttraction.strength) },
                        showToggle: false,
                        valueFormat: { v in
                            if abs(v) < 0.02 { return "Off" }
                            return v < 0 ? String(format: "Repel %.0f%%", -v * 100) : String(format: "Attract %.0f%%", v * 100)
                        })

                    EffectSliderRow(icon: "circle.fill", label: "Ball Size",
                        value: cacheBinding(\.handAttraction.ballScale),
                        range: ControlCatalog.handAttractionBallScale.range,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.handAttractionBallScale, value: cache.handAttraction.ballScale) },
                        showToggle: false,
                        valueFormat: { v in String(format: "%.0f%% of radius", v * 100) })

                    EffectSliderRow(icon: "aqi.medium", label: "Blend Softness",
                        value: cacheBinding(\.handAttraction.softness),
                        range: ControlCatalog.handAttractionSoftness.range,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.handAttractionSoftness, value: cache.handAttraction.softness) },
                        showToggle: false,
                        valueFormat: { v in String(format: "%.2f\u{00D7}", v) })

                    EffectSliderRow(icon: "arrow.up.forward", label: "Reach Offset",
                        value: cacheBinding(\.handAttraction.projectionDistance),
                        range: ControlCatalog.handAttractionProjectionDistance.range,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.handAttractionProjectionDistance, value: cache.handAttraction.projectionDistance) },
                        showToggle: false,
                        valueFormat: { v in v < 0.005 ? "At hand" : String(format: "%.0f cm ahead", v * 100) })
                    Text("Reach Offset projects the ball outward from your body through the hand, so it floats in front of the palm instead of on it.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()
                    HStack {
                        Label("Forearms", systemImage: "figure.wave")
                            .font(.subheadline)
                        Spacer()
                        Toggle("", isOn: cacheBinding(\.handAttraction.forearmEnabled))
                            .labelsHidden()
                            .onChange(of: cache.handAttraction.forearmEnabled) { _, val in
                                cache.push(\.handAttractionForearmEnabled, value: val)
                            }
                    }
                    Text("Carves empty space along each wrist\u{2192}elbow segment so your real forearm stays visible through the fractal.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if cache.handAttraction.forearmEnabled {
                        EffectSliderRow(icon: "capsule", label: "Forearm Radius",
                            value: cacheBinding(\.handAttraction.forearmRadius),
                            range: ControlCatalog.handAttractionForearmRadius.range,
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
                            Toggle("", isOn: cacheBinding(\.handAttraction.pocketEnabled))
                                .labelsHidden()
                                .onChange(of: cache.handAttraction.pocketEnabled) { _, val in
                                    cache.push(\.handAttractionPocketEnabled, value: val)
                                }
                        }
                        Text("Hollows out a small pocket right at the hand while the wider surface still pulls toward it.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if cache.handAttraction.pocketEnabled {
                            EffectSliderRow(icon: "circle.circle", label: "Pocket Size",
                                value: cacheBinding(\.handAttraction.pocketSize),
                                range: ControlCatalog.handAttractionPocketSize.range,
                                enabled: .constant(true),
                                onChanged: { cache.push(\.handAttractionPocketSize, value: cache.handAttraction.pocketSize) },
                                showToggle: false,
                                valueFormat: { v in String(format: "%.0f%% of ball", v * 100) })

                            EffectSliderRow(icon: "aqi.low", label: "Pocket Softness",
                                value: cacheBinding(\.handAttraction.pocketSoftness),
                                range: ControlCatalog.handAttractionPocketSoftness.range,
                                enabled: .constant(true),
                                onChanged: { cache.push(\.handAttractionPocketSoftness, value: cache.handAttraction.pocketSoftness) },
                                showToggle: false,
                                valueFormat: { v in String(format: "%.2f\u{00D7}", v) })
                        }
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
            TransformationsSection(renderSettings: appModel.renderSettings,
                                   cache: cache)
        }
    }

    private var fractalSpaceContent: some View {
        let rotationEuler = eulerAngles(from: cache.liveWorldRotation)

        return VStack(spacing: 12) {
            // ── Safety Bubble ────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Safety Bubble", systemImage: AppIcons.shieldLefthalfFilled)
                        .font(.headline)
                    Spacer()
                    Toggle("", isOn: cacheBinding(\.safetyBubble.enabled))
                        .labelsHidden()
                        .onChange(of: cache.safetyBubble.enabled) { _, val in
                            cache.push(\.safetyBubbleEnabled, value: val)
                        }
                }
                Text("Prevents the camera from entering fractal geometry.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if cache.safetyBubble.enabled {
                    let selectedBubbleFamily = SafetyBubbleShapePreset.family(for: cache.safetyBubble.shape)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Shape")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
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

                        if selectedBubbleFamily == .platonic {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                                ForEach(SafetyBubbleShapePreset.platonicOptions) { preset in
                                    let isSelected = SafetyBubbleShapePreset(storedValue: cache.safetyBubble.shape) == preset

                                    Button {
                                        cache.safetyBubble.shape = preset.storedValue
                                        cache.push(\.safetyBubbleShape, value: preset.storedValue)
                                    } label: {
                                        Text(preset.displayName)
                                            .font(.caption.weight(.semibold))
                                            .frame(maxWidth: .infinity, alignment: .center)
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
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.05)))

                    VStack(alignment: .leading, spacing: 8) {
                        EffectSliderRow(icon: "circle.dashed", label: "Radius",
                            value: cacheBinding(\.safetyBubble.radius),
                            range: ControlCatalog.safetyBubbleRadius.range,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.safetyBubbleRadius, value: cache.safetyBubble.radius) },
                            showToggle: false)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.05)))

#if os(visionOS)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Shrink in Mixed", systemImage: "arrow.down.right.and.arrow.up.left")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Toggle("", isOn: cacheBinding(\.safetyBubble.mixedAutoShrinkEnabled))
                                .labelsHidden()
                                .onChange(of: cache.safetyBubble.mixedAutoShrinkEnabled) { _, val in
                                    cache.push(\.safetyBubbleMixedAutoShrink, value: val)
                                }
                        }
                        Text("Caps the bubble while Mixed immersion is active, then restores the saved radius when you leave Mixed.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if cache.safetyBubble.mixedAutoShrinkEnabled {
                            EffectSliderRow(icon: "circle.dashed", label: "Mixed Radius",
                                value: cacheBinding(\.safetyBubble.mixedRadius),
                                range: ControlCatalog.safetyBubbleMixedRadius.range,
                                enabled: .constant(true),
                                onChanged: { cache.push(\.safetyBubbleMixedRadius, value: cache.safetyBubble.mixedRadius) },
                                showToggle: false,
                                valueFormat: { v in String(format: "%.2f m", v) })
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.05)))
#endif

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Blend")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("Controls how strongly the bubble masks fractal geometry. Fine control at low values.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Label("Cost varies by scene, fractal, and zoom.", systemImage: AppIcons.exclamationmarkTriangle)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        EffectSliderRow(icon: "circle.righthalf.filled", label: "Blend",
                            value: Binding<Float>(
                                get: { 1.0 - ControlStateStore.blendValueToSlider(cache.safetyBubble.strength) },
                                set: { cache.safetyBubble.strength = ControlStateStore.blendSliderToValue(1.0 - $0) }
                            ), range: ControlCatalog.safetyBubbleBlend.range,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.safetyBubbleBlend, value: cache.safetyBubble.strength) },
                            showToggle: false)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.05)))
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
                        set: { cache.setPlatformEnabled($0) }
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
                        ), range: ControlCatalog.platformRadius.range,
                        enabled: .constant(true),
                        onChanged: { cache.commitPlatformRadius() },
                        showToggle: false)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.cyan.opacity(0.07)))
#endif

            // (Spherical Inversion + Sphere Projection moved to the Transformations
            // section → fractalTransformContent, where they show as active cards and
            // are add-able alongside the warp stack.)

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

    // Spherical Inversion + Sphere Projection now render inside the Transformations
    // section (Shape → Transform) as active "SPACE" cards, add-able from its ✚ menu.
    // See `TransformationsSection.sphericalInversionCard` / `sphereProjectionCard`.
    // The `ModuleUISection.sphereProjection(cache:)` factory is retained there.

    // ── Acceleration panel: the gamut of march speedup techniques ──
    // Each control trades a little quality for frame rate in a different way.
    // Bindings write the live RenderSettings (via cache.push) and the UI cache.
    // Defaults reproduce the renderer's prior behavior, so an untouched panel is
    // a no-op.

    private func accelSliderCompact(_ title: String,
                                    value: Float,
                                    range: ClosedRange<Float>,
                                    display: String,
                                    help: String,
                                    onChange: @escaping (Float) -> Void) -> some View {
        CompactValueSlider(
            title: title,
            value: Binding(get: { value }, set: { newValue in onChange(newValue) }),
            range: range,
            display: display,
            tint: .cyan,
            helpText: help
        )
    }

    /// Compact toggle for the horizontal toggle grid. Explanation in a tooltip.
    private func accelToggleCompact(_ title: String,
                                    isOn: Bool,
                                    help: String,
                                    onChange: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { newValue in onChange(newValue) })) {
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
                CompactValueSlider(
                    title: "Over-Relaxation",
                    value: Binding(
                        get: { cache.quality.overRelaxationMax },
                        set: { cache.quality.overRelaxationMax = $0; cache.push(\.overRelaxationMax, value: $0) }
                    ),
                    range: ControlCatalog.overRelaxationMax.range,
                    display: String(format: "%.2f×", cache.quality.overRelaxationMax),
                    tint: .cyan,
                    helpText: "How big a step the march takes in open space (Keinert enhanced sphere tracing). Higher = faster; lower = sharper on thin features. 1.0 = plain conservative tracing."
                )

                CompactValueSlider(
                    title: "Cone Marching",
                    value: Binding(
                        get: { cache.quality.coneMarchStrength },
                        set: { cache.quality.coneMarchStrength = $0; cache.push(\.coneMarchStrength, value: $0) }
                    ),
                    range: ControlCatalog.coneMarchStrength.range,
                    display: cache.quality.coneMarchStrength < 0.01 ? "Off" : "\(Int((cache.quality.coneMarchStrength * 100).rounded()))%",
                    tint: .cyan,
                    helpText: "Stops each ray within its on-screen pixel footprint, so distant geometry needs far fewer steps. Higher = faster, but inflates distant silhouettes."
                )

                CompactValueSlider(
                    title: "Distance Falloff",
                    value: Binding(
                        get: { cache.quality.distanceLODStrength },
                        set: { cache.quality.distanceLODStrength = $0; cache.push(\.distanceLODStrength, value: $0) }
                    ),
                    range: ControlCatalog.distanceLODStrength.range,
                    display: cache.quality.distanceLODStrength < 0.01 ? "Off" : "\(Int((cache.quality.distanceLODStrength * 100).rounded()))%",
                    tint: .cyan,
                    helpText: "Faraway geometry uses fewer fractal iterations, where the lost detail is already sub-pixel. Speeds up deep scenes without inflating silhouettes the way cone marching does."
                )

                CompactValueSlider(
                    title: "Foveation",
                    value: Binding(
                        get: { cache.quality.foveationStrength },
                        set: { cache.quality.foveationStrength = $0; cache.push(\.foveationStrength, value: $0) }
                    ),
                    range: ControlCatalog.foveationStrength.range,
                    display: cache.quality.foveationStrength < 0.01 ? "Off" : "\(Int((cache.quality.foveationStrength * 100).rounded()))%",
                    tint: .cyan,
                    helpText: "Peripheral tiles march fewer steps, ramping from the center outward. Adaptive Compute renderer mode only."
                )
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
                            help: "Reuses compatible previous-frame depth, then validates each predicted start with the distance field before skipping ahead. Rejected or stale predictions fall back to a full march. On by default; Adaptive Compute renderer mode only.") { v in
                    cache.quality.computeTemporalReprojectionEnabled = v; cache.push(\.computeTemporalReprojectionEnabled, value: v)
                }
                .disabled(!isCompute)
                .opacity(isCompute ? 1 : 0.45)

                accelToggleCompact("Cone Warm-Start",
                            isOn: cache.quality.coarsePrepassWarmStartEnabled,
                            help: "A low-res cone pre-pass marches one cone per 8×8 block and writes a provable lower bound on the nearest surface distance; the full march starts there, skipping empty space without ever skipping a surface. Conservative and exact (box/fold fractals, un-warped domain only). Fragment renderer path; off by default.") { v in
                    cache.quality.coarsePrepassWarmStartEnabled = v; cache.push(\.coarsePrepassWarmStartEnabled, value: v)
                }

                accelToggleCompact("Cone Coverage AA",
                            isOn: cache.quality.coneCoverageAAEnabled,
                            help: "Anti-aliases silhouettes from the cone footprint so Cone Marching can run harder (fewer steps) without blobby, inflated edges. Softens outer edges only — no sub-pixel thin-feature recovery. Fragment renderer path.") { v in
                    cache.quality.coneCoverageAAEnabled = v; cache.push(\.coneCoverageAAEnabled, value: v)
                }
                .disabled(isCompute)
                .opacity(isCompute ? 0.45 : 1)
            }
        }
        .padding()
        .background(Color.cyan.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Shape tab (rail sub-tab: Bounding)

    /// Bounding Shape/Radius/Fog controls, moved out of Acceleration into their
    /// own Shape rail tab — these are shape/framing choices, not perf knobs.
    var fractalBoundingContent: some View {
        let selectedBoundingFamily = SafetyBubbleShapePreset.family(
            for: cache.quality.boundingShapeType
        )
        let selectedBoundingPreset = SafetyBubbleShapePreset(
            storedValue: cache.quality.boundingShapeType
        )

        return VStack(alignment: .leading, spacing: 10) {
            #if os(visionOS)
            // Containment — the headline mode framing, so it sits at the very top
            // of the tab. The MUTUALLY EXCLUSIVE picker sets a single canonical combo
            // (Shape / Space / Surroundings / Free); individual toggles below are
            // independent and can override it (e.g. both on) — when they do, the
            // picker shows the read-only "Custom" segment. The mode is derived
            // from the same enable flags.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "circle.dashed.inset.filled").foregroundStyle(.cyan)
                    Text("Containment").font(.headline)
                    Spacer()
                }
                Picker("Containment", selection: Binding(
                    get: { cache.mixedContainment },
                    // Tapping a canonical mode applies its exclusive combo; tapping
                    // the derived "Custom" segment is a no-op (applyMixedContainment
                    // guards it) — Custom is only reached via the side toggles.
                    set: { cache.applyMixedContainment($0) }
                )) {
                    ForEach(MixedContainment.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(cache.mixedContainment.help)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.vertical, 2)

            // Scrunch to Surroundings — the most-reached-for mode in Mixed immersion.
            scrunchToSurroundingsSection

            Divider().padding(.vertical, 2)
            #endif

            // On Vision Pro this follows the sensed current room. Authored
            // dimensions remain the cross-platform and incomplete-scan fallback.
            HStack(spacing: 6) {
                Image(systemName: "house").foregroundStyle(.cyan)
                Text("Bound to Space").font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { cache.quality.boundToSpaceEnabled },
                    set: { cache.setBoundToSpaceEnabled($0) }
                ))
                .labelsHidden()
                .help("Clips the fractal to the sensed rectangular room on Vision Pro, with the authored dimensions below as a fallback.")
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker("Faces", selection: Binding(
                    get: { BoundToSpaceMode(rawValue: cache.quality.boundToSpaceMode) ?? .matchSpace },
                    set: { mode in
                        cache.quality.boundToSpaceMode = mode.rawValue
                        cache.push(\.boundToSpaceMode, value: mode.rawValue)
                    }
                )) {
                    ForEach(BoundToSpaceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(BoundToSpaceMode(rawValue: cache.quality.boundToSpaceMode)?.help ?? BoundToSpaceMode.matchSpace.help)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                #if os(visionOS)
                Text("Room Tracking automatically follows the current room's center, wall angle, footprint, floor, and ceiling. Fallback dimensions are used until the room scan is complete.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                #endif

                accelSliderCompact("Fallback Width",
                            value: cache.quality.boundSpaceWidth,
                            range: ControlCatalog.boundSpaceWidth.range,
                            display: String(format: "%.1f m", cache.quality.boundSpaceWidth),
                            help: "Fallback width used until a complete room scan is available.") { value in
                    cache.quality.boundSpaceWidth = value
                    cache.push(\.boundSpaceWidth, value: value)
                }
                accelSliderCompact("Fallback Depth",
                            value: cache.quality.boundSpaceDepth,
                            range: ControlCatalog.boundSpaceDepth.range,
                            display: String(format: "%.1f m", cache.quality.boundSpaceDepth),
                            help: "Fallback depth used until a complete room scan is available.") { value in
                    cache.quality.boundSpaceDepth = value
                    cache.push(\.boundSpaceDepth, value: value)
                }
                accelSliderCompact("Fallback Height",
                            value: cache.quality.boundSpaceHeight,
                            range: ControlCatalog.boundSpaceHeight.range,
                            display: String(format: "%.1f m", cache.quality.boundSpaceHeight),
                            help: "Fallback height used until a complete room scan is available.") { value in
                    cache.quality.boundSpaceHeight = value
                    cache.push(\.boundSpaceHeight, value: value)
                }
                accelSliderCompact("Space Ambient",
                            value: cache.quality.boundAmbientStrength,
                            range: ControlCatalog.boundAmbientStrength.range,
                            display: String(format: "%.0f%%", cache.quality.boundAmbientStrength * 100),
                            help: "Contact shadow contributed by the room boundary. 0% disables it.") { value in
                    cache.quality.boundAmbientStrength = value
                    cache.push(\.boundAmbientStrength, value: value)
                }
            }
            .disabled(!cache.quality.boundToSpaceEnabled)
            .opacity(cache.quality.boundToSpaceEnabled ? 1 : 0.45)

            Divider().padding(.vertical, 2)

            HStack(spacing: 6) {
                Image(systemName: "circle.dashed").foregroundStyle(.cyan)
                Text("Shape").font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { cache.quality.boundingSphereSkipEnabled },
                    // Independent toggle — does not turn another containment
                    // system off. A manual combination appears as Custom.
                    set: { v in cache.setBoundingShapeEnabled(v) }
                ))
                .labelsHidden()
                .help("Bounds the visible fractal to the shape below: rays that miss it skip the march entirely. Large sizes just cull background; tight sizes deliberately clip the fractal to the shape. Independent of Bound to Space and Surroundings Containment; combinations appear as Custom.")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Boundary Shape")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("Boundary Shape", selection: Binding<SafetyBubbleShapeFamily>(
                    get: { selectedBoundingFamily },
                    set: { family in
                        let newValue = SafetyBubbleShapePreset.storedValue(
                            for: family,
                            currentValue: cache.quality.boundingShapeType
                        )
                        cache.quality.boundingShapeType = newValue
                        cache.push(\.boundingShapeType, value: newValue)
                    }
                )) {
                    ForEach(SafetyBubbleShapeFamily.allCases) { family in
                        Text(family.rawValue).tag(family)
                    }
                }
                .pickerStyle(.segmented)

                if selectedBoundingFamily == .platonic {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 120), spacing: 8)],
                        spacing: 8
                    ) {
                        ForEach(SafetyBubbleShapePreset.platonicOptions) { preset in
                            let isSelected = selectedBoundingPreset == preset
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

                Text("The selected signed-distance shape defines both ray culling and the final clipping silhouette.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!cache.quality.boundingSphereSkipEnabled)
            .opacity(cache.quality.boundingSphereSkipEnabled ? 1 : 0.45)

            accelSliderCompact("Shape Size",
                        value: cache.quality.boundingShapeRadius,
                        range: ControlCatalog.boundingShapeRadius.range,
                        display: String(format: "%.1f", cache.quality.boundingShapeRadius),
                        help: "Radius/half-size of the selected boundary in model units. Only active while Shape is on.") { v in
                cache.quality.boundingShapeRadius = v; cache.push(\.boundingShapeRadius, value: v)
            }
            .disabled(!cache.quality.boundingSphereSkipEnabled)
            .opacity(cache.quality.boundingSphereSkipEnabled ? 1 : 0.45)

            VStack(alignment: .leading, spacing: 6) {
                Text("Fade Effect").font(.caption)
                Picker("Fade Effect", selection: Binding(
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
            .disabled(!boundingEdgeTreatmentActive)
            .opacity(boundingEdgeTreatmentActive ? 1 : 0.45)

            if cache.quality.boundingShapeFogMode == BoundingFogMode.innerShadow.rawValue {
                accelSliderCompact("Shadow Depth",
                            value: cache.quality.boundingShapeShadowDepth,
                            range: ControlCatalog.boundingShapeShadowDepth.range,
                            display: "\(Int((cache.quality.boundingShapeShadowDepth * 100).rounded()))%",
                            help: "How far the darkening reaches in from the bounding shape's edge, as a fraction of its radius.") { v in
                    cache.quality.boundingShapeShadowDepth = v; cache.push(\.boundingShapeShadowDepth, value: v)
                }
                .disabled(!boundingEdgeTreatmentActive)
                .opacity(boundingEdgeTreatmentActive ? 1 : 0.45)
            }
        }
        .padding()
        .background(Color.cyan.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    #if os(visionOS)
    /// "Surroundings Containment" (Environment Scrunch): the scanned surroundings
    /// (scene reconstruction on visionOS) become a distance field the fractal
    /// scrunches and bulges around — a proximity field like the hands, not a
    /// see-through cut. Surfaced at the top of the Bounding tab.
    @ViewBuilder
    private var scrunchToSurroundingsSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.3.layers.3d").foregroundStyle(.cyan)
            Text("Surroundings Containment").font(.headline)
            Spacer()
            Toggle("", isOn: Binding(
                get: { cache.quality.envScrunchEnabled },
                // Independent toggle — does NOT turn the Bounding shape off. With
                // Bounding also on, the Containment picker shows Custom. Turning
                // Scrunch on defaults Contain to Blend when it was still Off.
                set: { v in cache.setScrunchEnabled(v) }
            ))
            .labelsHidden()
            .help("Scrunches the fractal around your scanned surroundings: it bulges toward nearby real surfaces while keeping a small clearance at the surface itself. Uses the headset's room scan. Independent of the Bounding shape — turning both on is the Custom containment mode. Turning this on defaults Contain to Blend.")
        }

        VStack(alignment: .leading, spacing: 6) {
            Picker("Mode", selection: Binding(
                get: { cache.quality.envScrunchMode },
                set: { v in
                    cache.quality.envScrunchMode = v; cache.push(\.envScrunchMode, value: v)
                    if v == 1 {
                        cache.quality.envScrunchContain = 1; cache.push(\.envScrunchContain, value: 1)
                    }
            }
        )) {
            Text("Scrunch").tag(0)
            Text("Shell").tag(1)
        }
        .pickerStyle(.segmented)
            .help("Scrunch: the fractal bulges around nearby real surfaces. Shell: the fractal only renders within Reach of walls and objects, coating the room instead of filling open space.")
            accelSliderCompact("Strength",
                        value: cache.quality.envScrunchStrength,
                        range: ControlCatalog.surroundingsStrength.range,
                        display: "\(Int((cache.quality.envScrunchStrength * 100).rounded()))%",
                        help: "How strongly the fractal deforms toward the scrunched shape. Low values bump gently; 100% fully conforms within the reach band.") { v in
                cache.quality.envScrunchStrength = v; cache.push(\.envScrunchStrength, value: v)
            }
            accelSliderCompact("Reach",
                        value: cache.quality.envScrunchReach,
                        range: ControlCatalog.surroundingsReach.range,
                        display: String(format: "%.1f m", cache.quality.envScrunchReach),
                        help: "Scrunch: how far from a real surface the pull engages. Shell: the thickness of the rendered layer around walls and objects.") { v in
                cache.quality.envScrunchReach = v; cache.push(\.envScrunchReach, value: v)
            }
            Picker("Contain", selection: Binding(
                get: { cache.quality.envScrunchContain },
                set: { v in
                    cache.quality.envScrunchContain = v; cache.push(\.envScrunchContain, value: v)
                }
            )) {
                Text("Off").tag(0)
                Text("Hard").tag(1)
                Text("Blend").tag(2)
            }
            .pickerStyle(.segmented)
            .help("Keeps the fractal stuck to your scanned room. The room scan is an unsigned distance field, so on its own the scrunch mirrors an outside shell / doubling beyond real walls — Contain clips the fractal to the scanned room box to cut that. Hard: a crisp boundary. Blend: a soft feathered edge (width below). Works with Strength 0 too, for pure auto-containment.")
            if cache.quality.envScrunchContain == 2 {
                accelSliderCompact("Blend Width",
                            value: cache.quality.envScrunchContainFeather,
                            range: ControlCatalog.surroundingsBlendWidth.range,
                            display: String(format: "%.2f m", cache.quality.envScrunchContainFeather),
                            help: "How gradually the fractal fades out as it crosses the scanned room boundary.") { v in
                    cache.quality.envScrunchContainFeather = v; cache.push(\.envScrunchContainFeather, value: v)
                }
            }
        }
        .disabled(!cache.quality.envScrunchEnabled)
        .opacity(cache.quality.envScrunchEnabled ? 1 : 0.45)
    }
    #endif

    /// The edge treatment applies to both authored space and shape bounds.
    private var boundingEdgeTreatmentActive: Bool {
        cache.quality.boundingSphereSkipEnabled || cache.quality.boundToSpaceEnabled
    }

    // MARK: - Performance tab (rail sub-tabs: Overview / Tuning — Overview hosts the
    // live metrics readout with Force Recompile embedded; Tuning holds every knob)

    /// Dispatches the Performance tab's content based on the selected rail
    /// sub-section, so each panel is short instead of one long dense scroll.
    @ViewBuilder
    var performanceTabContent: some View {
        switch performanceRailSection {
        case .overview: performanceOverviewContent
        case .tuning:   performanceTuningContent
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

    /// Standard Performance-tab card chrome — matches the Acceleration section so
    /// every Tuning group reads as the same kind of panel.
    @ViewBuilder
    private func perfCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.cyan.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Overview — the live performance dashboard (Force Recompile is embedded in the
    /// card). Read-only readouts and a one-shot rebuild; every tunable knob lives in
    /// the Tuning sub-tab.
    private var performanceOverviewContent: some View {
        VStack(spacing: 12) {
            performanceSectionHeader("Overview", systemImage: "gauge")

            PerformanceMetricsView(cache: cache)
        }
    }

    /// Tuning — every performance knob in one place: the iteration/ray-step budget,
    /// renderer mode, render quality, and the march-acceleration techniques. (The
    /// live readout and Force Recompile moved to the Overview sub-tab.)
    private var performanceTuningContent: some View {
        VStack(spacing: 12) {
            performanceSectionHeader("Tuning", systemImage: "slider.horizontal.3")

            // ── Budget card: iteration budget + detail budget, with the
            //    Simplified/Advanced goal picker in the header. ──
            perfCard {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.fill").foregroundStyle(.cyan)
                    Text("Budget").font(.headline)
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
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }

                // Formula and raymarch budgets. Transform-group passes are surfaced
                // alongside them because they also run inside every distance sample.
                Text("Raymarch & Formula Budget")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if cache.fractalType == .constructionPrimitive {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Label("Analytic Base Shape", systemImage: "function")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text("1 EVALUATION")
                                .font(.caption2.monospacedDigit().weight(.bold))
                                .foregroundStyle(.green)
                        }
                        Text("Formula Iterations do not apply to construction primitives. Group Passes control the repeated geometry; Max Ray Steps controls raymarch quality.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                transformationGroupBudgetSummary

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
                    if cache.fractalType == .constructionPrimitive {
                        Text("For this analytic base, presets use their ray-step budget; their formula-iteration value is ignored.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    VStack(spacing: 12) {
                        if cache.fractalType != .constructionPrimitive {
                            CompactValueSlider(
                                title: "Formula Iterations",
                                value: Binding(
                                    get: { Float(cache.quality.baseFractalIterations) },
                                    set: {
                                        cache.quality.baseFractalIterations = Int($0)
                                        cache.push(\.baseFractalIterations, value: Int($0))
                                        appModel.animationManager?.markIterationBudgetUserOverridden()
                                    }
                                ),
                                range: ControlCatalog.iterations.range,
                                step: 1,
                                display: "\(cache.quality.baseFractalIterations)",
                                tint: .cyan,
                                onEditingChanged: { isEditing in
                                    guard !isEditing else { return }
                                    appModel.preparePipeline(
                                        iterations: cache.quality.baseFractalIterations,
                                        raySteps: cache.quality.baseMaxRaySteps
                                    )
                                }
                            )
                        }

                        CompactValueSlider(
                            title: "Max Ray Steps",
                            value: Binding(
                                get: { Float(cache.quality.baseMaxRaySteps) },
                                set: {
                                    cache.quality.baseMaxRaySteps = Int($0)
                                    cache.push(\.baseMaxRaySteps, value: Int($0))
                                    appModel.animationManager?.markIterationBudgetUserOverridden()
                                }
                            ),
                            range: ControlCatalog.maxRaySteps.range,
                            step: 8,
                            display: "\(cache.quality.baseMaxRaySteps)",
                            tint: .cyan,
                            onEditingChanged: { isEditing in
                                guard !isEditing else { return }
                                appModel.preparePipeline(
                                    iterations: cache.quality.baseFractalIterations,
                                    raySteps: cache.quality.baseMaxRaySteps
                                )
                            }
                        )
                    }
                }

                Divider().padding(.vertical, 2)

                // Detail budget (Mac/iOS resolution scale) / Priority (visionOS).
                performanceQualityControls
            }

            // ── Renderer Mode card ──
            perfCard {
                HStack(spacing: 6) {
                    Image(systemName: "cpu").foregroundStyle(.cyan)
                    Text("Renderer Mode").font(.headline)
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
                .labelsHidden()

                Text(RendererModeOption.from(tileSize: cache.quality.tileSize).helperText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // ── Acceleration card (already carries its own card chrome) ──
            fractalAccelerationSection
        }
    }

    private var transformationGroupBudgets: [TransformationGroupBudget] {
        let stack = appModel.renderSettings.spaceWarpStack
        var result: [TransformationGroupBudget] = []
        var index = 0
        while index < stack.count {
            guard let groupID = stack[index].groupID else {
                index += 1
                continue
            }
            var end = index + 1
            while end < stack.count && stack[end].groupID == groupID { end += 1 }
            let enabledSteps = stack[index..<end].filter(\.isEnabled).count
            if enabledSteps > 0 {
                result.append(TransformationGroupBudget(
                    id: groupID,
                    steps: enabledSteps,
                    passes: stack[index].effectiveGroupIterations,
                    isMandelboxRecurrence:
                        stack[index].effectiveGroupMode == .mandelboxRecurrence
                ))
            }
            index = end
        }
        return result
    }

    @ViewBuilder
    private var transformationGroupBudgetSummary: some View {
        let groups = transformationGroupBudgets
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Label("Transform Group Work", systemImage: "repeat")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.indigo)
                ForEach(Array(groups.enumerated()), id: \.element.id) { offset, group in
                    HStack(spacing: 6) {
                        Text(groups.count == 1 ? "Group" : "Group \(offset + 1)")
                        if group.isMandelboxRecurrence {
                            Text("+p₀")
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Text("\(group.passes) passes × \(group.steps) steps = \(group.workPerSample)")
                            .monospacedDigit()
                    }
                    .font(.caption2)
                    .foregroundStyle(group.workPerSample > 32 ? .orange : .secondary)
                }
                Text(cache.fractalType == .constructionPrimitive
                     ? "This is the only geometry recurrence. It is not multiplied by Formula Iterations."
                     : "Transforms run before the formula loop. The two costs are sequential, not multiplied together.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Render-quality controls — compositor drawable quality plus optional MetalFX
    /// raymarch input scale where supported.
    @ViewBuilder
    private var performanceQualityControls: some View {
        // ── Detail/Framerate Budget ──
        // Mac/iOS use this as the MetalFX input scale. visionOS uses compositor
        // Render Quality instead; the separate MetalFX spatial path is disabled
        // on headset because it looks worse and has caused crashes.
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
                CompactValueSlider(
                    title: "Resolution Scale",
                    value: Binding(
                        get: { cache.quality.resolutionScale },
                        set: { newValue in
                            let snapped = (newValue * 100).rounded() / 100
                            cache.quality.resolutionScale = snapped
                            cache.push(\.resolutionScale, value: snapped)
                        }
                    ),
                    range: ControlCatalog.resolutionScale.range,
                    step: 0.01,
                    display: "\(Int((cache.quality.resolutionScale * 100).rounded()))%",
                    tint: .cyan
                )
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
        // ── Render Quality (Vision Pro compositor drawable resolution) ──
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Render Quality")
                Spacer()
                Text("\(Int((cache.quality.renderQuality * 100).rounded()))%")
                    .fontWeight(.bold)
                    .monospacedDigit()
            }

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
                .accessibilityLabel(Text("Render Quality"))
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
            .help("When FPS sags, render quality steps down to recover headroom, then climbs back toward your slider setting (the ceiling).")

            Text("Vision Pro compositor drawable size. This is the main memory ceiling; lower values reduce drawable memory and GPU cost.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        #endif
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
