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
    @State private var showStopsPopover = false
    
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
                    
                    // === MAPPING & GRADIENT CONTROLS ===
                    mappingSection
                    
                    Divider()
                    
                    // === COLOR GRADING ===
                    colorGradingSection
                    
                    Divider()
                    
                    // === COLOR BLEND ===
                    colorBlendSection
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
            
            // Gradient preview bar — tap to edit stops
            GradientPreviewBar(gradient: cache.gradientColorMap)
                .frame(height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture {
                    showStopsPopover = true
                }
                .popover(isPresented: $showStopsPopover, arrowEdge: .bottom) {
                    GradientStopsPopover(cache: $cache)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                )
                .help("Tap to edit color stops")
            
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
            
        }
    }
    
    // MARK: - Mapping Section
    
    private var mappingSection: some View {
        DisclosureGroup("Mapping & Gradient Controls") {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    // Left column
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Mode")
                            Spacer()
                            Picker("Mapping", selection: $cache.colorMappingMode) {
                                ForEach(ColorMappingMode.allCases, id: \.rawValue) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 120)
                            .onChange(of: cache.colorMappingMode) { _, newValue in
                                cache.push(\.colorMappingMode, value: newValue)
                            }
                        }
                        
                        Text("Repeat: \(cache.gradientRepeat, specifier: "%.1f")x")
                            .font(.caption)
                        Slider(value: $cache.gradientRepeat, in: 0.1...5.0, onEditingChanged: { editing in
                            if !editing { cache.push(\.gradientRepeat, value: cache.gradientRepeat) }
                        })
                    }
                    .frame(maxWidth: .infinity)
                    
                    // Right column
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Offset: \(cache.gradientOffset, specifier: "%.2f")")
                            .font(.caption)
                        Slider(value: $cache.gradientOffset, in: 0...1, onEditingChanged: { editing in
                            if !editing { cache.push(\.gradientOffset, value: cache.gradientOffset) }
                        })
                        
                        Text("Smoothing: \(cache.gradientSmoothing, specifier: "%.2f")")
                            .font(.caption)
                        Slider(value: $cache.gradientSmoothing, in: 0...1, onEditingChanged: { editing in
                            if !editing { cache.push(\.gradientSmoothing, value: cache.gradientSmoothing) }
                        })
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 4)
        }
    }
    
    // MARK: - Color Grading Section
    
    private var colorGradingSection: some View {
        DisclosureGroup("Color Grading") {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    // Left column
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Contrast: \(cache.colorSchemeContrast, specifier: "%.2f")")
                            .font(.caption)
                        Slider(value: $cache.colorSchemeContrast, in: 0.95...1.15, onEditingChanged: { editing in
                            if !editing { cache.push(\.colorSchemeContrast, value: cache.colorSchemeContrast) }
                        })
                        
                        Text("Vibrance: \(cache.colorSchemeVibrance, specifier: "%.2f")")
                            .font(.caption)
                        Slider(value: $cache.colorSchemeVibrance, in: 0...1.0, onEditingChanged: { editing in
                            if !editing { cache.push(\.colorSchemeVibrance, value: cache.colorSchemeVibrance) }
                        })
                        
                        Text("Midtone Curve: \(cache.colorSchemeCurve, specifier: "%.2f")")
                            .font(.caption)
                        Slider(value: $cache.colorSchemeCurve, in: -1.0...1.0, onEditingChanged: { editing in
                            if !editing { cache.push(\.colorSchemeCurve, value: cache.colorSchemeCurve) }
                        })
                    }
                    .frame(maxWidth: .infinity)
                    
                    // Right column
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Shadows: \(cache.colorSchemeShadows, specifier: "%.3f")")
                            .font(.caption)
                        Slider(value: $cache.colorSchemeShadows, in: -0.05...0.05, onEditingChanged: { editing in
                            if !editing { cache.push(\.colorSchemeShadows, value: cache.colorSchemeShadows) }
                        })
                        
                        Text("Highlights: \(cache.colorSchemeHighlights, specifier: "%.2f")")
                            .font(.caption)
                        Slider(value: $cache.colorSchemeHighlights, in: -0.5...1.0, onEditingChanged: { editing in
                            if !editing { cache.push(\.colorSchemeHighlights, value: cache.colorSchemeHighlights) }
                        })
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 4)
        }
    }
    
    // MARK: - Color Blend Section
    
    private var colorBlendSection: some View {
        DisclosureGroup("Color Blend") {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    // Left column
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Color Mix: \(cache.colorMix, specifier: "%.2f")")
                            .font(.caption)
                        Slider(value: $cache.colorMix, in: 0...1.0, onEditingChanged: { editing in
                            if !editing { cache.push(\.colorMix, value: cache.colorMix) }
                        })
                    }
                    .frame(maxWidth: .infinity)
                    
                    // Right column
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Color Iterations: \(cache.colorIterations, specifier: "%.0f")")
                            .font(.caption)
                        Slider(value: $cache.colorIterations, in: 4...16, step: 1, onEditingChanged: { editing in
                            if !editing { cache.push(\.colorIterations, value: cache.colorIterations) }
                        })
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 4)
        }
    }
}
