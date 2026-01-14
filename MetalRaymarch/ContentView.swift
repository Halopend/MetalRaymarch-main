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
    @State private var resolutionScale: Float = 0.5
    @State private var cameraMode: Bool = false

    var body: some View {
        @Bindable var appModel = appModel

        VStack {
            VStack(spacing: 10) {
                // Presets button at the top
                HStack {
                    PresetButton(
                        presetManager: appModel.presetManager,
                        settings: appModel.renderSettings,
                        captureScreenshot: { await appModel.captureScreenshot() },
                        onLoadPreset: { preset in
                            preset.apply(to: appModel.renderSettings)
                        }
                    )
                    
                    Spacer()
                }
                .padding(.bottom, 8)
                
                Text("Resolution Scale: \(Int(appModel.renderSettings.resolutionScale * 100))%")
                    .font(.headline)

                Slider(value: Binding(
                    get: { appModel.renderSettings.resolutionScale },
                    set: { appModel.renderSettings.resolutionScale = $0 }
                ), in: 0.25...1.0, step: 0.05)

                Toggle("Prefer foveated (disables MetalFX)", isOn: Binding(
                    get: { appModel.renderSettings.preferFoveated },
                    set: { appModel.renderSettings.preferFoveated = $0 }
                ))

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

                // Show MetalFX/ upscaling status for easier debugging
                HStack(spacing: 8) {
                    Image(systemName: appModel.metalFXAvailable ? "bolt.fill" : "bolt.slash")
                        .foregroundStyle(appModel.metalFXAvailable ? .yellow : .secondary)
                    Text(appModel.metalFXStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                        // Quality preset picker
                        Group {
                            Text("Quality Preset")
                                .font(.headline)
                            
                            Picker("Quality", selection: Binding(
                                get: {
                                    QualityPreset.detect(
                                        fractalIterations: appModel.renderSettings.fractalIterations,
                                        raySteps: appModel.renderSettings.maxRaySteps
                                    ) ?? .low
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

                        // Shape Parameters Group
                        DisclosureGroup("Shape Parameters") {
                            VStack(spacing: 8) {
                                Text("Min Distance")
                                Slider(value: Binding(
                                    get: { appModel.renderSettings.targetMinDistance },
                                    set: { appModel.renderSettings.targetMinDistance = $0 }
                                ), in: 0.0001...3.0)

                                Text("Box Folding Limit")
                                Slider(value: Binding(
                                    get: { appModel.renderSettings.targetFoldingLimit },
                                    set: { appModel.renderSettings.targetFoldingLimit = $0 }
                                ), in: 0.1...5.0)

                                Text("Sphere Radius")
                                Slider(value: Binding(
                                    get: { appModel.renderSettings.targetSphereRadius },
                                    set: { appModel.renderSettings.targetSphereRadius = $0 }
                                ), in: 0.01...2.0)
                            }
                            .padding(.leading, 10)
                        }

                        // Color & Glow Group
                        DisclosureGroup("Color & Glow") {
                            VStack(spacing: 8) {
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

                                Text("Foveation Intensity")
                                Slider(value: Binding(get: { appModel.renderSettings.foveationIntensity }, set: { appModel.renderSettings.foveationIntensity = $0 }), in: 0...2.0)
                            }
                            .padding(.leading, 10)
                        }

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
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
