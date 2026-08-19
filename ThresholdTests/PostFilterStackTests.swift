import Foundation
import Testing
@testable import Threshold

@Suite("Ordered output-filter model")
struct PostFilterStackTests {
    @Test("stable kind IDs and ColorConfig Codable preserve explicit order")
    func codablePreservesIdentityAndOrder() throws {
        #expect(PostProcessingFilterKind.allCases.map(\.rawValue) == [1, 2, 3, 4, 5, 6, 7])

        let sepiaID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let edgeID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let sepia = PostFilterInstance(
            id: sepiaID,
            kind: .sepia,
            isEnabled: true,
            amount: 0.42,
            params: SIMD4<Float>(repeating: 99),
            color: SIMD3<Float>(0.2, 0.3, 0.4)
        )
        let edge = PostFilterInstance(
            id: edgeID,
            kind: .edgeDetection,
            isEnabled: false,
            amount: 0.75,
            params: SIMD4<Float>(0.2, 0.1, 3, 7),
            color: SIMD3<Float>(0.1, 0.6, 0.9)
        )
        var config = ColorConfig()
        config.postFilterStack = [sepia, edge]

        let decoded = try JSONDecoder().decode(
            ColorConfig.self,
            from: JSONEncoder().encode(config)
        )
        #expect(decoded.postFilterStack?.map(\.id) == [sepiaID, edgeID])
        #expect(decoded.postFilterStack?.map(\.kind) == [.sepia, .edgeDetection])
        #expect(decoded.postFilterStack?[0].amount == 0.42)
        #expect(decoded.postFilterStack?[1].params == SIMD4<Float>(0.2, 0.1, 3, 0))
        #expect(decoded.postFilterStack?[1].color == SIMD3<Float>(0.1, 0.6, 0.9))

        let legacy = try JSONDecoder().decode(ColorConfig.self, from: Data("{}".utf8))
        let explicitEmpty = try JSONDecoder().decode(
            ColorConfig.self,
            from: Data("{\"postFilterStack\":[]}".utf8)
        )
        #expect(legacy.postFilterStack == nil)
        #expect(explicitEmpty.postFilterStack == [])
    }

    @Test("normalization clamps values, keeps one edge, and caps the stack")
    func normalizationEnforcesInvariants() {
        var malformed = PostFilterInstance(kind: .scanlines)
        malformed.amount = .nan
        malformed.params = SIMD4<Float>(.infinity, -.infinity, 12, 12)
        malformed.color = SIMD3<Float>(.nan, -4, 8)
        malformed.normalize()
        #expect(malformed.amount == 0)
        #expect(malformed.params == SIMD4<Float>(480, 0.35, 0, 0))
        #expect(malformed.color == SIMD3<Float>(1, 0, 1))

        let firstEdge = PostFilterInstance(kind: .edgeDetection)
        let duplicateEdge = PostFilterInstance(kind: .edgeDetection)
        let tail = (0..<9).map { _ in PostFilterInstance(kind: .grain) }
        let normalized = ([firstEdge, duplicateEdge] + tail).normalizedPostFilterStack()
        #expect(normalized.count == PostFilterInstance.maximumCount)
        #expect(normalized.filter { $0.kind == .edgeDetection }.map(\.id) == [firstEdge.id])
        #expect(normalized.first?.id == firstEdge.id)
    }

    @Test("packing preserves active order and drops disabled or zero filters")
    func packingIsOrderedAndSparse() {
        var disabled = PostFilterInstance(kind: .monochrome)
        disabled.isEnabled = false
        let sepia = PostFilterInstance(kind: .sepia)
        var zero = PostFilterInstance(kind: .invert)
        zero.amount = 0
        var posterize = PostFilterInstance(kind: .posterize)
        posterize.params.x = 9

        let packed = cPostFilterStack(from: [disabled, sepia, zero, posterize])
        #expect(packed.count == 2)
        withUnsafePointer(to: packed.ops) { tuplePointer in
            tuplePointer.withMemoryRebound(
                to: PostFilterOp.self,
                capacity: Int(kMaxPostFilterOps)
            ) { ops in
                #expect(ops[0].type == PostProcessingFilterKind.sepia.rawValue)
                #expect(ops[0].amount == 1)
                #expect(ops[1].type == PostProcessingFilterKind.posterize.rawValue)
                #expect(ops[1].param1 == 9)
            }
        }
    }

    @Test("legacy edge state and explicit stacks migrate bidirectionally")
    func legacyEdgeMigration() {
        let settings = RenderSettings()
        settings.withPersistenceSuppressed {
            #expect(settings.colorConfig.postFilterStack == nil)

            settings.edgeDetectionEffect = EdgeDetectionEffect(
                enabled: true,
                strength: 0.7,
                threshold: 0.18,
                softness: 0.04,
                windowRadius: 2,
                color: SIMD3<Float>(0.2, 0.4, 0.8)
            )
            let legacyResolved = settings.postFilterStack
            #expect(legacyResolved.count == 1)
            #expect(legacyResolved[0].kind == .edgeDetection)
            #expect(settings.colorConfig.postFilterStack == nil)
            #expect(settings.snapshot().postFilterStack.count == 1)

            let invert = PostFilterInstance(kind: .invert)
            var explicitEdge = PostFilterInstance(kind: .edgeDetection)
            explicitEdge.amount = 0.35
            explicitEdge.params = SIMD4<Float>(0.25, 0.12, 3, 0)
            explicitEdge.color = SIMD3<Float>(0.9, 0.3, 0.1)
            settings.postFilterStack = [invert, explicitEdge]

            #expect(settings.colorConfig.postFilterStack?.map(\.id) == [invert.id, explicitEdge.id])
            #expect(settings.edgeDetectionEffect.strength == 0.35)
            #expect(settings.edgeDetectionEffect.threshold == 0.25)
            #expect(settings.edgeDetectionEffect.color == SIMD3<Float>(0.9, 0.3, 0.1))

            settings.edgeDetectionEffect = .off
            #expect(settings.postFilterStack.map(\.id) == [invert.id, explicitEdge.id])
            #expect(settings.postFilterStack[1].isEnabled == false)
            #expect(settings.snapshot().postFilterStack.count == 1)

            settings.postFilterStack = []
            #expect(settings.edgeDetectionEffect.isActive == false)
            #expect(settings.colorConfig.postFilterStack == [])
            #expect(settings.snapshot().postFilterStack.count == 0)
        }
    }

    @Test("scanline sampling stays visible at common output heights")
    func scanlineSamplingAvoidsDegenerateFrequencies() {
        func sampleBand(row: Int, height: Int, density authoredDensity: Float = 480) -> Float {
            let pixelHeight = 1 / Float(height)
            let density = min(max(authoredDensity, 1), 0.5 / pixelHeight)
            let uvY = (Float(row) + 0.5) * pixelHeight
            let rowAlignedY = uvY - 0.5 * pixelHeight
            return 0.5 + 0.5 * cos(rowAlignedY * density * 2 * .pi)
        }

        for height in [480, 960] {
            #expect(sampleBand(row: 0, height: height) > 0.999)
            #expect(sampleBand(row: 1, height: height) < 0.001)
            #expect(sampleBand(row: 2, height: height) > 0.999)
        }

        // Frequencies beyond the output's Nyquist limit retain the same stable
        // row alternation instead of collapsing into a flat tint or moire.
        #expect(sampleBand(row: 0, height: 720, density: 2_048) > 0.999)
        #expect(sampleBand(row: 1, height: 720, density: 2_048) < 0.001)
    }
}

@MainActor
@Suite("Output-filter editor mirror")
struct PostFilterStoreTests {
    @Test("value edits avoid structural invalidation while reorder commits do invalidate")
    func mirrorSeparatesValuesFromStructure() {
        let settings = RenderSettings()
        settings.withPersistenceSuppressed {
            let sepia = PostFilterInstance(kind: .sepia)
            let grain = PostFilterInstance(kind: .grain)
            settings.postFilterStack = [sepia, grain]
            let store = ControlStateStore(renderSettings: settings)
            let initialRevision = store.postFilterStructureRevision

            #expect(store.updatePostFilter(id: grain.id) { $0.amount = 0.6 })
            #expect(store.postFilterStack[1].amount == 0.6)
            #expect(settings.postFilterStack[1].amount == 0.6)
            #expect(store.postFilterStructureRevision == initialRevision)

            store.replacePostFilterStack([store.postFilterStack[1], store.postFilterStack[0]])
            #expect(store.postFilterStack.map(\.id) == [grain.id, sepia.id])
            #expect(settings.postFilterStack.map(\.id) == [grain.id, sepia.id])
            #expect(store.postFilterStructureRevision == initialRevision + 1)
        }
    }
}
