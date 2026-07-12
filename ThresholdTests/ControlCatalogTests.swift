//
//  ControlCatalogTests.swift
//  ThresholdTests
//
//  Guards the ControlCatalog single-source-of-truth invariants that the parameter
//  hierarchy migration rests on: every spec id is unique, and the routed
//  (`allSpecs`) and long-tail (`longTailSpecs`) sets are disjoint. A duplicate or
//  typo'd id would silently let two controls share a range — the exact drift the
//  spec system exists to prevent — so it must fail fast.
//

import Testing
import Foundation
@testable import Threshold

@Suite("ControlCatalog — spec id invariants")
struct ControlCatalogTests {

    @Test("Every spec id is unique across routed + long-tail")
    func specIDsAreUnique() {
        let ids = ControlCatalog.everySpec.map(\.id)
        let unique = Set(ids)
        #expect(ids.count == unique.count,
                "Duplicate ControlSpec id(s): \(ids.filter { id in ids.filter { $0 == id }.count > 1 })")
    }

    @Test("Routed (allSpecs) and long-tail sets are disjoint")
    func routedAndLongTailDisjoint() {
        let routed = Set(ControlCatalog.allSpecs.map(\.id))
        let longTail = Set(ControlCatalog.longTailSpecs.map(\.id))
        #expect(routed.isDisjoint(with: longTail),
                "A spec appears in BOTH allSpecs and longTailSpecs: \(routed.intersection(longTail))")
    }

    @Test("everySpec is exactly the union of routed + long-tail")
    func everySpecIsUnion() {
        #expect(ControlCatalog.everySpec.count
                == ControlCatalog.allSpecs.count + ControlCatalog.longTailSpecs.count)
    }

    @Test("Long-tail specs are deliberately NOT routed (absent from spec() lookup)")
    func longTailNotRouted() {
        // `spec(_:)` resolves only routed ids; long-tail controls are reached via
        // their static `ControlCatalog.x` accessor, never the routed lookup. This is
        // what keeps them out of validateStartupRouting's node-agreement check.
        for spec in ControlCatalog.longTailSpecs {
            #expect(ControlCatalog.spec(spec.id) == nil,
                    "Long-tail spec '\(spec.id)' unexpectedly resolves as routed.")
        }
    }

    @Test("Post-processing ranges cover shipped looks and identity/off values")
    func postProcessingRanges() {
        // Built-in gradient presets author contrast as high as 1.4.
        #expect(ControlCatalog.colorSchemeContrast.range.contains(1.4))
        // Gamma must cover both sides of the identity exponent.
        #expect(ControlCatalog.colorSchemeGamma.range.contains(1.0))
        #expect(ControlCatalog.colorSchemeGamma.range.upperBound > 1.0)

        #expect(ControlCatalog.vignetteStrength.range.lowerBound == 0)
        #expect(ControlCatalog.edgeStrength.range.lowerBound == 0)
        #expect(ControlCatalog.edgeThreshold.range.upperBound == 0.25)
        #expect(ControlCatalog.edgeSoftness.range.lowerBound == 0.001)
        #expect(ControlCatalog.edgeWindowRadius.range == 1...3)
    }
}
