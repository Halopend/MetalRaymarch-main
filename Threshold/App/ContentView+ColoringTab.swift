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
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    switch coloringSubTab {
                    case .gradient: coloringGradientContent
                    case .mapping:  coloringMappingContent
                    case .grading:  coloringGradingContent
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
            GradientPreviewBar(gradient: cache.color.gradientState.gradient)
                .frame(height: 28).clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture { showStopsPopover = true }
                .popover(isPresented: $showStopsPopover, arrowEdge: .bottom) {
                    GradientStopsPopover(cache: $cache)
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4), lineWidth: 1))
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
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
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
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
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

            LazyVGrid(columns: [GridItem(.flexible(minimum: 100), spacing: 8), GridItem(.flexible(minimum: 100), spacing: 8), GridItem(.flexible(minimum: 100), spacing: 8)], spacing: 8) {
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
                    value: $cache.color.gradientState.gradient.repeatCount, range: 0.1...5.0,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.gradientRepeat, value: cache.color.gradientState.gradient.repeatCount) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "arrow.right", label: "Offset",
                    value: $cache.color.gradientState.gradient.offset, range: 0...1,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.gradientOffset, value: cache.color.gradientState.gradient.offset) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "waveform.path", label: "Smoothing",
                    value: $cache.color.gradientState.gradient.smoothing, range: 0...1,
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
                    value: $cache.color.colorMix, range: 0...1.0,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorMix, value: cache.color.colorMix) },
                    showToggle: false,
                    musicTargetID: ParameterTargetID.Core.colorMix)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "number", label: "Iterations",
                    value: $cache.color.colorIterations, range: 4...16,
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
            Label("Color Grading", systemImage: AppIcons.cameraFilters).font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Tone controls
            VStack(spacing: 4) {
                EffectSliderRow(icon: "circle.lefthalf.filled", label: "Contrast",
                    value: $cache.color.colorSchemeContrast, range: 0.95...1.15,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeContrast, value: cache.color.colorSchemeContrast) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "paintpalette.fill", label: "Vibrance",
                    value: $cache.color.colorSchemeVibrance, range: 0...1.0,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeVibrance, value: cache.color.colorSchemeVibrance) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "waveform.path", label: "Midtone Curve",
                    value: $cache.color.colorSchemeCurve, range: -1.0...1.0,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeCurve, value: cache.color.colorSchemeCurve) },
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.06)))

            // Shadows & Highlights
            VStack(spacing: 4) {
                EffectSliderRow(icon: "shadow", label: "Shadows",
                    value: $cache.color.colorSchemeShadows, range: -0.05...0.05,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeShadows, value: cache.color.colorSchemeShadows) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "sun.max.fill", label: "Highlights",
                    value: $cache.color.colorSchemeHighlights, range: -0.5...1.0,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeHighlights, value: cache.color.colorSchemeHighlights) },
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.06)))
        }
    }
}
