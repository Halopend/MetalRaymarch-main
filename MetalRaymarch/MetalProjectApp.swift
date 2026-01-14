//
//  MetalProjectApp.swift
//  MetalProject
//
//  Created by MU on 18/11/24.
//

import SwiftUI
import CompositorServices

struct ContentStageConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        // === DEPTH FORMAT ===
        // Use depth32Float for reverse-Z precision (compositor expects reverse-Z)
        configuration.depthFormat = .depth32Float
        configuration.colorFormat = .bgra8Unorm_srgb

        // === FOVEATION ===
        // Enable foveation for automatic eye-tracked variable rate shading
        // NOTE: When foveation is enabled, you CANNOT render to smaller resolution
        // and upscale with MetalFX - the rasterizationRateMap dimensions must match
        let foveationEnabled = capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveationEnabled

        // === LAYOUT ===
        // Query supported layouts WITH foveation option if enabled
        // This ensures we get layouts compatible with the rate maps
        let layoutOptions: LayerRenderer.Capabilities.SupportedLayoutsOptions = foveationEnabled ? [.foveationEnabled] : []
        let supportedLayouts = capabilities.supportedLayouts(options: layoutOptions)
        
        // Prefer .layered for efficient vertex amplification (single 2-slice array texture)
        // Fall back to .shared, avoid .dedicated (requires separate render passes per eye)
        if supportedLayouts.contains(.layered) {
            configuration.layout = .layered
        } else if supportedLayouts.contains(.shared) {
            configuration.layout = .shared
        } else {
            configuration.layout = .dedicated
        }
    }
}

@main
struct MetalProjectTestApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .glassBackgroundEffect() // Use default glass to avoid unavailable Material symbol
        }
        .defaultSize(width: 600, height: 250)
        .windowStyle(.plain)

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            CompositorLayer(configuration: ContentStageConfiguration()) { @MainActor layerRenderer in
                Renderer.startRenderLoop(layerRenderer, appModel: appModel)
            }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
        .upperLimbVisibility(.visible)
    }
}

