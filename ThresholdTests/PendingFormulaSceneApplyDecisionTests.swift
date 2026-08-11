//
//  PendingFormulaSceneApplyDecisionTests.swift
//  ThresholdTests
//
//  Regression coverage for animation scenes queued behind runtime shader
//  publication. A bound renderer handler is deliberately not part of this
//  decision: handler availability precedes asynchronous Metal publication.
//

import Testing
@testable import Threshold

@Suite("Queued animation formula publication")
struct PendingFormulaSceneApplyDecisionTests {
    private let currentGeneration: UInt64 = 7

    private func decision(
        expected: String = "formula-a",
        slot: EmbeddedFormulaPublicationSlot = .primary,
        active: String? = "formula-a",
        activeLighting: String? = "lighting-a",
        publishedPrimary: String? = "formula-a",
        publishedLighting: String? = "lighting-a",
        publishedGeneration: UInt64? = 7,
        requiresActiveRuntime: Bool = false,
        runtimeIsActive: Bool = false
    ) -> PendingFormulaSceneApplyDecision {
        let publication = publishedGeneration.map {
            PublishedEmbeddedEffectSet(
                primaryHash: publishedPrimary,
                lightingHash: publishedLighting,
                operationGeneration: $0
            )
        }
        return .resolve(
            expectedFormulaHash: expected,
            slot: slot,
            activeFormulaHash: active,
            activeLightingHash: activeLighting,
            publication: publication,
            currentOperationGeneration: currentGeneration,
            requiresActiveRuntime: requiresActiveRuntime,
            runtimeIsActive: runtimeIsActive
        )
    }

    @Test("Only the exact current published effect set may apply")
    func publicationIdentity() {
        #expect(decision() == .apply)
        #expect(decision(active: "formula-b") == .discard)
        #expect(decision(publishedGeneration: nil) == .waitForPublication)
        #expect(decision(publishedGeneration: 6) == .waitForPublication)
        #expect(decision(publishedPrimary: "formula-b") == .waitForPublication)
        #expect(decision(publishedLighting: "lighting-b") == .waitForPublication)
    }

    @Test("A space warp additionally waits for active runtime publication")
    func warpRuntimeGate() {
        #expect(decision(
            requiresActiveRuntime: true,
            runtimeIsActive: false
        ) == .waitForPublication)
        #expect(decision(
            requiresActiveRuntime: true,
            runtimeIsActive: true
        ) == .apply)
    }

    @Test("A lighting formula resolves against the lighting publication slot")
    func lightingSlot() {
        #expect(decision(
            expected: "lighting-a",
            slot: .lighting,
            requiresActiveRuntime: true,
            runtimeIsActive: true
        ) == .apply)
        #expect(decision(
            expected: "lighting-a",
            slot: .lighting,
            activeLighting: "lighting-b",
            requiresActiveRuntime: true,
            runtimeIsActive: true
        ) == .discard)
        #expect(decision(
            expected: "lighting-a",
            slot: .lighting,
            requiresActiveRuntime: true,
            runtimeIsActive: false
        ) == .waitForPublication)
    }
}
