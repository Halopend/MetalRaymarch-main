//
//  UISettingsCacheTests.swift
//  ThresholdTests
//
//  Guards UI-to-renderer writes and the platform-specific live-stat refresh
//  policy without constructing the full AppModel graph.
//

import Testing
import simd
@testable import Threshold

@MainActor
@Suite("UI settings cache synchronization")
struct UISettingsCacheTests {

    @Test("platform visibility updates both cache and RenderSettings")
    func platformVisibilityPushesToRenderSettings() {
        let settings = RenderSettings()
        settings.withPersistenceSuppressed {
            settings.platformEnabled = true
            settings.platformRadius = 1.4
            let cache = UISettingsCache(renderSettings: settings)

            cache.setPlatformEnabled(false)

            #expect(cache.display.platformEnabled == false)
            #expect(settings.platformEnabled == false)
            #expect(settings.platformRadius == 1.4)
            #expect(settings.snapshot().platformEnabled == false)
        }
    }

    @Test("loading platform and bounding state is a read-only cache projection")
    func loadingStateDoesNotMutateRenderSettings() {
        let settings = RenderSettings()
        settings.withPersistenceSuppressed {
            settings.platformEnabled = false
            settings.boundingShapeType = SafetyBubbleShapePreset.dodecahedron.storedValue

            let cache = UISettingsCache(renderSettings: settings)

            #expect(cache.display.platformEnabled == false)
            #expect(cache.quality.boundingShapeType == SafetyBubbleShapePreset.dodecahedron.storedValue)
            #expect(settings.platformEnabled == false)
            #expect(settings.boundingShapeType == SafetyBubbleShapePreset.dodecahedron.storedValue)
            #expect(settings.snapshot().boundingShapeType == SafetyBubbleShapePreset.dodecahedron.storedValue)
        }
    }

    @Test("live stats refresh according to the renderer lifecycle on each platform")
    func liveStatsUsePlatformLifecycle() {
        let settings = RenderSettings()
        settings.withPersistenceSuppressed {
            settings.fractalIterations = 21
            settings.maxRaySteps = 177
            settings.fractalScale = 4.25
            settings.position = SIMD3<Float>(1, 2, 3)
            settings.detailScale = 0.125
            let cache = UISettingsCache(renderSettings: settings)

            cache.refreshLiveStats(
                isAppActive: true,
                immersiveSpaceIsOpen: false,
                fps: 90
            )

#if os(visionOS)
            #expect(cache.liveFractalIterations != 21)
            #expect(cache.liveFPS == 0)

            cache.refreshLiveStats(
                isAppActive: true,
                immersiveSpaceIsOpen: true,
                fps: 90
            )
#endif

            #expect(cache.liveFractalIterations == 21)
            #expect(cache.liveMaxRaySteps == 177)
            #expect(cache.liveFractalScale == 4.25)
            #expect(cache.livePosition == SIMD3<Float>(1, 2, 3))
            #expect(cache.liveDetailScale == 0.125)
            #expect(cache.liveFPS == 90)

            settings.fractalIterations = 22
            cache.refreshLiveStats(
                isAppActive: false,
                immersiveSpaceIsOpen: true,
                fps: 120
            )
            #expect(cache.liveFractalIterations == 21)
            #expect(cache.liveFPS == 90)
        }
    }
}
