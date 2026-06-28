//
//  ParameterCatalogTests.swift
//  ThresholdTests
//
//  A CI-runnable floor under the parameter-node hierarchy migration
//  (Context/PARAMETER_NODE_HIERARCHY_DESIGN.md). Two things this guards that were
//  previously only checked at app launch (via a `precondition` tripwire) or not at all:
//
//   1. The catalog ⇄ ControlCatalog "golden equality" net — every routed descriptor
//      equals its canonical ControlSpec, and the derived id lists agree. Drift here
//      is what the 6-registry lockstep used to risk.
//   2. validateStartupRouting() exercised IN-PROCESS (a non-trapping return == pass),
//      so a routing/range mismatch fails in `xcodebuild test` instead of only crashing
//      the app on first launch.
//
//  Plus the Slice 7 regression net: every formula float node's range matches its
//  authored FormulaCatalog param, across all fractal types.
//

import Testing
import Foundation
@testable import Threshold

@Suite("Parameter catalog — single-source-of-truth invariants")
struct ParameterCatalogTests {

    // MARK: Catalog ⇄ ControlCatalog (the migration's golden net)

    @Test("Routed descriptors exactly cover ControlCatalog.allSpecs (no spec without descriptor, none extra)")
    func routedDescriptorsCoverAllSpecs() {
        let descriptorIDs = Set(ParameterCatalog.routedDescriptors.map(\.id))
        let specIDs = Set(ControlCatalog.allSpecs.map(\.id))
        #expect(descriptorIDs == specIDs,
                "Catalog/spec id set mismatch — extra: \(descriptorIDs.subtracting(specIDs)), missing: \(specIDs.subtracting(descriptorIDs))")
    }

    @Test("Each descriptor's spec IS the canonical ControlCatalog spec (range/default/motion/name)")
    func descriptorSpecsMatchCatalog() {
        for descriptor in ParameterCatalog.routedDescriptors {
            let spec = ControlCatalog.spec(descriptor.id)
            #expect(spec != nil, "No ControlCatalog spec for routed descriptor \(descriptor.id)")
            if let spec {
                // ControlSpec is Equatable — full structural equality.
                #expect(descriptor.spec == spec, "Descriptor spec drifted from catalog for \(descriptor.id)")
            }
        }
    }

    @Test("byID is complete and collision-free")
    func byIDComplete() {
        #expect(ParameterCatalog.byID.count == ParameterCatalog.routedDescriptors.count,
                "byID has fewer entries than descriptors — duplicate id collision")
        for descriptor in ParameterCatalog.routedDescriptors {
            #expect(ParameterCatalog.byID[descriptor.id]?.id == descriptor.id)
        }
    }

    @Test("ParameterTargetID.coreAndEffect derives from the catalog")
    func coreAndEffectDerivesFromCatalog() {
        #expect(Set(ParameterTargetID.coreAndEffect) == Set(ParameterCatalog.routedDescriptors.map(\.id)))
    }

    @Test("settingsBinding(for:) resolves for every routed id and is nil for unknown ids")
    func settingsBindingResolves() {
        for descriptor in ParameterCatalog.routedDescriptors {
            #expect(ParameterCatalog.settingsBinding(for: descriptor.id) != nil,
                    "Missing settings binding for routed id \(descriptor.id)")
        }
        #expect(ParameterCatalog.settingsBinding(for: "definitely.not.a.real.id") == nil)
    }

    @Test("clamp honors the spec range at both extremes")
    func clampHonorsRange() {
        for descriptor in ParameterCatalog.routedDescriptors {
            let lo = descriptor.spec.range.lowerBound
            let hi = descriptor.spec.range.upperBound
            #expect(descriptor.clamp(lo - 10) == lo, "clamp low failed for \(descriptor.id)")
            #expect(descriptor.clamp(hi + 10) == hi, "clamp high failed for \(descriptor.id)")
        }
    }

    // MARK: Startup routing tripwire — run it in CI, not just at app launch

    @Test("validateStartupRouting passes (the lockstep tripwire, exercised in-process)")
    func startupRoutingValidates() {
        // A non-trapping return == pass. A precondition mismatch would trap the test
        // process (and fail the run), which is exactly the signal we want in CI.
        ParameterRoutingValidation.validateStartupRouting()
    }

    // MARK: Slice 7 — formula nodes faithfully project their FormulaCatalog params

    @Test("Every formula float node's range matches its FormulaCatalog param, for all fractal types")
    func formulaNodesMatchCatalogRanges() {
        for type in FractalModelType.allCases {
            guard let descriptor = FormulaCatalog.shared.descriptor(for: type) else { continue }
            let batch = ParameterNodeRegistry.shared.formulaBatch(for: type)
            for param in descriptor.params {
                guard !(param.isBool ?? false), !(param.isHidden ?? false) else { continue }
                guard let node = batch.floatNodeByFormulaIndex[param.index] else {
                    Issue.record("Missing float node for \(type) param \(param.index) (\(param.name))")
                    continue
                }
                #expect(node.range == param.min...param.max,
                        "Range drift for \(type) \(param.name): node \(node.range) vs param \(param.min)...\(param.max)")
            }
        }
    }
}
