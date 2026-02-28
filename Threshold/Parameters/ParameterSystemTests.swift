//
//  ParameterSystemTests.swift
//  Threshold
//
//  Unit tests for the structured parameter system:
//  layer precedence, bundle resolution, node registry, dispatcher routing.
//
//  These tests are self-contained and can be run via `swift test` or Xcode's test navigator
//  once a test target is added.
//

#if canImport(XCTest)
import XCTest

// MARK: - ParameterLayerStack Tests

final class ParameterLayerStackTests: XCTestCase {

    // MARK: - Layer Precedence

    func testDefaultResolvesToBase() {
        let stack = ParameterLayerStack(defaultValue: 0.5, range: 0...1)
        XCTAssertEqual(stack.resolvedValue(at: 0), 0.5, accuracy: 1e-5)
    }

    func testUILayerOverridesBase() {
        var stack = ParameterLayerStack(defaultValue: 0.5, range: 0...1)
        let resolved = stack.apply(layer: .ui, value: 0.8, timestamp: 1.0)
        XCTAssertEqual(resolved, 0.8, accuracy: 1e-5)
    }

    func testGestureOverridesUI() {
        var stack = ParameterLayerStack(defaultValue: 0.5, range: 0...1)
        _ = stack.apply(layer: .ui, value: 0.2, timestamp: 1.0)
        let resolved = stack.apply(layer: .gesture, value: 0.9, timestamp: 1.0)
        XCTAssertEqual(resolved, 0.9, accuracy: 1e-5)
    }

    func testSystemOverridesAll() {
        var stack = ParameterLayerStack(defaultValue: 0.5, range: 0...1)
        _ = stack.apply(layer: .ui, value: 0.2, timestamp: 1.0)
        _ = stack.apply(layer: .gesture, value: 0.9, timestamp: 1.0)
        _ = stack.apply(layer: .music, value: 0.1, timestamp: 1.0)
        let resolved = stack.apply(layer: .system, value: 0.42, timestamp: 1.0)
        XCTAssertEqual(resolved, 0.42, accuracy: 1e-5)
    }

    func testRangeClamping() {
        var stack = ParameterLayerStack(defaultValue: 0.5, range: 0...1)
        let resolved = stack.apply(layer: .ui, value: 5.0, timestamp: 1.0)
        XCTAssertLessThanOrEqual(resolved, 1.0)
    }

    func testBaseBootstrapOnce() {
        var stack = ParameterLayerStack(defaultValue: 0.0, range: -10...10)
        stack.setBaseIfNeeded(3.0, timestamp: 0)
        XCTAssertEqual(stack.resolvedValue(at: 0), 3.0, accuracy: 1e-5)
        // Second call should not overwrite
        stack.setBaseIfNeeded(7.0, timestamp: 1)
        XCTAssertEqual(stack.resolvedValue(at: 1), 3.0, accuracy: 1e-5)
    }
}

// MARK: - ParameterScope Tests

final class ParameterScopeTests: XCTestCase {

    func testCoreScope() {
        let scope: ParameterScope = .core
        XCTAssertEqual(scope.rawValue, "core")
    }

    func testFormulaScope() {
        let scope: ParameterScope = .formula
        XCTAssertEqual(scope.rawValue, "formula")
    }

    func testEffectScope() {
        let scope: ParameterScope = .effect
        XCTAssertEqual(scope.rawValue, "effect")
    }

    func testScopeCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for scope in [ParameterScope.core, .formula, .effect] {
            let data = try encoder.encode(scope)
            let decoded = try decoder.decode(ParameterScope.self, from: data)
            XCTAssertEqual(decoded, scope)
        }
    }
}

// MARK: - ParameterBundle Tests

final class ParameterBundleTests: XCTestCase {

    func testAllBundleCases() {
        let allCases: [ParameterBundle] = [
            .camera, .position, .scale, .rotation, .julia,
            .polarRotation, .color, .lighting, .fractalCore, .custom
        ]
        XCTAssertEqual(allCases.count, 10)
    }

    func testBundleCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let bundle = ParameterBundle.fractalCore
        let data = try encoder.encode(bundle)
        let decoded = try decoder.decode(ParameterBundle.self, from: data)
        XCTAssertEqual(decoded, .fractalCore)
    }
}

// MARK: - ParameterNodeRegistry Tests

final class ParameterNodeRegistryTests: XCTestCase {

    func testCoreNodesRegistered() {
        let registry = ParameterNodeRegistry.shared
        let expectedCoreIDs = [
            "core.targetMinDistance",
            "core.targetFoldingLimit",
            "core.targetSphereRadius",
            "core.fractalScale",
            "core.colorMix"
        ]
        for id in expectedCoreIDs {
            XCTAssertNotNil(registry.coreNode(id: id), "Missing core node: \(id)")
        }
    }

    func testEffectNodesRegistered() {
        let registry = ParameterNodeRegistry.shared
        let expectedEffectIDs = [
            "effect.glow",
            "effect.fog",
            "effect.bloom",
            "effect.hueSpeed",
            "effect.saturation"
        ]
        for id in expectedEffectIDs {
            XCTAssertNotNil(registry.effectNode(id: id), "Missing effect node: \(id)")
        }
    }

    func testCoreNodeBundles() {
        let registry = ParameterNodeRegistry.shared
        XCTAssertEqual(registry.coreNode(id: "core.targetMinDistance")?.metadata?.bundle, .fractalCore)
        XCTAssertEqual(registry.coreNode(id: "core.fractalScale")?.metadata?.bundle, .scale)
        XCTAssertEqual(registry.coreNode(id: "core.colorMix")?.metadata?.bundle, .color)
    }

    func testEffectNodeBundles() {
        let registry = ParameterNodeRegistry.shared
        XCTAssertEqual(registry.effectNode(id: "effect.glow")?.metadata?.bundle, .lighting)
        XCTAssertEqual(registry.effectNode(id: "effect.hueSpeed")?.metadata?.bundle, .color)
    }

    func testCoreNodeScopes() {
        let registry = ParameterNodeRegistry.shared
        for (_, node) in registry.coreNodes {
            XCTAssertEqual(node.scope, .core,
                           "Core node \(node.id) should have scope .core")
        }
    }

    func testEffectNodeScopes() {
        let registry = ParameterNodeRegistry.shared
        for (_, node) in registry.effectNodes {
            XCTAssertEqual(node.scope, .effect,
                           "Effect node \(node.id) should have scope .effect")
        }
    }

    func testAllCoreAndEffectNodesCount() {
        let registry = ParameterNodeRegistry.shared
        let all = registry.allCoreAndEffectNodes
        XCTAssertEqual(all.count, 10, "Expected 5 core + 5 effect nodes")
    }

    func testCoreNodeRanges() {
        let registry = ParameterNodeRegistry.shared
        if let node = registry.coreNode(id: "core.targetMinDistance") {
            XCTAssertEqual(node.range.lowerBound, -5.0)
            XCTAssertEqual(node.range.upperBound, 15.0)
        }
        if let node = registry.coreNode(id: "core.colorMix") {
            XCTAssertEqual(node.range.lowerBound, 0.0)
            XCTAssertEqual(node.range.upperBound, 1.0)
        }
    }
}

// MARK: - ParameterOperation Tests

final class ParameterOperationTests: XCTestCase {

    func testAbsoluteResolution() {
        let value = ParameterOperationValue.absolute(0.5)
        XCTAssertEqual(value.resolved(from: 0.3), 0.5, accuracy: 1e-5)
    }

    func testDeltaResolution() {
        let value = ParameterOperationValue.delta(0.2)
        XCTAssertEqual(value.resolved(from: 0.3), 0.5, accuracy: 1e-5)
    }

    func testOperationCodable() throws {
        let op = ParameterOperation(
            targetID: "core.fractalScale",
            source: .gesture,
            value: .absolute(2.5),
            frameIndex: 42
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(op)
        let decoded = try decoder.decode(ParameterOperation.self, from: data)
        XCTAssertEqual(decoded.targetID, "core.fractalScale")
        XCTAssertEqual(decoded.source, .gesture)
        XCTAssertEqual(decoded.frameIndex, 42)
    }

    func testTransactionGrouping() {
        let ops = [
            ParameterOperation(targetID: "core.fractalScale", source: .gesture, value: .absolute(1.0), frameIndex: 1),
            ParameterOperation(targetID: "core.colorMix", source: .slider, value: .absolute(0.5), frameIndex: 1)
        ]
        let txn = ParameterTransaction(frameIndex: 1, operations: ops)
        XCTAssertEqual(txn.operations.count, 2)
        XCTAssertEqual(txn.frameIndex, 1)
    }
}

// MARK: - FormulaParamDescriptor Bundle Tests

final class FormulaParamDescriptorBundleTests: XCTestCase {

    func testResolvedBundleDefaultsToCustom() {
        let desc = FormulaParamDescriptor(
            index: 0, name: "power", default: 8.0,
            min: 2.0, max: 16.0, step: 0.1
        )
        XCTAssertEqual(desc.resolvedBundle, .custom)
    }

    func testResolvedBundlePassesThrough() {
        let desc = FormulaParamDescriptor(
            index: 0, name: "power", default: 8.0,
            min: 2.0, max: 16.0, step: 0.1,
            bundle: .fractalCore
        )
        XCTAssertEqual(desc.resolvedBundle, .fractalCore)
    }

    func testDescriptorCodableWithBundle() throws {
        let desc = FormulaParamDescriptor(
            index: 3, name: "juliaX", default: 0.0,
            min: -2.0, max: 2.0, step: 0.01,
            bundle: .julia
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(desc)
        let decoded = try decoder.decode(FormulaParamDescriptor.self, from: data)
        XCTAssertEqual(decoded.bundle, .julia)
        XCTAssertEqual(decoded.resolvedBundle, .julia)
    }

    func testDescriptorCodableWithoutBundle() throws {
        let json = """
        {"index":0,"name":"power","default":8.0,"min":2.0,"max":16.0,"step":0.1}
        """
        let decoder = JSONDecoder()
        let desc = try decoder.decode(FormulaParamDescriptor.self, from: Data(json.utf8))
        XCTAssertNil(desc.bundle)
        XCTAssertEqual(desc.resolvedBundle, .custom)
    }
}

// MARK: - Cap / Range Enforcement Tests

final class ParameterCapTests: XCTestCase {

    func testLayerStackClampsAbsoluteInput() {
        var stack = ParameterLayerStack(defaultValue: 0.5, range: 0...1)
        let resolved = stack.apply(layer: .ui, value: 5.0, timestamp: 1.0)
        XCTAssertEqual(resolved, 1.0, accuracy: 1e-5, "Should clamp to upper bound")
    }

    func testLayerStackClampsNegativeInput() {
        var stack = ParameterLayerStack(defaultValue: 0.5, range: 0...1)
        let resolved = stack.apply(layer: .gesture, value: -3.0, timestamp: 1.0)
        XCTAssertEqual(resolved, 0.0, accuracy: 1e-5, "Should clamp to lower bound")
    }

    func testMusicLayerUnclamped() {
        // Music is additive — its raw value shouldn't be individually clamped,
        // but the final resolved sum should be clamped.
        var stack = ParameterLayerStack(defaultValue: 0.5, range: 0...1)
        _ = stack.apply(layer: .ui, value: 0.8, timestamp: 1.0)
        let resolved = stack.apply(layer: .music, value: 0.5, timestamp: 1.0)
        // 0.8 + 0.5 = 1.3 → clamped to 1.0
        XCTAssertEqual(resolved, 1.0, accuracy: 1e-5, "Sum should be clamped at range cap")
    }

    func testCoreNodeCapQueries() {
        let registry = ParameterNodeRegistry.shared
        guard let node = registry.coreNode(id: "core.colorMix") else {
            XCTFail("Missing core.colorMix"); return
        }
        // Node range is 0...1
        XCTAssertEqual(node.range.lowerBound, 0.0)
        XCTAssertEqual(node.range.upperBound, 1.0)
        // isAtMinCap / isAtMaxCap depend on currentValue
        // (can't easily set it here without UISettingsCache, so test normalizedValue math)
        XCTAssertGreaterThanOrEqual(node.normalizedValue, 0.0)
        XCTAssertLessThanOrEqual(node.normalizedValue, 1.0)
    }

    func testCoreNodeRangeMatch() {
        // Every core/effect node's range should match its corresponding
        // ParameterOperationDispatcher descriptor range.
        let registry = ParameterNodeRegistry.shared
        let expectedRanges: [(String, ClosedRange<Float>)] = [
            ("core.targetMinDistance", -5.0...15.0),
            ("core.targetFoldingLimit", -10.0...30.0),
            ("core.targetSphereRadius", -5.0...8.0),
            ("core.fractalScale", -5.0...8.0),
            ("core.colorMix", 0.0...1.0),
            ("effect.glow", 0.0...2.0),
            ("effect.fog", 0.0...1.0),
            ("effect.bloom", 0.0...2.0),
            ("effect.hueSpeed", 0.0...0.5),
            ("effect.saturation", 0.0...3.0),
        ]
        for (id, expectedRange) in expectedRanges {
            let node = registry.coreNode(id: id) ?? registry.effectNode(id: id)
            XCTAssertNotNil(node, "Missing node \(id)")
            XCTAssertEqual(node?.range.lowerBound, expectedRange.lowerBound,
                           "\(id) lower bound mismatch")
            XCTAssertEqual(node?.range.upperBound, expectedRange.upperBound,
                           "\(id) upper bound mismatch")
        }
    }
}

// MARK: - FloatDelayBuffer Tests

final class FloatDelayBufferTests: XCTestCase {

    func testSnap() {
        var buf = FloatDelayBuffer(initialValue: 0.0, responseTime: 0.1)
        buf.snap(to: 5.0)
        XCTAssertEqual(buf.current, 5.0, accuracy: 1e-5)
    }

    func testConvergence() {
        var buf = FloatDelayBuffer(initialValue: 0.0, responseTime: 0.05)
        buf.setTarget(1.0)
        // 200 frames at 60fps ≈ 3.3 seconds — should converge
        for _ in 0..<200 {
            buf.update(deltaTime: 1.0 / 60.0)
        }
        XCTAssertEqual(buf.current, 1.0, accuracy: 0.01)
    }
}
#endif // canImport(XCTest)
