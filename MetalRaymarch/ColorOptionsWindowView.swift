//
//  ColorOptionsWindowView.swift
//  MetalRaymarch
//
//  Dedicated window for gradient coloring, color grading, and color controls.
//  Opened from the top bar color button in ContentView.
//

import SwiftUI

struct ColorOptionsWindowView: View {
    @Environment(AppModel.self) private var appModel
    @State private var cache = UISettingsCache()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Color Options", systemImage: "paintpalette.fill")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)
            
            Divider()
            
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    // === GRADIENT COLORING SYSTEM ===
                    gradientSection
                    
                    Divider()
                    
                    // === COLOR GRADING ===
                    colorGradingSection
                    
                    Divider()
                    
                    // === COLOR MIX & ITERATIONS ===
                    colorMixSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .frame(minHeight: 400)
        .opacity(0.9)
        .glassBackgroundEffect(in: .rect(cornerRadius: 20))
        .onAppear {
            cache.startSync(with: appModel.renderSettings)
        }
        .onDisappear {
            cache.stopSync()
        }
    }
    
    // MARK: - Gradient Section
    
    private var gradientSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gradient Coloring")
                .font(.headline)
            
            // Gradient preview bar
            GradientPreviewBar(gradient: cache.gradientColorMap)
                .frame(height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            
            // Preset picker
            Text("Presets").font(.subheadline).foregroundColor(.secondary)
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 6) {
                ForEach(GradientPreset.allCases, id: \.rawValue) { preset in
                    Button {
                        cache.applyGradientPreset(preset)
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: preset.icon)
                                .font(.caption)
                            Text(preset.displayName)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(cache.gradientPreset == preset ? .blue : .secondary)
                }
            }
            
            Divider()
            
            // Mapping mode
            HStack {
                Text("Mapping")
                Spacer()
                Picker("Mapping", selection: $cache.colorMappingMode) {
                    ForEach(ColorMappingMode.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 140)
                .onChange(of: cache.colorMappingMode) { _, newValue in
                    cache.push(\.colorMappingMode, value: newValue)
                }
            }
            
            // Repeat
            HStack {
                Text("Repeat: \(cache.gradientRepeat, specifier: "%.1f")x")
                Spacer()
            }
            Slider(value: $cache.gradientRepeat, in: 0.1...5.0, onEditingChanged: { editing in
                if !editing { cache.push(\.gradientRepeat, value: cache.gradientRepeat) }
            })
            
            // Offset
            HStack {
                Text("Offset: \(cache.gradientOffset, specifier: "%.2f")")
                Spacer()
            }
            Slider(value: $cache.gradientOffset, in: 0...1, onEditingChanged: { editing in
                if !editing { cache.push(\.gradientOffset, value: cache.gradientOffset) }
            })
            
            // Smoothing
            HStack {
                Text("Smoothing: \(cache.gradientSmoothing, specifier: "%.2f")")
                Spacer()
            }
            Slider(value: $cache.gradientSmoothing, in: 0...1, onEditingChanged: { editing in
                if !editing { cache.push(\.gradientSmoothing, value: cache.gradientSmoothing) }
            })
            
            Divider()
            
            // Color stops editor
            HStack {
                Text("Color Stops").font(.subheadline)
                Spacer()
                Button {
                    addStop()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.caption)
                }
                .disabled(cache.gradientColorMap.stops.count >= 8)
            }
            
            ForEach(Array(cache.gradientColorMap.stops.enumerated()), id: \.element.id) { index, stop in
                GradientStopRow(
                    stop: stop,
                    index: index,
                    onUpdate: { updatedStop in
                        updateStop(at: index, with: updatedStop)
                    },
                    onDelete: {
                        deleteStop(at: index)
                    },
                    canDelete: cache.gradientColorMap.stops.count > 2
                )
            }
        }
    }
    
    // MARK: - Color Grading Section
    
    private var colorGradingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Color Grading").font(.headline)
            
            // Contrast
            Text("Contrast: \(cache.colorSchemeContrast, specifier: "%.2f")")
            Slider(value: $cache.colorSchemeContrast, in: 0.95...1.15, onEditingChanged: { editing in
                if !editing { cache.push(\.colorSchemeContrast, value: cache.colorSchemeContrast) }
            })
            
            Divider()
            
            Text("Color Grading Curves").font(.subheadline).foregroundColor(.secondary)
            
            Text("Vibrance: \(cache.colorSchemeVibrance, specifier: "%.2f")")
            Slider(value: $cache.colorSchemeVibrance, in: 0...1.0, onEditingChanged: { editing in
                if !editing { cache.push(\.colorSchemeVibrance, value: cache.colorSchemeVibrance) }
            })
            
            Text("Midtone Curve: \(cache.colorSchemeCurve, specifier: "%.2f")")
            Slider(value: $cache.colorSchemeCurve, in: -1.0...1.0, onEditingChanged: { editing in
                if !editing { cache.push(\.colorSchemeCurve, value: cache.colorSchemeCurve) }
            })
            
            Text("Shadows: \(cache.colorSchemeShadows, specifier: "%.3f")")
            Slider(value: $cache.colorSchemeShadows, in: -0.05...0.05, onEditingChanged: { editing in
                if !editing { cache.push(\.colorSchemeShadows, value: cache.colorSchemeShadows) }
            })
            
            Text("Highlights: \(cache.colorSchemeHighlights, specifier: "%.2f")")
            Slider(value: $cache.colorSchemeHighlights, in: -0.5...1.0, onEditingChanged: { editing in
                if !editing { cache.push(\.colorSchemeHighlights, value: cache.colorSchemeHighlights) }
            })
        }
    }
    
    // MARK: - Color Mix Section
    
    private var colorMixSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Color Blend").font(.headline)
            
            Text("Color Mix")
            Slider(value: $cache.colorMix, in: 0...1.0, onEditingChanged: { editing in
                if !editing { cache.push(\.colorMix, value: cache.colorMix) }
            })
            
            Text("Color Iterations: \(cache.colorIterations, specifier: "%.0f")")
            Slider(value: $cache.colorIterations, in: 4...16, step: 1, onEditingChanged: { editing in
                if !editing { cache.push(\.colorIterations, value: cache.colorIterations) }
            })
        }
    }
    
    // MARK: - Gradient Helpers
    
    private func addStop() {
        var map = cache.gradientColorMap
        let newPos: Float = 0.5
        let newStop = GradientStop(position: newPos, r: 1.0, g: 1.0, b: 1.0)
        map.stops.append(newStop)
        map.sortStops()
        cache.gradientColorMap = map
        cache.pushGradientMap(map)
    }
    
    private func updateStop(at index: Int, with stop: GradientStop) {
        var map = cache.gradientColorMap
        guard index < map.stops.count else { return }
        map.stops[index] = stop
        map.sortStops()
        cache.gradientColorMap = map
        cache.pushGradientMap(map)
    }
    
    private func deleteStop(at index: Int) {
        var map = cache.gradientColorMap
        guard map.stops.count > 2, index < map.stops.count else { return }
        map.stops.remove(at: index)
        cache.gradientColorMap = map
        cache.pushGradientMap(map)
    }
}
