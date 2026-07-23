//
//  ControlStateStoreTests.swift
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
struct ControlStateStoreTests {

    @Test("platform visibility updates both cache and RenderSettings")
    func platformVisibilityPushesToRenderSettings() {
        let settings = RenderSettings()
        settings.withPersistenceSuppressed {
            settings.platformEnabled = true
            settings.platformRadius = 1.4
            let cache = ControlStateStore(renderSettings: settings)

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

            let cache = ControlStateStore(renderSettings: settings)

            #expect(cache.display.platformEnabled == false)
            #expect(cache.quality.boundingShapeType == SafetyBubbleShapePreset.dodecahedron.storedValue)
            #expect(settings.platformEnabled == false)
            #expect(settings.boundingShapeType == SafetyBubbleShapePreset.dodecahedron.storedValue)
            #expect(settings.snapshot().boundingShapeType == SafetyBubbleShapePreset.dodecahedron.storedValue)
        }
    }

    @Test("Bounding toggle preserves the authored non-sphere silhouette")
    func boundingTogglePreservesShape() {
        let settings = RenderSettings()
        settings.withPersistenceSuppressed {
            settings.boundingSphereSkipEnabled = false
            settings.boundingShapeType = SafetyBubbleShapePreset.dodecahedron.storedValue
            let cache = ControlStateStore(renderSettings: settings)

            cache.setBoundingShapeEnabled(true)

            #expect(cache.quality.boundingSphereSkipEnabled)
            #expect(cache.quality.boundingShapeType == SafetyBubbleShapePreset.dodecahedron.storedValue)
            #expect(settings.boundingShapeType == SafetyBubbleShapePreset.dodecahedron.storedValue)
        }
    }

    @Test("Containment picker makes authored space latch exclusively")
    func authoredSpaceContainmentLatches() {
        let settings = RenderSettings()
        settings.withPersistenceSuppressed {
            settings.boundingSphereSkipEnabled = true
            settings.boundToSpaceEnabled = false
            settings.envScrunchEnabled = true
            let cache = ControlStateStore(renderSettings: settings)

            #expect(cache.mixedContainment == .custom)
            cache.applyMixedContainment(.space)

            #expect(cache.mixedContainment == .space)
            #expect(cache.quality.boundToSpaceEnabled)
            #expect(!cache.quality.boundingSphereSkipEnabled)
            #expect(!cache.quality.envScrunchEnabled)
            #expect(settings.boundToSpaceEnabled)
            #expect(!settings.boundingSphereSkipEnabled)
            #expect(!settings.envScrunchEnabled)
        }
    }

    @Test("A Bounding silhouette promotes to a same-sized primitive seed")
    func boundingShapePromotesToSeed() {
        let settings = RenderSettings()
        settings.withPersistenceSuppressed {
            settings.boundingSphereSkipEnabled = true
            settings.boundingShapeRadius = 2.75
            settings.boundingShapeType = SafetyBubbleShapePreset.icosahedron.storedValue
            settings.spaceWarpStack = [SpaceWarpOpValue(kind: .icosahedralCut)]
            let cache = ControlStateStore(renderSettings: settings)

            cache.promoteBoundingShapeToSeed()

            #expect(settings.fractalType == .constructionPrimitive)
            #expect(FractalPrimitiveKind(
                selector: Int(FormulaCatalog.getParam(settings.formulaParams, index: 0).rounded())
            ) == .icosahedron)
            #expect(abs(FormulaCatalog.getParam(settings.formulaParams, index: 1) - 2.75) < 1e-5)
            #expect(!settings.boundingSphereSkipEnabled)
            #expect(settings.spaceWarpStack.map(\.kind) == [.icosahedralCut])
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
            let cache = ControlStateStore(renderSettings: settings)

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

    @Test("Transform slider writes stay value-only while structural edits invalidate projections")
    func transformMirrorSeparatesValuesFromStructure() {
        let settings = RenderSettings()
        settings.withPersistenceSuppressed {
            let operation = SpaceWarpOpValue(kind: .twist)
            settings.spaceWarpStack = [operation]
            let cache = ControlStateStore(renderSettings: settings)
            let initialRevision = cache.spaceWarpStructureRevision

            #expect(cache.updateSpaceWarpOp(id: operation.id) { $0.strength = 0.25 })
            #expect(cache.spaceWarpStack.first?.strength == 0.25)
            #expect(settings.spaceWarpStack.first?.strength == 0.25)
            #expect(cache.spaceWarpStructureRevision == initialRevision)

            var expanded = cache.spaceWarpStack
            expanded.append(SpaceWarpOpValue(kind: .mirror))
            cache.replaceSpaceWarpStack(expanded)

            #expect(cache.spaceWarpStack.map(\.kind) == [.twist, .mirror])
            #expect(settings.spaceWarpStack.map(\.kind) == [.twist, .mirror])
            #expect(cache.spaceWarpStructureRevision == initialRevision + 1)
        }
    }
}
