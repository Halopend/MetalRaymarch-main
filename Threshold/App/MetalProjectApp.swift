//
//  MetalProjectApp.swift
//  MetalProject
//
//  Created by MU on 18/11/24.
//

#if os(visionOS)
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

        // === RENDER QUALITY (visionOS 26+) ===
        // The platform DEFAULT runtime render quality is below native, which is why
        // the image looked uniformly soft. The app drives layerRenderer.renderQuality
        // at runtime (see Renderer.applyRenderQualityIfNeeded), bounded by this
        // ceiling. maxRenderQuality governs the drawable texture MEMORY allocation,
        // so we set it to the minimum our content needs per Apple's guidance — the
        // runtime slider scales within it for free (no realloc). Shared with the
        // Render Quality slider's top via QualityConfig.visionMaxRenderQuality.
        if #available(visionOS 26.0, *) {
            if configuration.isFoveationEnabled {
                configuration.maxRenderQuality = LayerRenderer.RenderQuality(QualityConfig.visionMaxRenderQuality)
                print("✓ maxRenderQuality = \(QualityConfig.visionMaxRenderQuality) (platform defaultRenderQuality: \(capabilities.defaultRenderQuality))")
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
                .background(ImmersiveSpaceAutoOpener().environment(appModel))
                .onAppear {
                    // PGO: if this is an instrumented "Generate Optimization
                    // Profile" build, start periodic counter flushing so the
                    // profile survives the SIGKILL teardown typical of
                    // immersive apps. No-op in normal builds.
                    PGOProfile.startPeriodicFlushIfInstrumented()

                    // Dismiss any secondary windows that may have been restored
                    // by the system from a previous session. Without this, windows
                    // like Music Library can reappear and block immersive mode entry.
                    dismissWindow(id: AppModel.libraryWindowID)
                    dismissWindow(id: AppModel.fractalBrowserWindowID)
                    dismissWindow(id: AppModel.animationEditorWindowID)
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
                        appModel.markMenuWindowDismissed()
                        dismissWindow(id: appModel.menuWindowID)
                    }
                }
                .onOpenURL { url in
                    appModel.openExternalFile(url)
                }
                .onDisappear {
                    appModel.markMenuWindowDismissed()
                }
                // Whole-interface zoom (Settings ▸ Display ▸ Interface Scale).
                // Scales the entire menu as one unit so buttons stay proportional
                // to the panels and text; no-op on Mac/iPad.
                .menuInterfaceScaled()
        }
        .defaultSize(width: 1460, height: 820)
        .windowStyle(.plain)
        .windowResizability(.contentSize)

        Window("Welcome", id: AppModel.onboardingWindowID) {
            FirstLaunchWindowView()
                .environment(appModel)
        }
        .defaultSize(width: 980, height: 760)
        .windowResizability(.contentMinSize)

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
        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            CompositorLayer(configuration: ContentStageConfiguration()) { @MainActor layerRenderer in
                Renderer.startRenderLoop(layerRenderer, appModel: appModel)
            }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
        .upperLimbVisibility(.visible)
        .persistentSystemOverlays(.hidden)
        .onChange(of: appModel.immersiveSpaceState) { oldValue, newValue in
            if newValue == .closed {
                appModel.cancelActiveRenderLoop()
                // PGO: capture render-path coverage at the moment the
                // immersive space tears down — the data a profiling run is
                // really after. No-op when not instrumented.
                PGOProfile.flush()
            }

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
                    appModel.presetManager.refreshBundledPresets()
                    appModel.ensureWindowContentVisible()
                }
            } else if newPhase == .background || newPhase == .inactive {
                // PGO: persist profile counters before the system can SIGKILL
                // us. No-op when not instrumented.
                if newPhase == .background { PGOProfile.flush() }
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
#endif

