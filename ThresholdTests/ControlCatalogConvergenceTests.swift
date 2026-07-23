import Testing

@testable import Threshold

@MainActor
@Suite("Control catalog convergence")
struct ControlCatalogConvergenceTests {
    @Test("Live writes are presentation-independent")
    func presentationWriteParity() {
        let settings = RenderSettings()
        let store = ControlStateStore(renderSettings: settings)
        let access = ControlAccessService(store: store)
        let id = ControlCatalog.fractalScale.controlID

        // Flat, radial, and spatial presenters all resolve this same semantic ID
        // through ControlAccessService. Replaying their writes must hit one value.
        for value: Float in [-2.5, 3.25, 7.5] {
            access.write(value, to: id)
            #expect(access.read(id) == value)
            #expect(settings.targetFractalScale == value)
        }
    }

    @Test("Projection cache keys exclude live slider values")
    func projectionDoesNotRebuildForLiveValues() {
        let settings = RenderSettings()
        let store = ControlStateStore(renderSettings: settings)
        let access = ControlAccessService(store: store)
        let cache = ControlCatalogProjectionCache()
        let key = ControlCatalogProjectionKey(
            profile: .macOS,
            route: .shape(.parameters),
            presentation: .radial2D,
            fractalType: .mandelbox,
            catalogRevision: 1,
            transformRevision: 1,
            featureFlags: 0
        )

        let before = cache.sections(for: key)
        access.write(6.25, to: ControlCatalog.fractalScale.controlID)
        let after = cache.sections(for: key)
        #expect(after == before)
        #expect(after.flatMap(\.controlIDs).contains(ControlCatalog.fractalScale.controlID))
    }

    @Test("Platform profiles expose only their native input capabilities")
    func platformCapabilityMatrix() {
        #expect(PlatformProfile.macOS.supports([.pointerViewport, .twoDimensionalRadial]))
        #expect(!PlatformProfile.macOS.supports(.touchViewport))
        #expect(PlatformProfile.iPadOS.supports([.touchViewport, .tiltInput, .hardwareKeyboard]))
        #expect(!PlatformProfile.iPadOS.supports(.handTracking))
        #expect(PlatformProfile.visionOS.supports([.handTracking, .spatialMenu, .gestureEditing]))
        #expect(!PlatformProfile.visionOS.supports(.twoDimensionalRadial))
    }

    @Test("Spatial quick controls are a catalog projection")
    func spatialQuickControlProjection() {
        let ids = Set(ParameterCatalog.toggleDescriptors.compactMap { descriptor -> ControlID? in
            guard PlatformProfile.visionOS.supports(descriptor.requiredPlatformCapabilities),
                  descriptor.placement.presentations.contains(.spatialRadial) else { return nil }
            return descriptor.controlID
        })
        #expect(ids == [
            ControlID("toggle.space.boundingShape"),
            ControlID("toggle.space.surroundings"),
            ControlID("toggle.quality.selfShadows"),
            ControlID("toggle.quality.smartAdvance"),
            ControlID("toggle.input.audioReactive"),
        ])
    }
}
