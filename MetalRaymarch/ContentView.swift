//
//  ContentView.swift
//  MetalProject
//
//  Created by MU on 18/11/24.
//

import SwiftUI
import RealityKit

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    
    @State private var speed: Float = 0
    @State private var initialPosition: SIMD3<Float> = .zero
    @State private var initialScale: Float = 1.0
    @State private var cameraMode: Bool = false
    
    /// Get parameter ranges for current fractal type
    private var parameterRanges: (minDistance: ClosedRange<Float>, foldingLimit: ClosedRange<Float>, sphereRadius: ClosedRange<Float>) {
        appModel.gestureController?.getParameterRanges() ?? (0.1...5.0, 0.1...13.0, 0.1...2.0)
    }

    var body: some View {
        @Bindable var appModel = appModel

        ZStack {
            // Main content
            VStack {
                // Recording indicator at top center
                if let recorder = appModel.parameterRecorder {
                    if recorder.isRecording {
                        RecordingIndicatorView(recorder: recorder)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                            .padding(.top, 8)
                    } else if recorder.isPlaying || recorder.isPaused {
                        PlaybackIndicatorView(recorder: recorder) {
                            recorder.stopPlayback()
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .padding(.top, 8)
                    }
                }
                
             
                // Menu content
                menuContent
                
                Spacer()
            }
            .animation(.easeInOut(duration: 0.3), value: appModel.isMenuWindowVisible)
            .animation(.easeInOut(duration: 0.2), value: appModel.parameterRecorder?.isRecording)
            .animation(.easeInOut(duration: 0.2), value: appModel.parameterRecorder?.isPlaying)
        }
        .padding(40)
        .gesture(
            TapGesture(count: 2)
                .onEnded {
                    cameraMode.toggle()
                }
        )
        .gesture(
            DragGesture()
                .onChanged { value in
                    let sensitivityXY: Float = 0.002
                    let sensitivityZ: Float = 0.004
                    if cameraMode {
                        // Dolly camera along Z with drag Y
                        let zDelta = -Float(value.translation.height) * sensitivityZ
                        var newPos = initialPosition
                        newPos.z += zDelta
                        appModel.renderSettings.targetPosition = newPos
                    } else {
                        let delta = SIMD3<Float>(Float(value.translation.width) * sensitivityXY, -Float(value.translation.height) * sensitivityXY, 0)
                        appModel.renderSettings.targetPosition = initialPosition + delta
                    }
                }
                .onEnded { _ in
                    initialPosition = appModel.renderSettings.targetPosition
                }
        )
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    let sensitivity: Float = 1.0
                    let zDelta = (Float(value.magnification) - 1.0) * sensitivity
                    var newPos = initialPosition
                    newPos.z += zDelta
                    appModel.renderSettings.targetPosition = newPos
                }
                .onEnded { _ in
                    initialPosition = appModel.renderSettings.targetPosition
                }
        )
        // Hide content when menu window is "closed" (preserves window position/size)
        .opacity(appModel.isMenuWindowVisible ? 1 : 0)
        .allowsHitTesting(appModel.isMenuWindowVisible)
        .background {
            if appModel.isMenuWindowVisible {
                Color.clear.glassBackgroundEffect()
            }
        }
    }
    
    // MARK: - Menu Content
    
    private var menuContent: some View {
        VStack {
            VStack(spacing: 10) {
                // Presets and Recordings buttons at the top
                HStack {
                    PresetButton(
                        presetManager: appModel.presetManager,
                        settings: appModel.renderSettings,
                        captureScreenshot: { await appModel.captureScreenshot() },
                        onLoadPreset: { preset in
                            preset.apply(to: appModel.renderSettings)
                            // Sync gesture controller to prevent jumps when gestures resume
                            appModel.gestureController?.syncWithSettings()
                        }
                    )
                    
                    if let recorder = appModel.parameterRecorder {
                        RecordingButton(recorder: recorder) { recording in
                            recorder.startPlayback(recording)
                        }
                    }
                    
                    Spacer()
                    
                    // Menu visibility hint
                    Text("👆 Middle→Palm: Toggle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
                
                // Resolution scale and upscaling controls removed to keep UI focused on native/foveated path.

                // Tile-based rendering mode (2x2 quad sharing shadows)
                HStack {
                    Text("Tile Mode:")
                    Picker("", selection: Binding(
                        get: { appModel.renderSettings.tileSize },
                        set: { appModel.renderSettings.tileSize = $0 }
                    )) {
                        Text("Off").tag(0)
                        Text("2×2").tag(2)
                        Text("8×8 Adaptive").tag(8)
                    }
                    .pickerStyle(.segmented)
                }

            }
            .padding(.bottom, 16)

            ToggleImmersiveSpaceButton()
            
            if appModel.immersiveSpaceState == .open {
                ScrollView {
                    VStack(spacing: 12) {
                        Divider()
                        Text("Animation speed (caution: motion sickness!)")

                        Slider(value: $speed, in: 0...2, onEditingChanged: { editing in
                            if !editing {
                                appModel.clock.speed = Double(speed)
                            }
                        })

                        // Fractal type picker
                        Group {
                            Text("Fractal Type")
                                .font(.headline)
                            
                            Picker("Fractal", selection: Binding(
                                get: { appModel.renderSettings.fractalType },
                                set: { newType in
                                    let oldType = appModel.renderSettings.fractalType
                                    appModel.renderSettings.fractalType = newType
                                    // Apply default parameters when switching fractal types
                                    if oldType != newType {
                                        appModel.gestureController?.applyFractalDefaults()
                                    }
                                }
                            )) {
                                Text("Mandelbox").tag(FractalType.mandelbox)
                                Text("Triforce").tag(FractalType.triforce)
                                Text("Neg. Mandelbox").tag(FractalType.negativeMandelbox)
                            }
                            .pickerStyle(.segmented)
                        }

                        // Quality preset picker
                        Group {
                            Text("Quality Preset")
                                .font(.headline)
                            
                            Picker("Quality", selection: Binding(
                                get: {
                                    QualityPreset.detect(
                                        fractalIterations: appModel.renderSettings.fractalIterations,
                                        raySteps: appModel.renderSettings.maxRaySteps
                                    ) ?? .mid
                                },
                                set: { preset in
                                    appModel.renderSettings.fractalIterations = preset.fractalIterations
                                    appModel.renderSettings.maxRaySteps = preset.raySteps
                                }
                            )) {
                                ForEach(QualityPreset.allCases, id: \.self) { preset in
                                    Text(preset.rawValue).tag(preset)
                                }
                            }
                            .pickerStyle(.segmented)
                            
                            // Show current values
                            HStack {
                                Text("FI: \(appModel.renderSettings.fractalIterations)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("RI: \(appModel.renderSettings.maxRaySteps)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // Primary Parameter: Fractal Scale
                        Text("Fractal Scale")
                        Slider(value: Binding(get: { appModel.renderSettings.fractalScale }, set: { appModel.renderSettings.fractalScale = $0 }), in: 1.0...5.0)

                        // Shape Parameters Group - ranges adjust per fractal type
                        DisclosureGroup("Shape Parameters") {
                            VStack(spacing: 8) {
                                Text("Min Distance (\(String(format: "%.2f", appModel.renderSettings.targetMinDistance)))")
                                Slider(value: Binding(
                                    get: { appModel.renderSettings.targetMinDistance },
                                    set: { appModel.renderSettings.targetMinDistance = $0 }
                                ), in: parameterRanges.minDistance)

                                Text("Box Folding Limit (\(String(format: "%.2f", appModel.renderSettings.targetFoldingLimit)))")
                                Slider(value: Binding(
                                    get: { appModel.renderSettings.targetFoldingLimit },
                                    set: { appModel.renderSettings.targetFoldingLimit = $0 }
                                ), in: parameterRanges.foldingLimit)

                                Text("Sphere Radius (\(String(format: "%.2f", appModel.renderSettings.targetSphereRadius)))")
                                Slider(value: Binding(
                                    get: { appModel.renderSettings.targetSphereRadius },
                                    set: { appModel.renderSettings.targetSphereRadius = $0 }
                                ), in: parameterRanges.sphereRadius)
                            }
                            .padding(.leading, 10)
                        }

                        // Color & Glow Group
                        DisclosureGroup("Color & Glow") {
                            VStack(spacing: 8) {
                                HStack {
                                    Button {
                                        appModel.renderSettings.lightingPlay.toggle()
                                    } label: {
                                        Label(appModel.renderSettings.lightingPlay ? "Lighting: Playing" : "Lighting: Paused",
                                              systemImage: appModel.renderSettings.lightingPlay ? "play.fill" : "play")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    Spacer()
                                }

                                Text("Color Mix")
                                Slider(value: Binding(get: { appModel.renderSettings.colorMix }, set: { appModel.renderSettings.colorMix = $0 }), in: 0...1.0)

                                Text("Glow Intensity")
                                Slider(value: Binding(get: { appModel.renderSettings.glowIntensity }, set: { appModel.renderSettings.glowIntensity = $0 }), in: 0...2.0)

                                Text("Color Iterations: \(appModel.renderSettings.colorIterations, specifier: "%.0f")")
                                Slider(value: Binding(get: { appModel.renderSettings.colorIterations }, set: { appModel.renderSettings.colorIterations = $0 }), in: 4...16, step: 1)
                            }
                            .padding(.leading, 10)
                        }

                        // Foveation, Safety & Debug Group
                        DisclosureGroup("Safety & Render Options") {
                            VStack(spacing: 8) {
                                Toggle("Show HUD", isOn: Binding(get: { appModel.renderSettings.showHUD }, set: { appModel.renderSettings.showHUD = $0 }))

                                Toggle("Safety Bubble", isOn: Binding(get: { appModel.renderSettings.safetyBubbleEnabled }, set: { appModel.renderSettings.safetyBubbleEnabled = $0 }))

                                Text("Safety Bubble Radius: \(appModel.renderSettings.safetyBubbleRadius, specifier: "%.2f")m")
                                Slider(value: Binding(get: { appModel.renderSettings.safetyBubbleRadius }, set: { appModel.renderSettings.safetyBubbleRadius = $0 }), in: 0.05...2.5)

                                Text("Shape: \(appModel.renderSettings.safetyBubbleShape < 0.33 ? "Sphere" : (appModel.renderSettings.safetyBubbleShape > 0.66 ? "Cube" : "Blend"))")
                                Slider(value: Binding(get: { appModel.renderSettings.safetyBubbleShape }, set: { appModel.renderSettings.safetyBubbleShape = $0 }), in: 0...1)

                                Text("Foveation Intensity")
                                Slider(value: Binding(get: { appModel.renderSettings.foveationIntensity }, set: { appModel.renderSettings.foveationIntensity = $0 }), in: 0...2.0)
                                
                                Divider()
                                
                                Toggle("Relative Gestures", isOn: Binding(
                                    get: { appModel.renderSettings.useRelativeGestures },
                                    set: { appModel.renderSettings.useRelativeGestures = $0 }
                                ))
                                .help("Relative: fine-tune from current value. Absolute: hand distance maps directly to range.")
                            }
                            .padding(.leading, 10)
                        }
                        
                        // Symmetry Movement (auto-pilot along fractal symmetry)
                        DisclosureGroup("Symmetry Movement") {
                            VStack(spacing: 8) {
                                Toggle("Enable Symmetry Travel", isOn: Binding(
                                    get: { appModel.renderSettings.symmetryMovementEnabled },
                                    set: { appModel.renderSettings.symmetryMovementEnabled = $0 }
                                ))
                                .help("Auto-navigate along fractal symmetry axes for hypnotic exploration")
                                
                                if appModel.renderSettings.symmetryMovementEnabled {
                                    Text("Speed: \(appModel.renderSettings.symmetryMovementSpeed, specifier: "%.2f")")
                                    Slider(value: Binding(
                                        get: { appModel.renderSettings.symmetryMovementSpeed },
                                        set: { appModel.renderSettings.symmetryMovementSpeed = $0 }
                                    ), in: 0.05...1.0)
                                    
                                    Text("Direction Change Interval: \(appModel.renderSettings.symmetryUpdateInterval, specifier: "%.1f")s")
                                    Slider(value: Binding(
                                        get: { appModel.renderSettings.symmetryUpdateInterval },
                                        set: { appModel.renderSettings.symmetryUpdateInterval = $0 }
                                    ), in: 0.2...2.0)
                                    
                                    Text("Blend Smoothness: \(appModel.renderSettings.symmetryBlendDuration, specifier: "%.1f")s")
                                    Slider(value: Binding(
                                        get: { appModel.renderSettings.symmetryBlendDuration },
                                        set: { appModel.renderSettings.symmetryBlendDuration = $0 }
                                    ), in: 0.1...1.0)
                                    
                                    Picker("Axis Preference", selection: Binding(
                                        get: { appModel.renderSettings.symmetryPreferredAxis },
                                        set: { appModel.renderSettings.symmetryPreferredAxis = $0 }
                                    )) {
                                        Text("Auto").tag(-1)
                                        Text("Primary").tag(0)
                                        Text("Secondary").tag(1)
                                        Text("Tertiary").tag(2)
                                    }
                                    .pickerStyle(.segmented)
                                }
                            }
                            .padding(.leading, 10)
                        }

                        // Gesture hints
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Gesture Controls:")
                                .font(.caption)
                                .fontWeight(.semibold)
                            Text("✊ Left fist: Start/stop recording")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("👆 Right middle→palm: Toggle menu")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)

                        Text("FPS: \(appModel.fps, specifier: "%.1f")")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(cameraMode ? "Camera dolly: drag = Z, pinch = Z" : "Object move: drag = XY, pinch = Z")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
