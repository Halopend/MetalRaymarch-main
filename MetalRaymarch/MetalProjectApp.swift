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
        configuration.depthFormat = .depth32Float
        configuration.colorFormat = .bgra8Unorm_srgb

        // Enable foveation but don't force foveation-enabled layouts
        configuration.isFoveationEnabled = capabilities.supportsFoveation

        let supportedLayouts = capabilities.supportedLayouts(options: [])

        configuration.layout = supportedLayouts.contains(.layered) ? .layered : .dedicated
        
        // Ensure we have renderTarget usage for direct rendering
        configuration.colorFormat = .bgra8Unorm_srgb
        // Add shaderWrite just in case blit needs it, though usually not required for copy
        // But definitely need renderTarget
        // configuration.textureUsage = [.renderTarget, .shaderRead] 
    }
}

@main
struct MetalProjectTestApp: App {
    @State private var appModel = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window(appModel.menuWindowID, id: appModel.menuWindowID) {
            ContentView()
                .environment(appModel)
                // Glass background is applied conditionally in ContentView based on visibility
                .onAppear {
                    // Ensure window content is visible when app launches or window appears
                    appModel.ensureWindowContentVisible()
                }
        }
        .defaultSize(width: 600, height: 250)
        .windowStyle(.plain)
        .windowResizability(.contentSize)

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            CompositorLayer(configuration: ContentStageConfiguration()) { @MainActor layerRenderer in
                Renderer.startRenderLoop(layerRenderer, appModel: appModel)
            }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
        .upperLimbVisibility(.visible)
        .onChange(of: appModel.immersiveSpaceState) { oldValue, newValue in
            // When exiting immersive mode, ensure window is visible and populated
            if oldValue == .open && (newValue == .closed || newValue == .inTransition) {
                Task { @MainActor in
                    // Small delay to let the transition complete
                    try? await Task.sleep(for: .milliseconds(100))
                    appModel.ensureWindowContentVisible()
                    // Re-open the menu window to ensure it's in front
                    openWindow(id: appModel.menuWindowID)
                }
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            // Handle app becoming active from background/terminated state
            if newPhase == .active {
                Task { @MainActor in
                    appModel.isAppActive = true
                    appModel.ensureWindowContentVisible()
                }
            } else {
                Task { @MainActor in
                    appModel.isAppActive = false
                }
            }
        }
    }
}

