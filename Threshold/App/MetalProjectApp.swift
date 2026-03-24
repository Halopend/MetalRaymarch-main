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
    @AppStorage("hasCompletedIntroOnboarding") private var hasCompletedIntroOnboarding = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some Scene {
        Window(appModel.menuWindowID, id: appModel.menuWindowID) {
            ContentView()
                .environment(appModel)
                .onAppear {
                    // Dismiss any secondary windows that may have been restored
                    // by the system from a previous session. Without this, windows
                    // like Music Library can reappear and block immersive mode entry.
                    dismissWindow(id: AppModel.libraryWindowID)
                    dismissWindow(id: AppModel.fractalBrowserWindowID)
                    dismissWindow(id: AppModel.animationEditorWindowID)
                    dismissWindow(id: AppModel.animationPlayerWindowID)
                    dismissWindow(id: AppModel.onboardingWindowID)

                    // Set up handler for gesture-based window control
                    appModel.openMenuWindowHandler = {
                        openWindow(id: appModel.menuWindowID)
                    }
                    // Set up handler to dismiss the menu window for real
                    appModel.dismissMenuWindowHandler = { [dismissWindow] in
                        dismissWindow(id: appModel.menuWindowID)
                    }

                    if !hasCompletedIntroOnboarding {
                        openWindow(id: AppModel.onboardingWindowID)
                        dismissWindow(id: appModel.menuWindowID)
                    }
                }
        }
        .defaultSize(width: 1050, height: 600)
        .windowStyle(.plain)
        .windowResizability(.contentSize)

        Window("Welcome", id: AppModel.onboardingWindowID) {
            FirstLaunchWindowView()
                .environment(appModel)
        }
        .defaultSize(width: 640, height: 540)
        .windowResizability(.contentSize)

        // Music Library pop-out window
        Window("Music Library", id: AppModel.libraryWindowID) {
            MusicLibraryWindow()
                .environment(appModel)
        }
        .defaultSize(width: 500, height: 700)
        .windowResizability(.contentMinSize)

        // Fractal Browser pop-out window (family-focused switcher + historical info)
        Window("Fractal Browser", id: AppModel.fractalBrowserWindowID) {
            FractalBrowserWindow()
                .environment(appModel)
        }
        .defaultSize(width: 980, height: 700)
        .defaultWindowPlacement { _, context in
            if let anchorWindow = context.windows.first(where: { $0.id == appModel.menuWindowID }) ?? context.windows.first {
                return WindowPlacement(.trailing(anchorWindow))
            }
            return WindowPlacement(nil)
        }
        .windowResizability(.contentMinSize)

        Window("Animation Editor", id: AppModel.animationEditorWindowID) {
            AnimationEditorWindowView()
                .environment(appModel)
        }
        .defaultSize(width: 1080, height: 760)
        .defaultWindowPlacement { _, context in
            if let anchorWindow = context.windows.first(where: { $0.id == appModel.menuWindowID }) ?? context.windows.first {
                return WindowPlacement(.trailing(anchorWindow))
            }
            return WindowPlacement(nil)
        }
        .windowResizability(.contentMinSize)

        // Animation Player pop-out window (positioned below main menu)
        Window("Animation Player", id: AppModel.animationPlayerWindowID) {
            AnimationPlayerWindowView()
                .environment(appModel)
        }
        .defaultSize(width: 700, height: 180)
        .defaultWindowPlacement { _, context in
            if let anchorWindow = context.windows.first(where: { $0.id == appModel.menuWindowID }) ?? context.windows.first {
                return WindowPlacement(.below(anchorWindow))
            }
            return WindowPlacement(nil)
        }
        .windowResizability(.contentMinSize)

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

