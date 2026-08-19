//
//  ContentView+ColoringTab.swift
//  Threshold
//
//  Coloring tab UI extracted from ContentView.swift (Phase C refactor).
//  Stored properties remain on the main `ContentView` struct.
//

import SwiftUI

extension ContentView {
    private enum OutputFilter: String, CaseIterable, Identifiable {
        case none = "None"
        case edgeDetection = "Edge Detection (Canny-style)"
        case convolution = "Convolution"

        var id: Self { self }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Coloring Tab
    // ═══════════════════════════════════════════════════════════════════════════
    
    var coloringTabContent: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    switch currentRoute {
                    case .look(.color): coloringGradientContent
                    case .look(.mapping): coloringMappingContent
                    case .look(.grading): coloringGradingContent
                    default: EmptyView()
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }
    
    private var coloringGradientContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Gradient Coloring", systemImage: AppIcons.paintbrushFill)
                    .font(.headline)
                Spacer()
                Text("Current: \(cache.color.gradientState.gradientPreset?.displayName ?? cache.gradientLibrary.savedCustomGradients.first(where: { $0.id == cache.color.gradientState.gradient.id })?.name ?? "Custom")")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.blue.opacity(0.12)))
            }
            Button {
                showStopsPopover = true
            } label: {
                GradientPreviewBar(gradient: cache.color.gradientState.gradient)
                    .frame(height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit gradient colors")
            .accessibilityHint("Opens the gradient stop editor")
            .popover(isPresented: $showStopsPopover, arrowEdge: .bottom) {
                GradientStopsPopover(cache: cache)
            }
            // ── Saved Custom Gradients ──
            HStack {
                Text("Saved").font(.subheadline).foregroundColor(.secondary)
                Spacer()
                if !cache.gradientLibrary.savedCustomGradients.isEmpty {
                    Text("\(cache.gradientLibrary.savedCustomGradients.count)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if cache.gradientLibrary.savedCustomGradients.isEmpty {
                Text("Edit a gradient and tap Save to build your library.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 180), spacing: 6)], spacing: 6) {
                    ForEach(Array(cache.gradientLibrary.savedCustomGradients.enumerated()), id: \.element.id) { index, saved in
                        let isActive = cache.color.gradientState.gradientPreset == nil && cache.color.gradientState.gradient.id == saved.id
                        Button {
                            cache.applySavedGradient(saved)
                        } label: {
                            VStack(spacing: 3) {
                                GradientPreviewBar(gradient: saved)
                                    .frame(height: 10)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                    .allowsHitTesting(false)
                                Text(saved.name).font(.caption2).lineLimit(1)
                                if isActive {
                                    Label("Selected", systemImage: AppIcons.checkmarkCircleFill)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.blue)
                                }
                            }.frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .tint(isActive ? .purple : .indigo)
                        .accessibilityAddTraits(isActive ? .isSelected : [])
                        .contextMenu {
                            Button {
                                renamingGradientName = saved.name
                                renamingGradientIndex = index
                            } label: {
                                Label("Rename", systemImage: AppIcons.pencil)
                            }
                            Button {
                                cache.updateSavedGradient(at: index)
                            } label: {
                                Label("Overwrite with Current", systemImage: AppIcons.arrowDownCircle)
                            }
                            Divider()
                            Button(role: .destructive) {
                                cache.deleteSavedGradient(at: index)
                            } label: {
                                Label("Delete", systemImage: AppIcons.trash)
                            }
                        }
                        .onLongPressGesture(minimumDuration: 0.5) {
                            renamingGradientName = saved.name
                            renamingGradientIndex = index
                        }
                    }
                }
            }
            
            // ── Presets ──
            Text("Presets").font(.subheadline).foregroundColor(.secondary)
                .padding(.top, 4)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 180), spacing: 6)], spacing: 6) {
                ForEach(GradientPreset.allCases, id: \.rawValue) { preset in
                    let isSelected = cache.color.gradientState.gradientPreset == preset
                    Button { cache.applyGradientPreset(preset) } label: {
                        VStack(spacing: 3) {
                            Image(systemName: preset.icon).font(.caption)
                            Text(preset.displayName).font(.caption2).lineLimit(1)
                            if isSelected {
                                Label("Selected", systemImage: AppIcons.checkmarkCircleFill)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.blue)
                            }
                        }.frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(isSelected ? .blue : .secondary)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }

            // ── Save / Edit Buttons ──
            HStack(spacing: 8) {
                Button { showStopsPopover = true } label: {
                    Label("Edit Gradient", systemImage: AppIcons.sliderHorizontal3)
                        .font(.caption)
                }
                .buttonStyle(.bordered).tint(cache.color.gradientState.gradientPreset == nil ? .blue : .secondary)
            }
        }
        .alert("Rename Gradient", isPresented: .init(
            get: { renamingGradientIndex != nil },
            set: { if !$0 { renamingGradientIndex = nil } }
        )) {
            TextField("Name", text: $renamingGradientName)
            Button("Cancel", role: .cancel) { renamingGradientIndex = nil }
            Button("Rename") {
                if let idx = renamingGradientIndex {
                    cache.renameSavedGradient(at: idx, to: renamingGradientName)
                }
                renamingGradientIndex = nil
            }
        } message: {
            Text("Enter a new name for this gradient")
        }
    }
    
    private var coloringMappingContent: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Mapping Mode", systemImage: AppIcons.target).font(.headline)
                Spacer()
                Text(cache.color.gradientState.gradient.mappingMode.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.blue.opacity(0.12)))
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 220), spacing: 8)], spacing: 8) {
                ForEach(ColorMappingMode.allCases, id: \.rawValue) { mode in
                    let isSelected = cache.color.gradientState.gradient.mappingMode == mode
                    Button {
                        cache.color.gradientState.gradient.mappingMode = mode
                        cache.push(\.colorMappingMode, value: mode)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Image(systemName: mappingModeIcon(mode))
                                    .font(.caption)
                                    .frame(width: 14)
                                    .foregroundStyle(isSelected ? Color.blue : .secondary)
                                Text(mode.displayName)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if isSelected {
                                    Image(systemName: AppIcons.checkmarkCircleFill)
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                }
                            }
                            Text(mappingModeDescription(mode))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isSelected ? Color.blue.opacity(0.18) : Color.white.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(isSelected ? Color.blue.opacity(0.5) : Color.secondary.opacity(0.12), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(mode.displayName)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }

            // Gradient transform controls
            VStack(spacing: 4) {
                EffectSliderRow(icon: "repeat", label: "Repeat",
                    value: cacheBinding(\.color.gradientState.gradient.repeatCount),
                    range: ControlCatalog.gradientRepeat.range,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.gradientRepeat, value: cache.color.gradientState.gradient.repeatCount) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "arrow.right", label: "Offset",
                    value: cacheBinding(\.color.gradientState.gradient.offset),
                    range: ControlCatalog.gradientOffset.range,
                    enabled: .constant(true),
                    onChanged: { cache.commitGradientOffset() },
                    showToggle: false,
                    musicTargetID: ParameterTargetID.Effect.gradientOffset)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "waveform.path", label: "Smoothing",
                    value: cacheBinding(\.color.gradientState.gradient.smoothing),
                    range: ControlCatalog.gradientSmoothing.range,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.gradientSmoothing, value: cache.color.gradientState.gradient.smoothing) },
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.06)))

            Divider()

            // Color blend controls
            VStack(spacing: 4) {
                EffectSliderRow(icon: "circle.lefthalf.filled", label: "Color Mix",
                    value: cacheBinding(\.color.colorMix),
                    range: ControlCatalog.colorMix.range,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorMix, value: cache.color.colorMix) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "number", label: "Iterations",
                    value: cacheBinding(\.color.colorIterations), range: ControlCatalog.colorIterations.range,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorIterations, value: cache.color.colorIterations) },
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.indigo.opacity(0.06)))
        }
    }

    private func mappingModeIcon(_ mode: ColorMappingMode) -> String {
        switch mode {
        case .orbitTrap:  return "scope"
        case .iterations: return "number.circle"
        case .zDepth:     return "arrow.forward.to.line"
        case .angle:      return "rotate.right"
        case .normal:     return "arrow.up.right.circle"
        case .blended:    return "blendmode"
        }
    }

    private func mappingModeDescription(_ mode: ColorMappingMode) -> String {
        switch mode {
        case .orbitTrap:  return "Distance to orbit trap"
        case .iterations: return "Normalized iteration count"
        case .zDepth:     return "Camera depth"
        case .angle:      return "Polar trap angle"
        case .normal:     return "Surface normal"
        case .blended:    return "Trap + iteration mix"
        }
    }

    private var coloringGradingContent: some View {
        VStack(spacing: 12) {
            Label("Post Processing", systemImage: AppIcons.cameraFilters).font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Tone controls
            VStack(spacing: 4) {
                EffectSliderRow(icon: "circle.lefthalf.filled", label: "Contrast",
                    value: cacheBinding(\.color.colorSchemeContrast), range: ControlCatalog.colorSchemeContrast.range,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeContrast, value: cache.color.colorSchemeContrast) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "circle.lefthalf.filled", label: "Gamma",
                    value: cacheBinding(\.color.colorSchemeGamma), range: ControlCatalog.colorSchemeGamma.range,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeGamma, value: cache.color.colorSchemeGamma) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "waveform.path", label: "Midtone Curve",
                    value: cacheBinding(\.color.colorSchemeCurve), range: ControlCatalog.colorSchemeCurve.range,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeCurve, value: cache.color.colorSchemeCurve) },
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.06)))

            // Color response, shadows & highlights
            VStack(spacing: 4) {
                EffectSliderRow(icon: ControlCatalog.saturation.icon, label: "Saturation",
                    value: cacheBinding(\.color.colorSchemeSaturation), range: ControlCatalog.saturation.range,
                    enabled: .constant(true),
                    onChanged: { cache.commitColorSchemeSaturation() },
                    showToggle: false,
                    musicTargetID: ParameterTargetID.Effect.saturation)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "paintpalette.fill", label: "Vibrance",
                    value: cacheBinding(\.color.colorSchemeVibrance), range: ControlCatalog.colorSchemeVibrance.range,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeVibrance, value: cache.color.colorSchemeVibrance) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "shadow", label: "Shadows",
                    value: cacheBinding(\.color.colorSchemeShadows), range: ControlCatalog.colorSchemeShadows.range,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeShadows, value: cache.color.colorSchemeShadows) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "sun.max.fill", label: "Highlights",
                    value: cacheBinding(\.color.colorSchemeHighlights), range: ControlCatalog.colorSchemeHighlights.range,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeHighlights, value: cache.color.colorSchemeHighlights) },
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.06)))

            // Lighting finish and stylization. Zero-valued scalar effects are
            // true bypasses; Cell Shading retains its explicit toggle because
            // its useful band-count range starts at two.
            VStack(spacing: 4) {
                EffectSliderRow(icon: ControlCatalog.lightingSoftness.icon, label: "Lighting Softness",
                    value: cacheBinding(\.color.lightingSoftness), range: ControlCatalog.lightingSoftness.range,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.lightingSoftness, value: cache.color.lightingSoftness) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: ControlCatalog.cellShadingLevels.icon, label: "Cell Shading",
                    value: cacheBinding(\.color.cellShadingLevels), range: ControlCatalog.cellShadingLevels.range,
                    enabled: cacheBinding(\.color.cellShadingEnabled),
                    onChanged: {
                        cache.push(\.cellShadingEnabled, value: cache.color.cellShadingEnabled)
                        cache.push(\.cellShadingLevels, value: cache.color.cellShadingLevels)
                    })
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "circle.lefthalf.striped.horizontal", label: "Ambient Occlusion",
                    value: cacheBinding(\.color.aoStrength), range: ControlCatalog.aoStrength.range,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.aoStrength, value: cache.color.aoStrength) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "camera.aperture", label: "Filmic Tonemap",
                    value: cacheBinding(\.color.tonemapStrength), range: ControlCatalog.tonemapStrength.range,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.tonemapStrength, value: cache.color.tonemapStrength) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: ControlCatalog.vignetteStrength.icon, label: "Vignette",
                    value: cacheBinding(\.color.vignetteStrength), range: ControlCatalog.vignetteStrength.range,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.vignetteStrength, value: cache.color.vignetteStrength) },
                    showToggle: false,
                    valueFormat: { $0 <= 0.001 ? "Off" : String(format: "%.2f", $0) })
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.06)))

            // Output-space filters are scene-authored and mutually exclusive.
            // MetalFX frames apply them after reconstruction so their footprint
            // is measured in output pixels.
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Filter", systemImage: AppIcons.cameraFilters)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Picker("Filter", selection: outputFilterBinding) {
                        ForEach(OutputFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                switch selectedOutputFilter {
                case .none:
                    Text("No output-space image filter is applied.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .edgeDetection:
                    edgeDetectionFilterControls
                case .convolution:
                    convolutionFilterControls
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.indigo.opacity(0.06)))
        }
    }

    private var selectedOutputFilter: OutputFilter {
        if cache.lighting.convolutionEffect.enabled { return .convolution }
        if cache.lighting.edgeDetectionEffect.enabled { return .edgeDetection }
        return .none
    }

    private var outputFilterBinding: Binding<OutputFilter> {
        Binding(get: { selectedOutputFilter }, set: { filter in
            switch filter {
            case .none:
                cache.lighting.edgeDetectionEffect.setStrength(0)
                cache.lighting.convolutionEffect.setStrength(0)
            case .edgeDetection:
                cache.lighting.convolutionEffect.setStrength(0)
                if !cache.lighting.edgeDetectionEffect.isActive {
                    cache.lighting.edgeDetectionEffect.setStrength(0.8)
                }
            case .convolution:
                cache.lighting.edgeDetectionEffect.setStrength(0)
                if !cache.lighting.convolutionEffect.isActive {
                    cache.lighting.convolutionEffect.setStrength(0.8)
                }
            }
            cache.lighting.lightingPreset = .custom
            cache.commitEdgeDetectionEffect()
            cache.commitConvolutionEffect()
        })
    }

    @ViewBuilder
    private var edgeDetectionFilterControls: some View {
        EffectSliderRow(
            icon: "circle.lefthalf.filled", label: "Strength",
            value: Binding(
                get: { cache.lighting.edgeDetectionEffect.strength },
                set: { cache.lighting.edgeDetectionEffect.setStrength($0) }
            ),
            range: ControlCatalog.edgeStrength.range,
            enabled: .constant(true),
            onChanged: { cache.commitEdgeDetectionEffect() },
            showToggle: false
        )
        Divider().padding(.leading, 159)
        EffectSliderRow(
            icon: ControlCatalog.edgeThreshold.icon, label: "Threshold",
            value: Binding(
                get: { cache.lighting.edgeDetectionEffect.threshold },
                set: { cache.lighting.edgeDetectionEffect.threshold = $0 }
            ),
            range: ControlCatalog.edgeThreshold.range,
            enabled: .constant(true),
            onChanged: { cache.commitEdgeDetectionEffect() },
            showToggle: false
        )
        Divider().padding(.leading, 159)
        EffectSliderRow(
            icon: ControlCatalog.edgeSoftness.icon, label: "Softness",
            value: Binding(
                get: { cache.lighting.edgeDetectionEffect.softness },
                set: { cache.lighting.edgeDetectionEffect.softness = $0 }
            ),
            range: ControlCatalog.edgeSoftness.range,
            enabled: .constant(true),
            onChanged: { cache.commitEdgeDetectionEffect() },
            showToggle: false
        )
        Divider().padding(.leading, 159)
        EffectSliderRow(
            icon: ControlCatalog.edgeWindowRadius.icon, label: "Window Size",
            value: Binding(
                get: { Float(cache.lighting.edgeDetectionEffect.windowRadius) },
                set: { cache.lighting.edgeDetectionEffect.windowRadius = Int($0.rounded()) }
            ),
            range: ControlCatalog.edgeWindowRadius.range,
            enabled: .constant(true),
            onChanged: { cache.commitEdgeDetectionEffect() },
            showToggle: false,
            valueFormat: { String(Int($0.rounded())) }
        )
    }

    @ViewBuilder
    private var convolutionFilterControls: some View {
        EffectSliderRow(
            icon: "circle.lefthalf.filled", label: "Amount",
            value: Binding(
                get: { cache.lighting.convolutionEffect.strength },
                set: { cache.lighting.convolutionEffect.setStrength($0) }
            ),
            range: 0...1,
            enabled: .constant(true),
            onChanged: { cache.commitConvolutionEffect() },
            showToggle: false
        )

        HStack {
            Text("Kernel Size")
                .font(.subheadline)
            Spacer()
            Picker("Kernel Size", selection: Binding(
                get: { cache.lighting.convolutionEffect.kernelSize },
                set: {
                    cache.lighting.convolutionEffect.kernelSize = $0
                    cache.commitConvolutionEffect()
                }
            )) {
                ForEach(ConvolutionEffect.supportedKernelSizes, id: \.self) { size in
                    Text("\(size)×\(size)").tag(size)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 190)
        }

        TextEditor(text: Binding(
            get: { cache.lighting.convolutionEffect.kernelText },
            set: {
                cache.lighting.convolutionEffect.kernelText = $0
                cache.commitConvolutionEffect()
            }
        ))
        .font(.system(.callout, design: .monospaced))
        .autocorrectionDisabled()
        .scrollContentBackground(.hidden)
        .padding(8)
        .frame(minHeight: 84, maxHeight: 130)
        .background(Color.black.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 6))

        let kernel = cache.lighting.convolutionEffect.parsedKernel
        if let error = kernel.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else {
            Text("Coefficients are read left-to-right, top-to-bottom. Spaces, commas, semicolons, and new lines are accepted.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
