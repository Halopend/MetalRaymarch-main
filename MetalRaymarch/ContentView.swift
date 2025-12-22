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

    var body: some View {
        @Bindable var appModel = appModel
        
        let _ = print("DEBUG: ContentView body re-evaluated. Resolution Scale: \(appModel.renderSettings.resolutionScale)")

        VStack {
            // Resolution Scale - Always visible
            VStack(spacing: 5) {
                Text("Resolution Scale: \(Int(appModel.renderSettings.resolutionScale * 100))%")
                    .font(.headline)
                
                Slider(value: Binding(
                    get: { appModel.renderSettings.resolutionScale },
                    set: { appModel.renderSettings.resolutionScale = $0 }
                ), in: 0.25...1.0, step: 0.05)
                
                // Tile-based rendering mode (2x2 quad sharing for ~4x less raymarching)
                HStack {
                    Text("Tile Mode:")
                    Picker("", selection: Binding(
                        get: { appModel.renderSettings.tileSize },
                        set: { appModel.renderSettings.tileSize = $0 }
                    )) {
                        Text("Off").tag(0)
                        Text("2×2 (Quad)").tag(2)
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.top, 8)
                
                // Hierarchical raymarch toggle (only applies when Tile Mode is on)
                if appModel.renderSettings.tileSize > 0 {
                    Toggle("Hierarchical Raymarch", isOn: Binding(
                        get: { appModel.renderSettings.useHierarchical },
                        set: { appModel.renderSettings.useHierarchical = $0 }
                    ))
                    .font(.caption)
                }
                
                // Show MetalFX / upscaling status for easier debugging
                HStack(spacing: 8) {
                    Image(systemName: appModel.metalFXAvailable ? "bolt.fill" : "bolt.slash")
                        .foregroundStyle(appModel.metalFXAvailable ? .yellow : .secondary)
                    Text(appModel.metalFXStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 20)

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
                        
                        Text("Min Distance")
                        Slider(value: Binding(get: { appModel.renderSettings.minDistance }, set: { appModel.renderSettings.minDistance = $0 }), in: 0.0001...1.0)
                        
                        Text("Fractal Scale")
                        Slider(value: Binding(get: { appModel.renderSettings.fractalScale }, set: { appModel.renderSettings.fractalScale = $0 }), in: 1.0...5.0)
                        
                        Text("Fractal Iterations")
                        Slider(value: Binding(get: { Float(appModel.renderSettings.fractalIterations) }, set: { appModel.renderSettings.fractalIterations = Int($0) }), in: 3...15, step: 1)
                        
                        Text("Ray Steps")
                        Slider(value: Binding(get: { Float(appModel.renderSettings.maxRaySteps) }, set: { appModel.renderSettings.maxRaySteps = Int($0) }), in: 16...128, step: 8)
                        
                        // Text("Foveation Intensity")
                        // Slider(value: Binding(get: { appModel.renderSettings.foveationIntensity }, set: { appModel.renderSettings.foveationIntensity = $0 }), in: 0.0...2.0)
                        
                        // Text("Color Mix")
                        // Slider(value: Binding(get: { appModel.renderSettings.colorMix }, set: { appModel.renderSettings.colorMix = $0 }), in: 0.0...1.0)
                        
                        // Text("Glow Intensity")
                        // Slider(value: Binding(get: { appModel.renderSettings.glowIntensity }, set: { appModel.renderSettings.glowIntensity = $0 }), in: 0.0...1.0)
                        
                        Text("Box Folding Limit")
                        Slider(value: Binding(get: { appModel.renderSettings.foldingLimit }, set: { appModel.renderSettings.foldingLimit = $0 }), in: 0.5...2.0)
                        
                        Text("Sphere Radius")
                        Slider(value: Binding(get: { appModel.renderSettings.sphereRadius }, set: { appModel.renderSettings.sphereRadius = $0 }), in: 0.1...1.5)
                        
                        // Text("Color Iterations")
                        // Slider(value: Binding(get: { appModel.renderSettings.colorIterations }, set: { appModel.renderSettings.colorIterations = $0 }), in: 2...12, step: 1)

                        Text("FPS: \(appModel.fps, specifier: "%.1f")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Text("Drag to move, Pinch to scale")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }
            }
        }
        .padding(40)
        .gesture(
            DragGesture()
                .onChanged { value in
                    let sensitivity: Float = 0.002
                    // X and Y movement
                    let delta = SIMD3<Float>(Float(value.translation.width) * sensitivity, -Float(value.translation.height) * sensitivity, 0)
                    appModel.renderSettings.position = initialPosition + delta
                }
                .onEnded { _ in
                    initialPosition = appModel.renderSettings.position
                }
        )
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    // Z movement (Pinch/Pull)
                    let sensitivity: Float = 1.0
                    let zDelta = (Float(value.magnification) - 1.0) * sensitivity
                    // Pulling (magnification > 1) brings it closer (positive Z in this setup usually, or negative depending on camera)
                    // Let's assume +Z is towards camera or simply moving the object.
                    var newPos = initialPosition
                    newPos.z += zDelta
                    appModel.renderSettings.position = newPos
                }
                .onEnded { _ in
                    initialPosition = appModel.renderSettings.position
                }
        )
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
