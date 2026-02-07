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
        
        // === DYNAMIC RENDER QUALITY (WWDC25 Session 294) ===
        // Set max render quality to allow dynamic adjustment between scenes.
        // Higher quality = larger textures, more detail but more GPU work.
        // Lower quality = smaller textures, less detail but faster rendering.
        // For raymarching fractals, we want the flexibility to drop quality when
        // scene complexity is high (dense fractals) and increase when viewing simpler areas.
        //
        // maxRenderQuality sets the upper bound; we dynamically adjust via
        // layerRenderer.renderQuality at runtime based on FPS.
        if #available(visionOS 26.0, *) {
            if configuration.isFoveationEnabled {
                // Allow quality range from default (~0.6) up to 1.0
                // Complex fractal scenes may render at lower quality for performance
                // Simpler views or menus can use higher quality
                configuration.maxRenderQuality = LayerRenderer.RenderQuality(1.0)
                print("✓ Dynamic render quality enabled: maxRenderQuality = 1.0")
            }
        }
    }
}

@main
struct MetalProjectTestApp: App {
    @State private var appModel = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some Scene {
        Window(appModel.menuWindowID, id: appModel.menuWindowID) {
            ContentView()
                .environment(appModel)
                .onAppear {
                    // Set up handler for gesture-based window control
                    appModel.openMenuWindowHandler = {
                        openWindow(id: appModel.menuWindowID)
                    }
                    // Set up handler to dismiss the menu window for real
                    appModel.dismissMenuWindowHandler = { [dismissWindow] in
                        dismissWindow(id: appModel.menuWindowID)
                    }
                    // Set up handler for developer window
                    appModel.openDeveloperWindowHandler = {
                        openWindow(id: appModel.developerWindowID)
                    }
                    // Set up handler for scenes window
                    appModel.openScenesWindowHandler = {
                        openWindow(id: appModel.scenesWindowID)
                    }
                }
        }
        .defaultSize(width: 600, height: 250)
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        
        // Developer Tools Window
        Window("Developer Tools", id: appModel.developerWindowID) {
            DeveloperView()
                .environment(appModel)
        }
        .defaultSize(width: 400, height: 500)
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        
        // Scenes Window
        Window("Animation Scenes", id: appModel.scenesWindowID) {
            ScenesWindowView()
                .environment(appModel)
        }
        .defaultSize(width: 500, height: 600)
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
            } else if newPhase == .background || newPhase == .inactive {
                Task { @MainActor in
                    appModel.isAppActive = false
                    // Save current state when going to background
                    appModel.saveLastState()
                    // Upload analytics before going to background
                    await UsageAnalytics.shared.endSession()
                }
            }
        }
    }
}

