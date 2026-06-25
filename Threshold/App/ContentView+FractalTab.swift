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
                    cache: cache,
                    gestureController: appModel.gestureController,
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

            case .render:
                ScrollView(.vertical, showsIndicators: true) {
                    fractalQualityContent
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

    @ViewBuilder
    private var fractalSpaceContent: some View {
        let rotationEuler = eulerAngles(from: cache.liveWorldRotation)

        VStack(spacing: 12) {
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

            spaceWarpSection

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

    private var fractalQualityContent: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Performance", systemImage: AppIcons.gauge)
                    .font(.headline)
                Spacer()
                FPSIndicatorView()
            }

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
                HStack {
                    Text("Priority")
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
                    ), in: 0.1...QualityConfig.visionMaxRenderQuality, step: 0.05)
                    .accessibilityLabel(Text("Priority"))
                    Text("Sharp")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }

                Text("Vision Pro: the compositor's native, gaze-foveated resolution. The top of the range is the configured ceiling (a memory/quality balance) and the sharpest; lower trades crispness for GPU headroom with a smoothed transition. Very low values (10–20%) probe max framerate.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            #endif

            Divider()
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
