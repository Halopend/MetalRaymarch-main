//
//  ContentView+ColoringTab.swift
//  Threshold
//
//  Coloring tab UI extracted from ContentView.swift (Phase C refactor).
//  Stored properties remain on the main `ContentView` struct.
//

import SwiftUI

extension ContentView {
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Coloring Tab
    // ═══════════════════════════════════════════════════════════════════════════
    
    var coloringTabContent: some View {
        VStack(spacing: 0) {
            if currentRoute == .look(.grading) {
                postProcessingSectionPicker
                Divider()
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    switch currentRoute {
                    case .look(.color):
                        coloringGradientContent
                        Divider().padding(.vertical, 4)
                        coloringMappingContent
                    case .look(.mapping): coloringMappingContent
                    case .look(.grading): coloringGradingContent
                    default: EmptyView()
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }

    private var postProcessingSectionPicker: some View {
        Picker("Post Processing section", selection: $postProcessingSection) {
            ForEach(PostProcessingSection.allCases) { section in
                Label(section.rawValue, systemImage: section.icon).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Post Processing section")
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
    
    private var coloringGradientContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Gradient Colors", systemImage: AppIcons.paintbrushFill)
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
                Label("Color Mapping", systemImage: AppIcons.target).font(.headline)
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
            if postProcessingSection == .color {
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
            }

            if postProcessingSection == .style {
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
            }

            if postProcessingSection == .filters {
                postProcessingFiltersContent
            }
        }
    }

    private var postProcessingFiltersContent: some View {
        let filters = cache.postFilterStack
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Filter Stack", systemImage: "square.stack.3d.up")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(filters.count)/\(PostFilterInstance.maximumCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Menu {
                    ForEach(PostProcessingFilterKind.allCases) { kind in
                        Button {
                            addPostFilter(kind)
                        } label: {
                            Label(
                                kind == .edgeDetection
                                    && filters.contains(where: { $0.kind == .edgeDetection })
                                    ? "\(kind.displayName) (Already Added)"
                                    : kind.displayName,
                                systemImage: kind.icon
                            )
                        }
                        .disabled(!canAddPostFilter(kind))
                    }
                } label: {
                    Label("Add Filter", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(filters.count >= PostFilterInstance.maximumCount)
                .help(filters.count >= PostFilterInstance.maximumCount
                      ? "A scene can contain up to \(PostFilterInstance.maximumCount) filters"
                      : "Add an output filter")
            }

            Text("Filters run from top to bottom. Reorder them to change how each treatment feeds the next one. Add up to eight filters; Edge Detection can appear once.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if filters.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "camera.filters")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("No Filters")
                        .font(.subheadline.weight(.medium))
                    Text("Add a filter to build an ordered final-image treatment.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            } else {
                ForEach(Array(filters.enumerated()), id: \.element.id) { index, filter in
                    postFilterCard(
                        filter,
                        index: index,
                        isFirst: index == filters.startIndex,
                        isLast: index == filters.index(before: filters.endIndex)
                    )
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: cache.postFilterStructureRevision)
    }

    @ViewBuilder
    private func postFilterCard(
        _ filter: PostFilterInstance,
        index: Int,
        isFirst: Bool,
        isLast: Bool
    ) -> some View {
        let selected = postProcessingFilter == filter.kind
        VStack(alignment: .leading, spacing: 7) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    postFilterIdentity(filter, index: index)
                    Spacer(minLength: 4)
                    postFilterActions(filter, isFirst: isFirst, isLast: isLast)
                }
                VStack(alignment: .leading, spacing: 6) {
                    postFilterIdentity(filter, index: index)
                    HStack(spacing: 8) {
                        Spacer()
                        postFilterActions(filter, isFirst: isFirst, isLast: isLast)
                    }
                }
            }

            Divider()
            postFilterControls(filter)

            Text(filter.kind.summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(
            selected ? Color.indigo.opacity(0.11) : Color.primary.opacity(0.05)
        ))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(
            selected ? Color.indigo.opacity(0.65) : Color.clear,
            lineWidth: 1
        ))
        .animation(.easeInOut(duration: 0.15), value: postFilterControlRevision)
    }

    private func postFilterIdentity(_ filter: PostFilterInstance, index: Int) -> some View {
        Button {
            postProcessingFilter = filter.kind
        } label: {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Label(filter.kind.displayName, systemImage: filter.kind.icon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filter \(index + 1), \(filter.kind.displayName)")
        .accessibilityHint("Selects this filter card")
    }

    private func postFilterActions(
        _ filter: PostFilterInstance,
        isFirst: Bool,
        isLast: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Toggle("Enable \(filter.kind.displayName)", isOn: postFilterBoolBinding(filter, \.isEnabled))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("\(filter.kind.displayName) enabled")
            Button {
                movePostFilter(filter.id, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(isFirst)
            .help("Move \(filter.kind.displayName) up")
            .accessibilityLabel("Move \(filter.kind.displayName) up")
            Button {
                movePostFilter(filter.id, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(isLast)
            .help("Move \(filter.kind.displayName) down")
            .accessibilityLabel("Move \(filter.kind.displayName) down")
            Button(role: .destructive) {
                deletePostFilter(filter.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove \(filter.kind.displayName)")
            .accessibilityLabel("Remove \(filter.kind.displayName)")
        }
    }

    @ViewBuilder
    private func postFilterControls(_ filter: PostFilterInstance) -> some View {
        // Keep this live rather than using `Binding.constant`: toggling a card
        // must immediately enable/disable every slider without waiting for an
        // unrelated view refresh.
        let enabled = postFilterBoolBinding(filter, \.isEnabled)
        VStack(spacing: 4) {
            EffectSliderRow(
                icon: filter.kind.icon,
                label: "Amount",
                value: postFilterFloatBinding(filter, \.amount),
                range: 0...1,
                enabled: enabled,
                onChanged: {},
                showToggle: false,
                valueFormat: { $0 <= PostFilterInstance.activationEpsilon ? "Off" : String(format: "%.2f", $0) },
                pairedColor: filter.kind == .edgeDetection
                    ? postFilterColorBinding(filter)
                    : nil
            )

            switch filter.kind {
            case .edgeDetection:
                Divider().padding(.leading, 159)
                EffectSliderRow(
                    icon: ControlCatalog.edgeThreshold.icon,
                    label: "Threshold",
                    value: postFilterFloatBinding(filter, \.params.x),
                    range: ControlCatalog.edgeThreshold.range,
                    enabled: enabled,
                    onChanged: {},
                    showToggle: false
                )
                Divider().padding(.leading, 159)
                EffectSliderRow(
                    icon: ControlCatalog.edgeSoftness.icon,
                    label: "Softness",
                    value: postFilterFloatBinding(filter, \.params.y),
                    range: ControlCatalog.edgeSoftness.range,
                    enabled: enabled,
                    onChanged: {},
                    showToggle: false
                )
                Divider().padding(.leading, 159)
                EffectSliderRow(
                    icon: ControlCatalog.edgeWindowRadius.icon,
                    label: "Window Size",
                    value: postFilterFloatBinding(filter, \.params.z),
                    range: ControlCatalog.edgeWindowRadius.range,
                    enabled: enabled,
                    onChanged: {},
                    showToggle: false,
                    valueFormat: { String(Int($0.rounded())) }
                )

            case .posterize:
                Divider().padding(.leading, 159)
                EffectSliderRow(
                    icon: "square.stack.3d.up.fill",
                    label: "Color Levels",
                    value: postFilterFloatBinding(filter, \.params.x),
                    range: 2...32,
                    enabled: enabled,
                    onChanged: {},
                    showToggle: false,
                    valueFormat: { String(Int($0.rounded())) }
                )

            case .grain:
                Divider().padding(.leading, 159)
                EffectSliderRow(
                    icon: "aqi.medium",
                    label: "Frequency",
                    value: postFilterFloatBinding(filter, \.params.x),
                    range: 1...2048,
                    enabled: enabled,
                    onChanged: {},
                    showToggle: false,
                    valueFormat: { String(Int($0.rounded())) }
                )

            case .scanlines:
                Divider().padding(.leading, 159)
                EffectSliderRow(
                    icon: "line.3.horizontal",
                    label: "Line Density",
                    value: postFilterFloatBinding(filter, \.params.x),
                    range: 1...2048,
                    enabled: enabled,
                    onChanged: {},
                    showToggle: false,
                    valueFormat: { String(Int($0.rounded())) }
                )
                Divider().padding(.leading, 159)
                EffectSliderRow(
                    icon: "circle.lefthalf.filled",
                    label: "Darkening",
                    value: postFilterFloatBinding(filter, \.params.y),
                    range: 0...1,
                    enabled: enabled,
                    onChanged: {},
                    showToggle: false
                )

            case .monochrome, .sepia, .invert:
                EmptyView()
            }
        }
        .opacity((livePostFilter(filter)?.isEnabled ?? filter.isEnabled) ? 1 : 0.48)
    }

    private func livePostFilter(_ fallback: PostFilterInstance) -> PostFilterInstance? {
        cache.postFilterStack.first { $0.id == fallback.id }
    }

    private func postFilterFloatBinding(
        _ filter: PostFilterInstance,
        _ keyPath: WritableKeyPath<PostFilterInstance, Float>
    ) -> Binding<Float> {
        Binding(
            get: { livePostFilter(filter)?[keyPath: keyPath] ?? filter[keyPath: keyPath] },
            set: { value in
                cache.updatePostFilter(id: filter.id) { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func postFilterBoolBinding(
        _ filter: PostFilterInstance,
        _ keyPath: WritableKeyPath<PostFilterInstance, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { livePostFilter(filter)?[keyPath: keyPath] ?? filter[keyPath: keyPath] },
            set: { value in
                cache.updatePostFilter(id: filter.id) { $0[keyPath: keyPath] = value }
                postFilterControlRevision &+= 1
            }
        )
    }

    private func postFilterColorBinding(_ filter: PostFilterInstance) -> Binding<SIMD3<Float>> {
        Binding(
            get: { livePostFilter(filter)?.color ?? filter.color },
            set: { color in
                cache.updatePostFilter(id: filter.id) { $0.color = color }
            }
        )
    }

    private func canAddPostFilter(_ kind: PostProcessingFilterKind) -> Bool {
        let filters = cache.postFilterStack
        guard filters.count < PostFilterInstance.maximumCount else { return false }
        return kind != .edgeDetection || !filters.contains { $0.kind == .edgeDetection }
    }

    private func addPostFilter(_ kind: PostProcessingFilterKind) {
        guard canAddPostFilter(kind) else { return }
        postProcessingFilter = kind
        cache.replacePostFilterStack(cache.postFilterStack + [kind.defaultInstance])
    }

    private func movePostFilter(_ id: UUID, by offset: Int) {
        var filters = cache.postFilterStack
        guard let source = filters.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard filters.indices.contains(destination) else { return }
        filters.swapAt(source, destination)
        cache.replacePostFilterStack(filters)
    }

    private func deletePostFilter(_ id: UUID) {
        var filters = cache.postFilterStack
        guard let index = filters.firstIndex(where: { $0.id == id }) else { return }
        let removedKind = filters[index].kind
        filters.remove(at: index)
        cache.replacePostFilterStack(filters)
        if postProcessingFilter == removedKind,
           !filters.contains(where: { $0.kind == removedKind }),
           !filters.isEmpty {
            postProcessingFilter = filters[min(index, filters.count - 1)].kind
        }
    }

    /// Control Finder can target a filter kind that is not authored in the
    /// current scene. Add a disabled card so navigation has a concrete target,
    /// while leaving the rendered image unchanged until the user enables it.
    func ensurePostProcessingFilterCard(for kind: PostProcessingFilterKind) {
        guard !cache.postFilterStack.contains(where: { $0.kind == kind }),
              cache.postFilterStack.count < PostFilterInstance.maximumCount else { return }
        var instance = kind.defaultInstance
        instance.isEnabled = false
        cache.replacePostFilterStack(cache.postFilterStack + [instance])
    }
}
