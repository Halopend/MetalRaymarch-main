//
//  DeveloperToolsView.swift
//  Threshold
//
//  Extracted from ContentView: Advanced/developer settings —
//  quality constraints, pipeline profiler, live stats, animation test, benchmarking.
//

import SwiftUI

struct DeveloperToolsView: View {
    @Environment(AppModel.self) private var appModel
    var cache: UISettingsCache
    var themeColor: Color

    @State private var isProfilerRunning = false
    @State private var lastProfileTime: Date?
    @State private var isTestAnimationPlaying = false
#if DEBUG
    @State private var isBenchmarking = false
#endif

    private var fpsColor: Color {
        let fps = cache.liveFPS
        if fps >= 85 { return .green }; if fps >= 60 { return .yellow }; return .red
    }

    var body: some View {
        VStack(spacing: 16) {
            // ── Quality Constraints ──
            VStack(alignment: .leading, spacing: 12) {
                HStack { Image(systemName: "slider.horizontal.3").foregroundStyle(themeColor); Text("Quality Constraints").font(.headline) }
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Fractal Iterations"); Spacer(); Text("\(cache.quality.baseFractalIterations)").fontWeight(.bold).monospacedDigit() }
                        Slider(value: Binding(
                            get: { Float(cache.quality.baseFractalIterations) },
                            set: { cache.quality.baseFractalIterations = Int($0); cache.push(\.baseFractalIterations, value: Int($0)) }
                        ), in: 4...32, step: 1)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Max Ray Steps"); Spacer(); Text("\(cache.quality.baseMaxRaySteps)").fontWeight(.bold).monospacedDigit() }
                        Slider(value: Binding(
                            get: { Float(cache.quality.baseMaxRaySteps) },
                            set: { cache.quality.baseMaxRaySteps = Int($0); cache.push(\.baseMaxRaySteps, value: Int($0)) }
                        ), in: 32...1024, step: 16)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Quality Floor (Min)"); Spacer(); Text(String(format: "%.0f%%", cache.quality.dynamicRenderQualityMin * 100)).fontWeight(.bold) }
                        Slider(value: Binding(
                            get: { cache.quality.dynamicRenderQualityMin },
                            set: { cache.quality.dynamicRenderQualityMin = $0 }
                        ), in: 0.1...0.8, step: 0.05, onEditingChanged: { e in
                            if !e { cache.push(\.dynamicRenderQualityMin, value: cache.quality.dynamicRenderQualityMin) }
                        })
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Quality Ceiling (Max)"); Spacer(); Text(String(format: "%.0f%%", cache.quality.dynamicRenderQualityMax * 100)).fontWeight(.bold) }
                        Slider(value: Binding(
                            get: { cache.quality.dynamicRenderQualityMax },
                            set: { cache.quality.dynamicRenderQualityMax = $0 }
                        ), in: 0.8...1.0, step: 0.05, onEditingChanged: { e in
                            if !e { cache.push(\.dynamicRenderQualityMax, value: cache.quality.dynamicRenderQualityMax) }
                        })
                    }
                    Toggle("Recreate Legacy Compute Cache Bug", isOn: Binding(
                        get: { cache.quality.recreateLegacyComputeCacheBug },
                        set: {
                            cache.quality.recreateLegacyComputeCacheBug = $0
                            cache.push(\.recreateLegacyComputeCacheBug, value: $0)
                        }
                    ))
                    Text("Uses nearest cached compute pipeline even when FI/RS mismatch, reproducing the old artifact look.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }.padding().background(themeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

            // ── Pipeline Profiler ──
            VStack(alignment: .leading, spacing: 8) {
                HStack { Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(themeColor); Text("Pipeline Profiler").font(.headline) }
                HStack {
                    Button {
                        isProfilerRunning = true; appModel.runProfiler()
                        Task { try? await Task.sleep(for: .seconds(3)); await MainActor.run { isProfilerRunning = false; lastProfileTime = Date() } }
                    } label: {
                        HStack {
                            if isProfilerRunning { ProgressView().scaleEffect(0.7).frame(width: 16, height: 16) } else { Image(systemName: "play.fill") }
                            Text(isProfilerRunning ? "Profiling..." : "Run Profiler")
                        }
                    }.buttonStyle(.borderedProminent).tint(themeColor).disabled(isProfilerRunning)
                }
            }.padding().background(themeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

            // ── Live Stats ──
            VStack(alignment: .leading, spacing: 8) {
                HStack { Image(systemName: "chart.bar.fill").foregroundStyle(themeColor); Text("Live Stats").font(.headline) }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    StatBox(label: "FPS", value: String(format: "%.0f", cache.liveFPS), color: fpsColor)
                    StatBox(label: "Iterations", value: "\(cache.liveFractalIterations)", color: themeColor)
                    StatBox(label: "Ray Steps", value: "\(cache.liveMaxRaySteps)", color: themeColor.opacity(0.8))
                    StatBox(label: "Scale", value: String(format: "%.2f", cache.liveFractalScale), color: themeColor.opacity(0.6))
                }
            }.padding().background(themeColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))

            // ── Animation Test ──
            VStack(alignment: .leading, spacing: 8) {
                HStack { Image(systemName: "film.fill").foregroundStyle(themeColor); Text("Animation Test").font(.headline) }
                Button {
                    if isTestAnimationPlaying { appModel.animationManager?.stop(); isTestAnimationPlaying = false }
                    else if let mgr = appModel.animationManager {
                        mgr.currentScene = AdvancedTestScene.create(startPosition: cache.livePosition)
                        mgr.play(); isTestAnimationPlaying = true
                    }
                } label: {
                    HStack { Image(systemName: isTestAnimationPlaying ? "stop.fill" : "play.fill"); Text(isTestAnimationPlaying ? "Stop" : "Play Test") }
                }.buttonStyle(.borderedProminent).tint(isTestAnimationPlaying ? .red : themeColor)
            }.padding().background(themeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

#if DEBUG
            // ── Benchmarking ──
            VStack(alignment: .leading, spacing: 8) {
                HStack { Image(systemName: "timer").foregroundStyle(themeColor); Text("Benchmarking").font(.headline) }
                HStack {
                    Button {
                        isBenchmarking.toggle()
                        BenchmarkManager.shared.toggleBenchmarking()
                    } label: {
                        HStack {
                            Image(systemName: isBenchmarking ? "stop.circle.fill" : "play.circle.fill")
                            Text(isBenchmarking ? "Stop Benchmarking" : "Start Benchmarking")
                        }
                    }.buttonStyle(.borderedProminent).tint(isBenchmarking ? .red : themeColor)

                    if !isBenchmarking {
                        Button {
                            BenchmarkManager.shared.clearStats()
                        } label: {
                            Text("Clear Stats")
                        }.buttonStyle(.bordered)
                    }
                }
                Text("Check Xcode console for results.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }.padding().background(themeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
#endif
        }
    }
}
