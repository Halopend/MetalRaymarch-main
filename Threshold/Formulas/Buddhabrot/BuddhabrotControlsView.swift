//
//  BuddhabrotControlsView.swift
//  Threshold
//
//  SwiftUI controls for the 3D Buddhabrot volume renderer.
//  Exposes iteration bands, density/gamma scaling, palette colors,
//  ray march quality, and volume placement parameters.
//

import SwiftUI

struct BuddhabrotControlsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let settings = appModel.buddhabrotSettings

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // MARK: - Header
                HStack {
                    Label("Buddhabrot", systemImage: "atom")
                        .font(.title2.bold())
                    Spacer()
                    Button {
                        appModel.runtimeViewMode = .raymarch
                    } label: {
                        Label("Back to Fractal", systemImage: "arrow.left")
                    }
                    .buttonStyle(.bordered)
                }
                
                Divider()
                
                // MARK: - Render Mode
                GroupBox("Render Mode") {
                    Picker("", selection: Binding(
                        get: { settings.renderMode },
                        set: { settings.renderMode = $0; settings.needsClear = true }
                    )) {
                        ForEach(BuddhabrotRenderMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                // MARK: - Accumulation Stats
                GroupBox("Accumulation") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Samples: \(formatLargeNumber(settings.totalSamplesAccumulated))")
                            .font(.caption.monospacedDigit())
                        
                        if settings.renderMode == .volumeRayMarch {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Volume Resolution")
                                    .font(.subheadline)
                                Picker("", selection: Binding(
                                    get: { settings.resolution },
                                    set: { newVal in
                                        settings.resolution = newVal
                                        settings.needsClear = true
                                    }
                                )) {
                                    Text("64³").tag(64)
                                    Text("128³").tag(128)
                                    Text("192³").tag(192)
                                    Text("256³").tag(256)
                                    Text("512³").tag(512)
                                    Text("756³").tag(756)
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        
                        if settings.renderMode == .gaussianSplats {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Max Splats")
                                    .font(.subheadline)
                                Picker("", selection: Binding(
                                    get: { settings.maxSplatCount },
                                    set: { settings.maxSplatCount = $0; settings.needsClear = true }
                                )) {
                                    Text("64K").tag(65_536)
                                    Text("128K").tag(131_072)
                                    Text("256K").tag(262_144)
                                    Text("512K").tag(524_288)
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        
                        Button("Clear & Restart") {
                            settings.needsClear = true
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
                
                // MARK: - Mandelbulb Parameters
                GroupBox("Mandelbulb") {
                    VStack(alignment: .leading, spacing: 8) {
                        SliderRow(label: "Power", value: Binding(
                            get: { settings.power },
                            set: { settings.power = $0; settings.needsClear = true }
                        ), range: 2...16, format: "%.1f")
                        
                        SliderRow(label: "Max Iterations", value: Binding(
                            get: { Float(settings.maxIterations) },
                            set: { settings.maxIterations = Int($0); settings.needsClear = true }
                        ), range: 10...500, format: "%.0f")
                        
                        SliderRow(label: "Bailout Radius", value: Binding(
                            get: { settings.bailoutRadius },
                            set: { settings.bailoutRadius = $0; settings.needsClear = true }
                        ), range: 2...20, format: "%.1f")
                        
                        SliderRow(label: "World Extent", value: Binding(
                            get: { settings.worldExtent },
                            set: { settings.worldExtent = $0; settings.needsClear = true }
                        ), range: 0.5...4.0, format: "%.2f")
                    }
                }
                
                // MARK: - Performance
                GroupBox("Performance") {
                    VStack(alignment: .leading, spacing: 8) {
                        SliderRow(label: "Batch Size", value: Binding(
                            get: { Float(settings.batchSize) },
                            set: { settings.batchSize = Int($0) }
                        ), range: 4096...262144, format: "%.0f")
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Batches Per Frame")
                                .font(.subheadline)
                            Picker("", selection: Binding(
                                get: { settings.batchesPerFrame },
                                set: { settings.batchesPerFrame = $0 }
                            )) {
                                Text("1").tag(1)
                                Text("2").tag(2)
                                Text("4").tag(4)
                                Text("8").tag(8)
                            }
                            .pickerStyle(.segmented)
                        }
                        
                        if settings.renderMode == .volumeRayMarch {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Normalize Every (frames)")
                                    .font(.subheadline)
                                Picker("", selection: Binding(
                                    get: { settings.normalizationInterval },
                                    set: { settings.normalizationInterval = $0 }
                                )) {
                                    Text("1").tag(1)
                                    Text("2").tag(2)
                                    Text("4").tag(4)
                                    Text("8").tag(8)
                                }
                                .pickerStyle(.segmented)
                            }
                            
                            Toggle("RGB Nebulabrot Mode", isOn: Binding(
                                get: { settings.useRGBMode },
                                set: { settings.useRGBMode = $0; settings.needsClear = true }
                            ))
                        }
                    }
                }
                
                // MARK: - Appearance (mode-specific)
                if settings.renderMode == .gaussianSplats {
                    GroupBox("Splat Appearance") {
                        VStack(alignment: .leading, spacing: 8) {
                            SliderRow(label: "Scale (Tangent)", value: Binding(
                                get: { settings.splatScaleAlongTangent },
                                set: { settings.splatScaleAlongTangent = $0 }
                            ), range: 0.005...0.2, format: "%.3f")
                            
                            SliderRow(label: "Scale (Perp)", value: Binding(
                                get: { settings.splatScalePerp },
                                set: { settings.splatScalePerp = $0 }
                            ), range: 0.005...0.2, format: "%.3f")
                            
                            SliderRow(label: "Opacity", value: Binding(
                                get: { settings.splatOpacity },
                                set: { settings.splatOpacity = $0 }
                            ), range: 0.01...1.0, format: "%.2f")
                            
                            SliderRow(label: "Brightness", value: Binding(
                                get: { settings.brightnessScale },
                                set: { settings.brightnessScale = $0 }
                            ), range: 0.1...5.0, format: "%.2f")
                        }
                    }
                } else {
                    GroupBox("Appearance") {
                        VStack(alignment: .leading, spacing: 8) {
                            SliderRow(label: "Density Scale", value: Binding(
                                get: { settings.densityScale },
                                set: { settings.densityScale = $0 }
                            ), range: 0.01...10.0, format: "%.2f")
                            
                            SliderRow(label: "Gamma", value: Binding(
                                get: { settings.gamma },
                                set: { settings.gamma = $0 }
                            ), range: 0.1...2.0, format: "%.2f")
                            
                            SliderRow(label: "Opacity", value: Binding(
                                get: { settings.alphaScale },
                                set: { settings.alphaScale = $0 }
                            ), range: 0.5...30.0, format: "%.1f")
                        }
                    }
                    
                    GroupBox("Ray March") {
                        VStack(alignment: .leading, spacing: 8) {
                            SliderRow(label: "Steps", value: Binding(
                                get: { Float(settings.maxRaySteps) },
                                set: { settings.maxRaySteps = Int($0) }
                            ), range: 32...192, format: "%.0f")
                            
                            SliderRow(label: "Early Exit Alpha", value: Binding(
                                get: { settings.earlyExitAlpha },
                                set: { settings.earlyExitAlpha = $0 }
                            ), range: 0.5...1.0, format: "%.2f")
                        }
                    }
                }
                
                // MARK: - Volume Placement
                GroupBox("Volume Placement") {
                    VStack(alignment: .leading, spacing: 8) {
                        SliderRow(label: "Distance", value: Binding(
                            get: { settings.volumeDistance },
                            set: { settings.volumeDistance = $0 }
                        ), range: 0.5...5.0, format: "%.1f m")
                        
                        SliderRow(label: "Scale", value: Binding(
                            get: { settings.volumeScale },
                            set: { settings.volumeScale = $0 }
                        ), range: 0.1...3.0, format: "%.2f m")
                        
                        Toggle("Auto Rotate", isOn: Binding(
                            get: { settings.autoRotate },
                            set: { settings.autoRotate = $0 }
                        ))
                        
                        if settings.autoRotate {
                            SliderRow(label: "Rotation Speed", value: Binding(
                                get: { settings.rotationSpeed },
                                set: { settings.rotationSpeed = $0 }
                            ), range: 0.01...1.0, format: "%.2f")
                        }
                    }
                }
            }
            .padding()
        }
    }
    
    // MARK: - Helpers
    
    private func formatLargeNumber(_ n: UInt64) -> String {
        if n >= 1_000_000_000 {
            return String(format: "%.2f B", Double(n) / 1_000_000_000)
        } else if n >= 1_000_000 {
            return String(format: "%.2f M", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.1f K", Double(n) / 1_000)
        }
        return "\(n)"
    }
}

// MARK: - Reusable Slider Row

private struct SliderRow: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(String(format: format, value))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Slider(value: $value, in: range)
        }
        .padding(.vertical, 2)
    }
}
