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

    var body: some View {
        @Bindable var appModel = appModel
        
        VStack {
            ToggleImmersiveSpaceButton()
            
            if appModel.immersiveSpaceState == .open {
                Spacer()
                
                Text("Animation speed (caution: motion sickness!)")
                
                Slider(value: $speed, in: 0...2, onEditingChanged: { editing in
                    if !editing {
                        appModel.clock.speed = Double(speed)
                    }
                })
                
                Text("Min Distance")
                Slider(value: Binding(get: { appModel.renderSettings.minDistance }, set: { appModel.renderSettings.minDistance = $0 }), in: 0.0001...1.0)

                Text("FPS: \(appModel.fps, specifier: "%.1f")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Text("Drag to move, Pinch to scale")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
