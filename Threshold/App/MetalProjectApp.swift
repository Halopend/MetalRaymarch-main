//
//  MetalProjectApp.swift
//  MetalProject
//
//  Created by MU on 18/11/24.
//

#if os(visionOS)
import SwiftUI
import CompositorServices
import Metal

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

        // === PROGRESSIVE IMMERSION (visionOS 26+) ===
        // Declaring a render-context stencil format opts the layer into the
        // compositor's portal-mask machinery, which is what lets the
        // ImmersiveSpace use the .progressive style (Digital Crown dials the
        // portal size). Full immersion is unaffected while the style stays
        // .full. NOTE: once configured, the compositor requires the drawable
        // render-context pass before every present in EVERY style — see
        // Renderer.encodeDrawableRenderContextPass.
        var progressiveImmersionEnabled = false
        if #available(visionOS 26.0, *) {
            if configuration.layout == .layered,
               capabilities.supportedLayouts(options: [.progressiveImmersionEnabled]).contains(.layered) {
                let stencilFormats = capabilities.drawableRenderContextSupportedStencilFormats
                // The portal pass uses the compositor's depth texture and a
                // separate stencil attachment. A packed depth/stencil fallback
                // is not interchangeable: Metal requires both aspects of a
                // packed format to refer to the same texture, while the
                // compositor requires its own depth texture here. Enable the
                // render context only when the separate stencil8 format that
                // this pass is authored for is actually supported.
                if stencilFormats.contains(.stencil8) {
                    configuration.drawableRenderContextStencilFormat = .stencil8
                    progressiveImmersionEnabled = true
                    print("✓ progressive immersion enabled (render-context stencil format: \(MTLPixelFormat.stencil8.rawValue))")
                } else {
                    print("⚠️ progressive immersion unavailable: separate stencil8 render context is unsupported")
                }
            }
        }

        // === HDR / EDR COLOR OUTPUT ===
        // rgba16Float is the compositor's HDR-renderable format: content is
        // composited as extended linear Display P3 with a 2.0x SDR-white EDR
        // headroom (WWDC23 10089). The raymarch fragment shader already
        // returns linear-light values — the sRGB drawable merely hardware-
        // encoded them — so the SDR body renders identically while highlight
        // energy above 1.0 (glow, bloom, specular; see the display mapping in
        // Shaders.metal) now reaches the panel instead of clipping. Every
        // downstream pipeline/texture derives its format from
        // `layerRenderer.configuration.colorFormat`, so this is the single
        // decision point. Checked last so the capability query can account for
        // the progressive-immersion portal machinery configured above.
        if QualityConfig.visionHDRColorEnabled {
            let hdrSupported: Bool
            if #available(visionOS 26.0, *) {
                let options: LayerRenderer.Capabilities.SupportedColorFormatsOptions =
                    progressiveImmersionEnabled ? [.progressiveImmersionEnabled] : []
                hdrSupported = capabilities.supportedColorFormats(options: options).contains(.rgba16Float)
            } else {
                // Documented as supported for HDR since visionOS 1.0; the
                // pre-26 capability list API is deprecated, so trust the docs.
                hdrSupported = true
            }
            if hdrSupported {
                configuration.colorFormat = .rgba16Float
                print("✓ HDR color output enabled (rgba16Float, EDR headroom \(QualityConfig.visionEDRHeadroom)x SDR)")
            } else {
                print("⚠️ HDR color output unavailable: rgba16Float unsupported for current layer options")
            }
        }
    }
}

@main
struct MetalProjectTestApp: App {
    @State private var appModel = AppModel()
    @State private var spatialRadialMenu = SpatialRadialMenuModel()

    /// Keep the entire morph in one progressive compositor style. The previous
    /// progressive-to-Mixed handoff changed alpha/depth semantics mid-animation,
    /// producing a visible pop and a dark seam around the portal.
    static let immersionCrownRange: ClosedRange<Double> = 0.28...1.0
    static let windowInitialAmount: Double = 0.38
    @AppStorage("hasCompletedIntroOnboarding") private var hasCompletedIntroOnboarding = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some Scene {
        Window(appModel.menuWindowID, id: appModel.menuWindowID) {
            ContentView()
                .environment(appModel)
                .environment(spatialRadialMenu)
                .background(ImmersiveSpaceAutoOpener().environment(appModel))
                .onAppear { [appModel, openWindow, dismissWindow] in
                    Task { @MainActor in
                        await appModel.startMicrophoneAtLaunchIfEnabled()
                    }

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
                    // This app-scoped seam remains alive while the main control
                    // window is dismissed in immersive mode.
                    appModel.openAnimationEditorHandler = { [openWindow] in
                        openWindow(id: AppModel.animationEditorWindowID)
                    }
                    // CompositorLayer must remain the direct ImmersiveSpace
                    // content. Without a spatial presentation handler, gesture
                    // commands intentionally use AppModel's existing plain
                    // menu-window routes instead of an unsupported RealityView
                    // sibling or a separate volumetric window.

                    if !hasCompletedIntroOnboarding {
                        openWindow(id: AppModel.onboardingWindowID)
                        dismissWindow(id: appModel.menuWindowID)
                    } else {
                        // Treat the window scene lifecycle as the source of
                        // truth; `openWindow` itself cannot report whether
                        // presentation succeeded. Defer the observed-state
                        // write past SwiftUI's current view-update turn.
                        Task { @MainActor in
                            await Task.yield()
                            appModel.markMenuWindowPresented()
                        }
                    }
                }
                .onOpenURL { url in
                    appModel.openExternalFile(url)
                }
                .onDisappear { [appModel] in
                    // Match presentation acknowledgement: lifecycle callbacks
                    // may run during a SwiftUI update, so publish on the next
                    // main-actor turn.
                    Task { @MainActor in
                        await Task.yield()
                        appModel.markMenuWindowDismissed()
                    }
                }
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
        // The selection follows the effective Immersive / Window / Mixed preference.
        // Immersive uses the compositor's full style so it remains launchable on
        // devices that do not expose a standalone stencil8 render-context
        // attachment. Window uses progressive style and therefore requires the
        // portal render-context capability configured above.
        // Mixed has no portal — the scene composites over passthrough (miss
        // rays write alpha 0). The picker is authoritative: compositor writes
        // must not silently replace the mode the user selected.
        .immersionStyle(
            selection: Binding(
                get: {
                    switch appModel.immersionStylePreference {
                    case .immersive:
                        return .full
                    case .window:
                        return .progressive(MetalProjectTestApp.immersionCrownRange, initialAmount: MetalProjectTestApp.windowInitialAmount)
                    case .mixed:
                        return .mixed
                    }
                },
                // SwiftUI writes this binding while constructing or reconciling
                // the immersive stage. Those writes describe compositor state,
                // not an explicit user choice; accepting them made Mixed and
                // Window snap back to Immersive. The in-app picker writes
                // `immersionStylePreference` directly.
                set: { _ in }
            ),
            in: .full, .progressive, .mixed
        )
        .upperLimbVisibility(.visible)
        .persistentSystemOverlays(.hidden)
        .onChange(of: appModel.immersiveSpaceState) { oldValue, newValue in
            if newValue == .closed {
                appModel.cancelActiveRenderLoop()
                if appModel.isSpatialMenuVisible {
                    appModel.setSpatialMenuVisible(false)
                }
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
        .onChange(of: scenePhase) { _, newPhase in
            AppLifecycle.transition(to: newPhase, appModel: appModel)
            if newPhase == .active {
                appModel.ensureWindowContentVisible()
            } else if newPhase == .background {
                // No-op outside instrumented PGO builds.
                PGOProfile.flush()
            }
        }
    }
}
#endif
