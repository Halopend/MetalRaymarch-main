//
//  RefiningView.swift
//  MetalRaymarch
//
//  Refining window for tuning sphere tracing optimization thresholds
//  Based on Polychronakis 2024 and Keinert 2014 papers
//

import SwiftUI

struct RefiningView: View {
    @Environment(AppModel.self) private var appModel
    
    var body: some View {
        VStack(spacing: 12) {
            Text("Refining Parameters")
                .font(.headline)
            
            Text("Sphere Tracing Optimization")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Divider()
            
            ScrollView {
                VStack(spacing: 16) {
                    // Over-relaxation (Keinert 2014)
                    Group {
                        Text("Over-Relaxation (Keinert 2014)")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Relax Factor: \(appModel.renderSettings.relaxFactor, specifier: "%.2f")")
                                .font(.caption)
                            Slider(value: Binding(
                                get: { appModel.renderSettings.relaxFactor },
                                set: { appModel.renderSettings.relaxFactor = $0 }
                            ), in: 1.0...2.0, step: 0.05)
                            Text("Higher = faster but may overshoot")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Backtrack Factor: \(appModel.renderSettings.relaxBacktrack, specifier: "%.2f")")
                                .font(.caption)
                            Slider(value: Binding(
                                get: { appModel.renderSettings.relaxBacktrack },
                                set: { appModel.renderSettings.relaxBacktrack = $0 }
                            ), in: 0.3...1.0, step: 0.05)
                            Text("Recovery when overshooting detected")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Divider()
                    
                    // SDF Scaling (Polychronakis 2024)
                    Group {
                        Text("SDF Scaling (Polychronakis 2024)")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Coarse Scale: \(appModel.renderSettings.sdfScaleCoarse, specifier: "%.2f")")
                                .font(.caption)
                            Slider(value: Binding(
                                get: { appModel.renderSettings.sdfScaleCoarse },
                                set: { appModel.renderSettings.sdfScaleCoarse = $0 }
                            ), in: 1.0...2.0, step: 0.05)
                            Text("SDF multiplier for coarse pass")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Super-Coarse Scale: \(appModel.renderSettings.sdfScaleSuperCoarse, specifier: "%.2f")")
                                .font(.caption)
                            Slider(value: Binding(
                                get: { appModel.renderSettings.sdfScaleSuperCoarse },
                                set: { appModel.renderSettings.sdfScaleSuperCoarse = $0 }
                            ), in: 1.0...2.5, step: 0.05)
                            Text("SDF multiplier for 8x8 tiles")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Divider()
                    
                    // Early Termination (Polychronakis 2024)
                    Group {
                        Text("Early Termination (Polychronakis 2024)")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Convergence Ratio: \(appModel.renderSettings.earlyTermRatio, specifier: "%.2f")")
                                .font(.caption)
                            Slider(value: Binding(
                                get: { appModel.renderSettings.earlyTermRatio },
                                set: { appModel.renderSettings.earlyTermRatio = $0 }
                            ), in: 0.1...0.6, step: 0.02)
                            Text("Terminate if d_n/d_{n-1} < this")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Termination Count: \(appModel.renderSettings.earlyTermCount)")
                                .font(.caption)
                            Slider(value: Binding(
                                get: { Float(appModel.renderSettings.earlyTermCount) },
                                set: { appModel.renderSettings.earlyTermCount = Int($0) }
                            ), in: 1...6, step: 1)
                            Text("Slow steps before termination")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Divider()
                    
                    // Log button
                    Button(action: {
                        appModel.renderSettings.logRefiningValues()
                    }) {
                        Label("Log Current Values", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                    
                    // Reset button
                    Button(action: {
                        resetToDefaults()
                    }) {
                        Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
                .padding(.horizontal)
            }
            
            // FPS display
            Text("FPS: \(appModel.fps, specifier: "%.1f")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 280, maxWidth: 320)
    }
    
    private func resetToDefaults() {
        appModel.renderSettings.relaxFactor = 1.6
        appModel.renderSettings.relaxBacktrack = 0.7
        appModel.renderSettings.sdfScaleCoarse = 1.3
        appModel.renderSettings.sdfScaleSuperCoarse = 1.5
        appModel.renderSettings.earlyTermRatio = 0.3
        appModel.renderSettings.earlyTermCount = 3
        print("[REFINE] Reset to defaults")
        appModel.renderSettings.logRefiningValues()
    }
}

#Preview(windowStyle: .automatic) {
    RefiningView()
        .environment(AppModel())
}
