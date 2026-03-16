//
//  ColoringViews.swift
//  Threshold
//
//  Extracted from ContentView: Gradient browser, color mapping, and color grading.
//  Self-contained state for gradient management (rename, delete, etc.).
//

import SwiftUI

// MARK: - Gradient Browser

struct GradientBrowserView: View {
    @Binding var cache: UISettingsCache
    @Binding var showStopsPopover: Bool

    // Self-contained state (no longer pollutes ContentView)
    @State private var savedGradientToDelete: Int? = nil
    @State private var showDeleteConfirm = false
    @State private var renamingGradientIndex: Int? = nil
    @State private var renamingGradientName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Gradient Coloring", systemImage: "paintbrush.fill").font(.headline)
            GradientPreviewBar(gradient: cache.color.gradientState.gradient)
                .frame(height: 28).clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture { showStopsPopover = true }
                .popover(isPresented: $showStopsPopover, arrowEdge: .bottom) {
                    GradientStopsPopover(cache: $cache)
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4), lineWidth: 1))
            Text("Presets").font(.subheadline).foregroundColor(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(GradientPreset.allCases, id: \.rawValue) { preset in
                    Button { cache.applyGradientPreset(preset) } label: {
                        VStack(spacing: 2) {
                            Image(systemName: preset.icon).font(.caption)
                            Text(preset.displayName).font(.caption2).lineLimit(1)
                        }.frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered).tint(cache.color.gradientState.gradientPreset == preset ? .blue : .secondary)
                }
            }

            // ── Saved Custom Gradients ──
            if !cache.gradientLibrary.savedCustomGradients.isEmpty {
                HStack {
                    Text("Saved").font(.subheadline).foregroundColor(.secondary)
                    Spacer()
                    Text("\(cache.gradientLibrary.savedCustomGradients.count)").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.top, 4)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(Array(cache.gradientLibrary.savedCustomGradients.enumerated()), id: \.element.id) { index, saved in
                        let isActive = cache.color.gradientState.gradientPreset == nil && cache.color.gradientState.gradient.id == saved.id
                        Button {
                            cache.applySavedGradient(saved)
                        } label: {
                            VStack(spacing: 2) {
                                GradientPreviewBar(gradient: saved)
                                    .frame(height: 10)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                    .allowsHitTesting(false)
                                Text(saved.name).font(.caption2).lineLimit(1)
                            }.frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .tint(isActive ? .purple : .indigo)
                        .contextMenu {
                            Button {
                                renamingGradientName = saved.name
                                renamingGradientIndex = index
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button {
                                cache.updateSavedGradient(at: index)
                            } label: {
                                Label("Overwrite with Current", systemImage: "arrow.down.circle")
                            }
                            Divider()
                            Button(role: .destructive) {
                                cache.deleteSavedGradient(at: index)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .onLongPressGesture(minimumDuration: 0.5) {
                            renamingGradientName = saved.name
                            renamingGradientIndex = index
                        }
                    }
                }
            }

            // ── Save / Edit Buttons ──
            HStack(spacing: 8) {
                Button { showStopsPopover = true } label: {
                    Label("Edit Gradient", systemImage: "slider.horizontal.3")
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
}

// MARK: - Color Mapping

struct ColorMappingView: View {
    var cache: UISettingsCache

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Mapping Mode", systemImage: "target").font(.headline)
                Spacer()
                Picker("Mapping", selection: Binding(
                    get: { cache.color.gradientState.gradient.mappingMode },
                    set: { cache.color.gradientState.gradient.mappingMode = $0; cache.push(\.colorMappingMode, value: $0) }
                )) {
                    ForEach(ColorMappingMode.allCases, id: \.rawValue) { Text($0.displayName).tag($0) }
                }.pickerStyle(.menu).frame(maxWidth: 140)
            }

            // Gradient transform controls
            VStack(spacing: 4) {
                EffectSliderRow(icon: "repeat", label: "Repeat",
                    value: Binding(get: { cache.color.gradientState.gradient.repeatCount }, set: { cache.color.gradientState.gradient.repeatCount = $0 }),
                    range: 0.1...5.0,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.gradientRepeat, value: cache.color.gradientState.gradient.repeatCount) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "arrow.right", label: "Offset",
                    value: Binding(get: { cache.color.gradientState.gradient.offset }, set: { cache.color.gradientState.gradient.offset = $0 }),
                    range: 0...1,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.gradientOffset, value: cache.color.gradientState.gradient.offset) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "waveform.path", label: "Smoothing",
                    value: Binding(get: { cache.color.gradientState.gradient.smoothing }, set: { cache.color.gradientState.gradient.smoothing = $0 }),
                    range: 0...1,
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
                    value: Binding(get: { cache.color.colorMix }, set: { cache.color.colorMix = $0 }),
                    range: 0...1.0,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorMix, value: cache.color.colorMix) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "number", label: "Iterations",
                    value: Binding(get: { cache.color.colorIterations }, set: { cache.color.colorIterations = $0 }),
                    range: 4...16,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorIterations, value: cache.color.colorIterations) },
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.indigo.opacity(0.06)))
        }
    }
}

// MARK: - Color Grading

struct ColorGradingView: View {
    var cache: UISettingsCache
    @State private var showShadowsHighlights = false

    var body: some View {
        VStack(spacing: 12) {
            Label("Color Grading", systemImage: "camera.filters").font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Tone controls (always visible)
            VStack(spacing: 4) {
                EffectSliderRow(icon: "circle.lefthalf.filled", label: "Contrast",
                    value: Binding(get: { cache.color.colorSchemeContrast }, set: { cache.color.colorSchemeContrast = $0 }),
                    range: 0.95...1.15,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeContrast, value: cache.color.colorSchemeContrast) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "paintpalette.fill", label: "Vibrance",
                    value: Binding(get: { cache.color.colorSchemeVibrance }, set: { cache.color.colorSchemeVibrance = $0 }),
                    range: 0...1.0,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeVibrance, value: cache.color.colorSchemeVibrance) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "waveform.path", label: "Midtone Curve",
                    value: Binding(get: { cache.color.colorSchemeCurve }, set: { cache.color.colorSchemeCurve = $0 }),
                    range: -1.0...1.0,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeCurve, value: cache.color.colorSchemeCurve) },
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.06)))

            // Shadows & Highlights (collapsed by default)
            DisclosureGroup(isExpanded: $showShadowsHighlights) {
                VStack(spacing: 4) {
                    EffectSliderRow(icon: "shadow", label: "Shadows",
                        value: Binding(get: { cache.color.colorSchemeShadows }, set: { cache.color.colorSchemeShadows = $0 }),
                        range: -0.05...0.05,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.colorSchemeShadows, value: cache.color.colorSchemeShadows) },
                        showToggle: false)
                    Divider().padding(.leading, 159)
                    EffectSliderRow(icon: "sun.max.fill", label: "Highlights",
                        value: Binding(get: { cache.color.colorSchemeHighlights }, set: { cache.color.colorSchemeHighlights = $0 }),
                        range: -0.5...1.0,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.colorSchemeHighlights, value: cache.color.colorSchemeHighlights) },
                        showToggle: false)
                }
                .padding(.top, 6)
            } label: {
                Label("Shadows & Highlights", systemImage: "sun.and.horizon")
                    .font(.subheadline.weight(.medium))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.06)))
        }
    }
}
