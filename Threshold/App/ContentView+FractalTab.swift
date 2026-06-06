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
                        Task { @MainActor in
                            customSceneDiagnostic("🔬 [CSDiag] ContentView.onLoadStaticScene name='\(preset.name)' ft=\(preset.fractalType.rawValue) embeddedFormula=\(preset.embeddedFormula?.name ?? "nil")")
                            if let formula = preset.embeddedFormula {
                                let installed = await appModel.installEmbeddedFormulaIfNeededAndWait(formula)
                                customSceneDiagnostic("🔬 [CSDiag] ContentView.onLoadStaticScene installEmbeddedFormula returned \(installed)")
                                guard installed else { return }
                            } else {
                                appModel.uninstallEmbeddedFormula()
                            }

                            if preset.embeddedFormula != nil {
                                await appModel.preparePipelineHandler?(preset)
                                customSceneDiagnostic("🔬 [CSDiag] ContentView.onLoadStaticScene preparePipelineHandler completed; loading preset NOW")
                            } else {
                                Task { await appModel.preparePipelineHandler?(preset) }
                                customSceneDiagnostic("🔬 [CSDiag] ContentView.onLoadStaticScene preparePipelineHandler dispatched (fire-and-forget); loading preset NOW")
                            }
                            // Snapshot the currently displayed parameters so the
                            // load can ease from them toward the new preset.
                            appModel.renderSettings.beginSceneTransitionSnapshot()
                            appModel.presetManager.loadPreset(
                                preset,
                                into: appModel.renderSettings,
                                resetEnvironment: true
                            )
                            // Ease displayed parameters toward the new preset's
                            // values over the configured "Same Scene Transition
                            // Time" instead of snapping instantly.
                            appModel.renderSettings.commitSceneTransition()
                            applyPresetGestureOverridesIfNeeded(for: preset)
                            appModel.gestureController?.syncWithSettings()
                            appModel.rememberActiveResetPreset(preset)
                            cache.loadFromSettings()
                        }
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
                        Label("Music Shape Control", systemImage: "waveform.path")
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
                    value: $cache.fractalScale, range: -3.0...5.0,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.targetFractalScale, value: cache.fractalScale) },
                    showToggle: false)
            }
        }
    }

    private var fractalFormulaContent: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Fractal Formula", systemImage: "function")
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
                    Label("Safety Bubble", systemImage: "shield.lefthalf.filled").font(.headline)
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
                    Label("Blend mode cost varies by scene/fractal/zoom — different values can be expensive in different conditions (Mandelbox often runs better with Blend off, but can behave differently when zoomed in).", systemImage: "exclamationmark.triangle")
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

            sphericalInversionSection

            // ── Detail (Grab Gesture Transform) ──────────────────────────────
            VStack(spacing: 8) {
                HStack {
                    Label("Detail", systemImage: "move.3d").font(.headline)
                    Spacer()
                    Button {
                        appModel.renderSettings.resetDetailTransform()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
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
                    Label("Zoom", systemImage: "magnifyingglass").font(.caption)
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
                    Label("Rotation", systemImage: "rotate.3d").font(.caption)
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
                Label("Spherical Inversion", systemImage: "circle.dashed.inset.filled")
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
                    range: 0.5...6.0,
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
    
    private var fractalQualityContent: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Performance", systemImage: "gauge")
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
                            if newValue == .framerate || newValue == .detail {
                                qualityGoalLastDirectPreferenceRaw = newValue.rawValue
                            }
                        }
                    )) {
                        ForEach(QualityGoalPreference.allCases, id: \.rawValue) { goal in
                            Text(goal.displayName).tag(goal)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 340)
                }
                Text("Framerate and Detail apply curated presets. Control unlocks free-form iteration and resolution sliders.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("Iteration Budget")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            if qualityGoalPreference != .control {
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
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(effectiveDirectBudgetLabel)
                    Spacer()
                    Text("\(Int(cache.quality.resolutionScale * 100))%")
                        .fontWeight(.bold)
                        .monospacedDigit()
                }

                if qualityGoalPreference != .control {
                    HStack(spacing: 8) {
                        let presets: [(label: String, scale: Float, icon: String?)] = {
                            // Shared labels (must match Iteration Budget wording): Low / Medium / High / Full
                            let items: [(String, Float, String, String)] = [
                                // Detail mode: use a dashed screen outline + inner grid to convey pixel density.
                                // Low is 0.34 (not 0.33) so it stays under MetalFX temporal's 3× cap.
                                ("Low", 0.34, "circle.grid.2x2", QualityPreset.low.icon),
                                ("Medium", 0.50, "circle.grid.3x3", QualityPreset.medium.icon),
                                ("High", 0.75, "circle.grid.3x3.fill", QualityPreset.high.icon),
                                ("Full", 1.0, "circle.grid.3x3.circle.fill", QualityPreset.ultra.icon)
                            ]

                            switch effectiveDirectBudgetPreference {
                            case .detail:
                                // Increasing detail left-to-right.
                                return items.map { (label: $0.0, scale: $0.1, icon: $0.2) }
                            case .framerate:
                                // Keep scale/order behavior, but label by framerate budget semantics.
                                // Left→right should read Low/Medium/High/Full for framerate.
                                let scalesAndIcons = items.reversed().map { (scale: $0.1, icon: $0.3) }
                                let framerateLabels = ["Low", "Medium", "High", "Full"]
                                return zip(framerateLabels, scalesAndIcons).map { pair in
                                    (label: pair.0, scale: pair.1.scale, icon: pair.1.icon)
                                }
                            case .control:
                                // Unreachable because we normalize control to the last direct preference.
                                return items.map { (label: $0.0, scale: $0.1, icon: $0.2) }
                            }
                        }()

                        ForEach(presets, id: \.label) { preset in
                            Button {
                                cache.quality.resolutionScale = preset.scale
                                cache.push(\.resolutionScale, value: preset.scale)
                            } label: {
                                VStack(spacing: 2) {
                                    if let icon = preset.icon {
                                        if effectiveDirectBudgetPreference == .framerate {
                                            Image(systemName: icon).font(.caption)
                                        } else {
                                            ZStack {
                                                Image(systemName: "rectangle.dashed")
                                                    .font(.caption)
                                                Image(systemName: icon)
                                                    .font(.caption2)
                                            }
                                        }
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

                if qualityGoalPreference == .control {
                    Slider(value: Binding(
                        get: { cache.quality.resolutionScale },
                        set: { newValue in
                            let snapped = (newValue * 100).rounded() / 100
                            cache.quality.resolutionScale = snapped
                            cache.push(\.resolutionScale, value: snapped)
                        }
                    ), in: 0.34...1.0, step: 0.01)
                    .disabled(cache.quality.tileSize == 8)
                }

                if cache.quality.tileSize == 8 {
                    Text(effectiveDirectBudgetUnavailableText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Group {
                    #if os(macOS) || os(iOS)
                        Text("MetalFX uses temporal upscaling when available. 50% to 75% is the usual quality/performance sweet spot.")
                    #else
                        Text("MetalFX on visionOS is spatial-only. 75% to 85% is the usual quality/performance sweet spot.")
                    #endif
                    }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
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

    var gesturePictographicAssignmentPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Hand Assignments", systemImage: "hand.point.up.left.and.text")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 10) {
                singleHandGesturePictograph(.left)
                singleHandGesturePictograph(.right)
            }

            Text("Tap a fingertip to map vertical and horizontal single-finger gestures.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func singleHandGesturePictograph(_ handMode: GestureHandMode) -> some View {
        VStack(spacing: 8) {
            Label(handMode.displayName, systemImage: handMode.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.08))

                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(.secondary.opacity(0.30))
                    .scaleEffect(x: handMode == .left ? -1 : 1, y: 1)
                    .offset(y: 10)

                HStack(spacing: 8) {
                    ForEach(FingerDigit.allCases, id: \.self) { finger in
                        singleFingerTipAssignmentButton(handMode: handMode, finger: finger)
                    }
                }
                .offset(y: -26)
            }
            .frame(height: 112)

            VStack(spacing: 4) {
                ForEach(FingerDigit.allCases, id: \.self) { finger in
                    singleFingerMappingSummaryRow(handMode: handMode, finger: finger)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func singleFingerTipAssignmentButton(handMode: GestureHandMode, finger: FingerDigit) -> some View {
        let verticalSlot = GestureSlot(hand: handMode, finger: finger, direction: .vertical)
        let horizontalSlot = GestureSlot(hand: handMode, finger: finger, direction: .horizontal)
        let verticalBinding = cache.gestureBinding(for: verticalSlot)
        let horizontalBinding = cache.gestureBinding(for: horizontalSlot)
        let bindings = GestureActionBinding.availableBindings(for: cache.fractalType, handMode: handMode)

        return Menu {
            Section("Vertical") {
                ForEach(bindings, id: \.self) { action in
                    Button {
                        cache.setGestureBinding(action, for: verticalSlot)
                    } label: {
                        HStack {
                            Label(action.contextualDisplayName(for: cache.fractalType), systemImage: action.icon)
                            if verticalBinding == action {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Section("Horizontal") {
                ForEach(bindings, id: \.self) { action in
                    Button {
                        cache.setGestureBinding(action, for: horizontalSlot)
                    } label: {
                        HStack {
                            Label(action.contextualDisplayName(for: cache.fractalType), systemImage: action.icon)
                            if horizontalBinding == action {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            if verticalBinding != .core(.none) || horizontalBinding != .core(.none) {
                Divider()
                Button("Clear Finger Mappings", role: .destructive) {
                    cache.setGestureBinding(.core(.none), for: verticalSlot)
                    cache.setGestureBinding(.core(.none), for: horizontalSlot)
                }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: finger.icon)
                    .font(.caption)
                HStack(spacing: 4) {
                    Image(systemName: verticalBinding.icon)
                        .font(.caption2)
                    Image(systemName: horizontalBinding.icon)
                        .font(.caption2)
                }
            }
            .frame(width: 34, height: 38)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.blue.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func singleFingerMappingSummaryRow(handMode: GestureHandMode, finger: FingerDigit) -> some View {
        let verticalSlot = GestureSlot(hand: handMode, finger: finger, direction: .vertical)
        let horizontalSlot = GestureSlot(hand: handMode, finger: finger, direction: .horizontal)
        let verticalBinding = cache.gestureBinding(for: verticalSlot)
        let horizontalBinding = cache.gestureBinding(for: horizontalSlot)

        return HStack(spacing: 6) {
            Text(finger.displayName)
                .font(.caption2.weight(.semibold))
                .frame(width: 46, alignment: .leading)

            Text("V")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(verticalBinding.contextualDisplayName(for: cache.fractalType))
                .font(.caption2)
                .lineLimit(1)

            Text("H")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            Text(horizontalBinding.contextualDisplayName(for: cache.fractalType))
                .font(.caption2)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    func gestureHandSection(mode: GestureHandMode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(mode.displayName, systemImage: mode.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            if mode == .both {
                ForEach(FingerDigit.allCases, id: \.self) { finger in
                    let slot = GestureSlot(hand: mode, finger: finger)
                    gestureSlotPicker(slot: slot, handMode: mode)
                }
            } else {
                ForEach(FingerDigit.allCases, id: \.self) { finger in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finger.displayName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)

                        let verticalSlot = GestureSlot(hand: mode, finger: finger, direction: .vertical)
                        gestureSlotPicker(slot: verticalSlot, handMode: mode, directionLabel: "↕")

                        let horizontalSlot = GestureSlot(hand: mode, finger: finger, direction: .horizontal)
                        gestureSlotPicker(slot: horizontalSlot, handMode: mode, directionLabel: "↔")
                    }
                }
            }
        }
    }

    /// Picker row for assigning a gesture binding to a hand+finger slot.
    @ViewBuilder
    func gestureSlotPicker(slot: GestureSlot, handMode: GestureHandMode, directionLabel: String? = nil) -> some View {
        let bindings = GestureActionBinding.availableBindings(for: cache.fractalType, handMode: handMode)
        let currentBinding = Binding<GestureActionBinding>(
            get: { cache.gestureBinding(for: slot) },
            set: { cache.setGestureBinding($0, for: slot) }
        )
        HStack {
            if let directionLabel {
                Text(directionLabel)
                    .font(.caption2)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
            }
            if handMode == .both {
                Label(slot.finger.displayName, systemImage: slot.finger.icon).font(.subheadline)
            }
            Spacer()
            Picker(slot.finger.displayName, selection: currentBinding) {
                ForEach(bindings, id: \.self) { action in
                    Label(action.contextualDisplayName(for: cache.fractalType), systemImage: action.icon).tag(action)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 220)
        }
    }
}
