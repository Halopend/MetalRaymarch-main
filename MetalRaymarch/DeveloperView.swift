//
//  DeveloperView.swift
//  MetalRaymarch
//
//  Developer tools window for profiling and diagnostics
//

import SwiftUI

// Safe array subscript
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct DeveloperView: View {
    @Environment(AppModel.self) private var appModel
    @State private var isProfilerRunning = false
    @State private var lastProfileTime: Date?
    @State private var isTestAnimationPlaying = false
    
    // Theme color based on fractal color scheme
    private var themeColor: Color {
        switch appModel.renderSettings.colorScheme {
        case .classic: return Color(red: 0.8, green: 0.5, blue: 0.2)
        case .ocean: return Color(red: 0.1, green: 0.5, blue: 0.9)
        case .fire: return Color(red: 1.0, green: 0.4, blue: 0.1)
        case .forest: return Color(red: 0.2, green: 0.7, blue: 0.3)
        case .nebula: return Color(red: 0.6, green: 0.3, blue: 0.9)
        case .mono: return Color(red: 0.5, green: 0.5, blue: 0.55)
        case .aurora: return Color(red: 0.2, green: 0.9, blue: 0.6)
        case .volcanic: return Color(red: 0.9, green: 0.3, blue: 0.1)
        case .neonCyber: return Color(red: 1.0, green: 0.2, blue: 0.8)
        case .neonSunset: return Color(red: 1.0, green: 0.5, blue: 0.3)
        case .neonMatrix: return Color(red: 0.0, green: 1.0, blue: 0.4)
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header with theme color
                HStack {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.title2)
                        .foregroundStyle(themeColor)
                    Text("Developer Tools")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Spacer()
                }
                .padding(.bottom, 4)
                
                // Quality Settings Section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(themeColor)
                        Text("Quality Constraints")
                            .font(.headline)
                    }
                    
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Fractal Iterations")
                                Spacer()
                                Text("\(appModel.renderSettings.baseFractalIterations)")
                                    .fontWeight(.bold)
                                    .monospacedDigit()
                            }
                            Slider(value: Binding(
                                get: { Float(appModel.renderSettings.baseFractalIterations) },
                                set: { appModel.renderSettings.baseFractalIterations = Int($0) }
                            ), in: 4...32, step: 1)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Max Ray Steps")
                                Spacer()
                                Text("\(appModel.renderSettings.baseMaxRaySteps)")
                                    .fontWeight(.bold)
                                    .monospacedDigit()
                            }
                            Slider(value: Binding(
                                get: { Float(appModel.renderSettings.baseMaxRaySteps) },
                                set: { appModel.renderSettings.baseMaxRaySteps = Int($0) }
                            ), in: 32...1024, step: 16)
                        }
                        
                        Divider()
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Quality Floor (Min)")
                                Spacer()
                                Text(String(format: "%.0f%%", appModel.renderSettings.dynamicRenderQualityMin * 100))
                                    .fontWeight(.bold)
                            }
                            Slider(value: Binding(
                                get: { appModel.renderSettings.dynamicRenderQualityMin },
                                set: { appModel.renderSettings.dynamicRenderQualityMin = $0 }
                            ), in: 0.1...0.8, step: 0.05)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Quality Ceiling (Max)")
                                Spacer()
                                Text(String(format: "%.0f%%", appModel.renderSettings.dynamicRenderQualityMax * 100))
                                    .fontWeight(.bold)
                            }
                            Slider(value: Binding(
                                get: { appModel.renderSettings.dynamicRenderQualityMax },
                                set: { appModel.renderSettings.dynamicRenderQualityMax = $0 }
                            ), in: 0.8...1.0, step: 0.05)
                        }
                    }
                    
                    Text("Quality ceiling limits how many resources are 'dedicated' when performance is high.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(themeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                
                // Pipeline Profiler Section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                            .foregroundStyle(themeColor)
                        Text("Pipeline Profiler")
                            .font(.headline)
                    }
                    
                    Text("Analyzes rendering costs by isolating SDF, normal calculation, and shading.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    HStack {
                        Button {
                            runProfiler()
                        } label: {
                            HStack {
                                if isProfilerRunning {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(width: 16, height: 16)
                                } else {
                                    Image(systemName: "play.fill")
                                }
                                Text(isProfilerRunning ? "Profiling..." : "Run Profiler")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(themeColor)
                        .disabled(isProfilerRunning || appModel.immersiveSpaceState != .open)
                        
                        if appModel.immersiveSpaceState != .open {
                            Text("Requires immersive mode")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    if let time = lastProfileTime {
                        Text("Last run: \(time, style: .relative) ago")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(themeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                
                // Current Render Stats
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "chart.bar.fill")
                            .foregroundStyle(themeColor)
                        Text("Live Stats")
                            .font(.headline)
                    }
                    
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 8) {
                        StatBox(label: "FPS", value: String(format: "%.0f", appModel.fps), color: fpsColor)
                        StatBox(label: "Iterations", value: "\(appModel.renderSettings.fractalIterations)", color: themeColor)
                        StatBox(label: "Ray Steps", value: "\(appModel.renderSettings.maxRaySteps)", color: themeColor.opacity(0.8))
                        StatBox(label: "Scale", value: String(format: "%.2f", appModel.renderSettings.fractalScale), color: themeColor.opacity(0.6))
                    }
                }
                .padding()
                .background(themeColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                
                // Test Animation Section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "film.fill")
                            .foregroundStyle(themeColor)
                        Text("Animation Test")
                            .font(.headline)
                    }
                    
                    Text("Runs a test scene that sweeps through fractal parameters.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    HStack(spacing: 12) {
                        Button {
                            if isTestAnimationPlaying {
                                stopTestAnimation()
                            } else {
                                runTestAnimation()
                            }
                        } label: {
                            HStack {
                                Image(systemName: isTestAnimationPlaying ? "stop.fill" : "play.fill")
                                Text(isTestAnimationPlaying ? "Stop" : "Play Test")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(isTestAnimationPlaying ? .red : themeColor)
                        .disabled(appModel.immersiveSpaceState != .open)
                        
                        if let manager = appModel.animationManager, manager.isPlaying {
                            VStack(alignment: .leading) {
                                Text("KF \(manager.playhead.currentKeyframeIndex + 1)")
                                    .font(.caption.monospacedDigit())
                                ProgressView(value: Double(manager.playhead.elapsedInSegment), 
                                           total: manager.currentScene?.keyframes[safe: manager.playhead.currentKeyframeIndex + 1]?.duration ?? 1.0)
                                    .tint(themeColor)
                            }
                            .frame(width: 80)
                        }
                    }
                    
                    if appModel.immersiveSpaceState != .open {
                        Text("Requires immersive mode")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(themeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                
                // Footer hint
                Text("Profiler results output to Xcode console")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(width: 380, height: 480)
        .onAppear {
            appModel.isDeveloperWindowVisible = true
        }
        .onDisappear {
            appModel.isDeveloperWindowVisible = false
        }
    }
    
    private var fpsColor: Color {
        if appModel.fps >= 85 { return .green }
        if appModel.fps >= 60 { return .yellow }
        return .red
    }
    
    private func runProfiler() {
        isProfilerRunning = true
        appModel.runProfiler()
        
        // The profiler runs synchronously on the render thread,
        // so we can mark completion after a short delay
        Task {
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run {
                isProfilerRunning = false
                lastProfileTime = Date()
            }
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // TEST ANIMATION
    // ═══════════════════════════════════════════════════════════════════════════
    
    private func runTestAnimation() {
        guard let manager = appModel.animationManager else { return }
        
        // Create a test scene with interesting parameter sweeps
        let currentPos = appModel.renderSettings.position
        
        let testScene = createTestScene(startPosition: currentPos)
        
        // Inject and play
        manager.currentScene = testScene
        manager.play()
        isTestAnimationPlaying = true
        
        print("🎬 Started test animation")
    }
    
    private func stopTestAnimation() {
        appModel.animationManager?.stop()
        isTestAnimationPlaying = false
        print("🎬 Stopped test animation")
    }
    
    /// Creates a test scene demonstrating parameter animation
    private func createTestScene(startPosition: SIMD3<Float>) -> AnimationScene {
        var scene = AnimationScene(name: "Dev Test")
        scene.isLooping = true
        
        // Keyframe 1: Starting state (duration 0 - this is the starting point)
        scene.keyframes.append(AnimationKeyframe(
            name: "Start",
            duration: 0,
            minDistance: 0.8,
            foldingLimit: 1.0,
            sphereRadius: 0.5,
            fractalScale: 2.8,
            position: startPosition
        ))
        
        // Keyframe 2: Open up - more porous (2 seconds)
        scene.keyframes.append(AnimationKeyframe(
            name: "Open",
            duration: 2.0,
            minDistance: 2.0,
            foldingLimit: 3.0,
            sphereRadius: 0.8,
            fractalScale: 2.5,
            position: startPosition + SIMD3<Float>(0.1, 0, 0)
        ))
        
        // Keyframe 3: Tight and dense (2 seconds)
        scene.keyframes.append(AnimationKeyframe(
            name: "Tight",
            duration: 2.0,
            minDistance: 0.5,
            foldingLimit: 0.8,
            sphereRadius: 0.3,
            fractalScale: 3.2,
            position: startPosition + SIMD3<Float>(0, 0.1, 0)
        ))
        
        // Keyframe 4: Wild scale (2 seconds)
        scene.keyframes.append(AnimationKeyframe(
            name: "Wild",
            duration: 2.0,
            minDistance: 1.5,
            foldingLimit: 5.0,
            sphereRadius: 1.2,
            fractalScale: 2.2,
            position: startPosition + SIMD3<Float>(-0.1, 0, 0.1)
        ))
        
        // Keyframe 5: Return to start (2 seconds)
        scene.keyframes.append(AnimationKeyframe(
            name: "Return",
            duration: 2.0,
            minDistance: 0.8,
            foldingLimit: 1.0,
            sphereRadius: 0.5,
            fractalScale: 2.8,
            position: startPosition
        ))
        
        return scene
    }
}

// MARK: - Supporting Views

struct StatBox: View {
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.monospacedDigit())
                .fontWeight(.semibold)
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    DeveloperView()
        .environment(AppModel())
}
