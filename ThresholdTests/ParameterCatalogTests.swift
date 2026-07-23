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

    @Test("byID is complete and collision-free")
    func byIDComplete() {
        #expect(ParameterCatalog.byID.count == ParameterCatalog.routedDescriptors.count,
                "byID has fewer entries than descriptors — duplicate id collision")
        for descriptor in ParameterCatalog.routedDescriptors {
            #expect(ParameterCatalog.byID[descriptor.id]?.id == descriptor.id)
        }
    }

    @Test("Every static scalar has complete metadata and explicit placement")
    func completeScalarMetadataAndPlacement() {
        #expect(Set(ParameterCatalog.allDescriptors.map(\.controlID)) == Set(ControlCatalog.everySpec.map(\.controlID)))
        for descriptor in ParameterCatalog.allDescriptors {
            #expect(!descriptor.id.isEmpty)
            #expect(!descriptor.spec.name.isEmpty)
            #expect(!descriptor.spec.icon.isEmpty)
            #expect(descriptor.spec.range.contains(descriptor.spec.defaultValue))
            switch descriptor.placement {
            case .internalOnly:
                break
            case .presented(let route, let section, _, let presentations):
                #expect(!route.stableID.isEmpty)
                #expect(!section.isEmpty)
                #expect(!presentations.isEmpty)
                #expect(presentations.contains(.fullControls))
            }
        }
    }

    @Test("Semantic control IDs are globally unique")
    func semanticIDsAreUnique() {
        let ids = ParameterCatalog.semanticDescriptors.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ParameterCatalog.semanticByID.count == ids.count)
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

    // MARK: Slice 9 — the audioModulate clamp is no longer validator-invisible

    /// The former "6th registry": each `audioModulate<Name>` setter clamps against a
    /// hand-picked `ControlCatalog.<spec>`, and nothing proved that spec is the SAME
    /// one its routed descriptor owns. Drive every descriptor's off-main `settings.write`
    /// past both bounds and assert the stored value is EITHER clamped to that
    /// descriptor's own spec range OR passed through raw (the params whose write is
    /// guarded upstream by the dispatcher's spec-range clamp — e.g. fractalScale,
    /// colorMix, the Twist origin axes). A write that clamps to any *other* range
    /// (the actual drift failure mode) lands on neither value and trips this test.
    @Test("Each descriptor's settings.write clamps to its OWN spec range, or not at all (no divergent-range clamp)")
    func settingsWriteClampMatchesSpec() {
        let overshoot: Float = 1000
        for descriptor in ParameterCatalog.routedDescriptors {
            let lo = descriptor.spec.range.lowerBound
            let hi = descriptor.spec.range.upperBound

            let highInput = hi + overshoot
            let sHigh = RenderSettings()
            descriptor.settings.write(sHigh, highInput)
            let readHigh = descriptor.settings.read(sHigh)
            #expect(readHigh == hi || readHigh == highInput,
                    "\(descriptor.id): write(\(highInput)) stored \(readHigh) — neither spec max \(hi) nor raw input (divergent-range clamp?)")

            let lowInput = lo - overshoot
            let sLow = RenderSettings()
            descriptor.settings.write(sLow, lowInput)
            let readLow = descriptor.settings.read(sLow)
            #expect(readLow == lo || readLow == lowInput,
                    "\(descriptor.id): write(\(lowInput)) stored \(readLow) — neither spec min \(lo) nor raw input (divergent-range clamp?)")
        }
    }

    /// The generic `audioModulate(targetID:value:)` entry clamps via the catalog for
    /// EVERY routed id (unlike the raw property setters), so audio can never push a
    /// routed scalar past its spec range through this door. Unknown ids are a silent no-op.
    @Test("Generic audioModulate(targetID:value:) clamps to spec for every routed id")
    func genericAudioModulateClampsToSpec() {
        for descriptor in ParameterCatalog.routedDescriptors {
            let lo = descriptor.spec.range.lowerBound
            let hi = descriptor.spec.range.upperBound

            let sHigh = RenderSettings()
            sHigh.audioModulate(targetID: descriptor.id, value: hi + 1000)
            #expect(descriptor.settings.read(sHigh) == hi,
                    "\(descriptor.id): generic audioModulate did not clamp to spec max \(hi)")

            let sLow = RenderSettings()
            sLow.audioModulate(targetID: descriptor.id, value: lo - 1000)
            #expect(descriptor.settings.read(sLow) == lo,
                    "\(descriptor.id): generic audioModulate did not clamp to spec min \(lo)")
        }
        // Unknown id is a no-op (must not trap).
        RenderSettings().audioModulate(targetID: "definitely.not.a.real.id", value: 1)
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
