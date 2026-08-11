//
//  CustomSpaceWarpRuntimeStateTests.swift
//  ThresholdTests
//
//  Presentation semantics for the external space-warp activation lifecycle.
//

import Testing
@testable import Threshold

@Suite("External space-warp runtime state")
struct CustomSpaceWarpRuntimeStateTests {
    @Test("Queued, compiling, active, and detaching states expose distinct controls")
    func presentationSemantics() {
        let cases: [(
            label: String,
            state: CustomSpaceWarpRuntimeState,
            isPresent: Bool,
            isBusy: Bool,
            isActive: Bool,
            canDetach: Bool,
            overridesBuiltInStack: Bool,
            name: String?
        )] = [
            ("inactive", .inactive, false, false, false, false, false, nil),
            ("waiting", .waitingForRenderer(name: "Warp"), true, false, false, true, false, "Warp"),
            ("compiling", .compiling(name: "Warp"), true, true, false, false, false, "Warp"),
            ("active", .active(name: "Warp"), true, false, true, true, true, "Warp"),
            ("detaching", .detaching(name: "Warp"), true, true, false, false, true, "Warp"),
        ]

        for expectation in cases {
            #expect(expectation.state.isPresent == expectation.isPresent,
                    "\(expectation.label) presence changed")
            #expect(expectation.state.isBusy == expectation.isBusy,
                    "\(expectation.label) busy state changed")
            #expect(expectation.state.isActive == expectation.isActive,
                    "\(expectation.label) active state changed")
            #expect(expectation.state.canDetach == expectation.canDetach,
                    "\(expectation.label) detach eligibility changed")
            #expect(expectation.state.overridesBuiltInStack == expectation.overridesBuiltInStack,
                    "\(expectation.label) stack-override semantics changed")
            #expect(expectation.state.name == expectation.name,
                    "\(expectation.label) display name changed")
        }
    }
}
