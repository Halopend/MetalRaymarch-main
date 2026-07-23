//
//  MenuGestureOwnershipTests.swift
//  ThresholdTests
//
//  The explicit "Open Menu With" setting must be the only source of menu
//  open/close behavior. Older builds mapped per-finger tap to Toggle Menu too,
//  which made changing the selected menu gesture appear ineffective.
//

import Testing
@testable import Threshold

@Suite("Menu gesture ownership")
struct MenuGestureOwnershipTests {

    @Test("per-finger defaults do not toggle the menu")
    func perFingerDefaultsDoNotToggleMenu() {
        #expect(!GestureDefaults.perFingerTapLeftActions.contains(.toggleMenu))
        #expect(!GestureDefaults.perFingerTapRightActions.contains(.toggleMenu))
    }

    @Test("legacy per-finger menu actions are sanitized")
    func legacyMenuActionsAreSanitized() {
        let actions: [PerFingerTapAction] = [.none, .toggleMenu, .openShapeMenu, .toggleMenu, .openRenderMenu]

        #expect(actions.removingMenuToggleActions == [.none, .none, .openShapeMenu, .none, .openRenderMenu])
    }

    @Test("gesture configuration copies only when its version changes")
    func gestureConfigurationIsVersioned() {
        let settings = RenderSettings()
        let snapshot = settings.gestureConfigurationSnapshot(ifNewerThan: .max)
        #expect(snapshot != nil)
        guard let snapshot else { return }
        #expect(settings.gestureConfigurationSnapshot(ifNewerThan: snapshot.version) == nil)
        #expect(!snapshot.leftTapActions.contains(.toggleMenu))
        #expect(!snapshot.rightTapActions.contains(.toggleMenu))
    }

    @Test("dedicated recovery engine releases and retriggers")
    func dedicatedRecoveryEngineRetriggers() {
        let engine = MenuToggleGestureEngine()
        let configuration = GestureConfigurationSnapshot(
            version: 1,
            menuToggleEnabled: true,
            menuToggleMode: .middleAndRingToPalm,
            perFingerTapEnabled: false,
            leftTapActions: Array(repeating: .none, count: 5),
            rightTapActions: Array(repeating: .none, count: 5),
            tapActivateThreshold: 0.55,
            tapReleaseThreshold: 0.25,
            tapHoldDuration: 0.08,
            tapCooldown: 0.4
        )
        var touching = HandData.zero
        touching.isTracked = true
        touching.palmCenter = SIMD3<Float>(0, 1, 0)
        touching.middleTip = SIMD3<Float>(0, 1.01, 0)
        touching.ringTip = SIMD3<Float>(0.01, 1, 0)

        func process(_ hand: HandData) -> [GestureOperation] {
            engine.process(
                context: GestureContext(leftHand: .zero, rightHand: hand, deltaTime: 1),
                configuration: configuration
            )
        }

        #expect(process(touching).isEmpty) // debounce frame
        #expect(process(touching) == [.toggleMenu])
        #expect(process(.zero).isEmpty) // release and cooldown elapse
        #expect(process(touching).isEmpty)
        #expect(process(touching) == [.toggleMenu])
    }

    @Test("per-finger engine can never claim recovery-menu ownership")
    func perFingerCannotToggleMenu() {
        let engine = PerFingerTapGestureEngine()
        engine.leftHandActions = Array(repeating: .toggleMenu, count: 5)
        engine.holdDuration = 0.05
        engine.cooldown = 0

        var touching = HandData.zero
        touching.isTracked = true
        touching.palmCenter = SIMD3<Float>(0, 1, 0)
        touching.indexTip = SIMD3<Float>(0, 1.01, 0)

        let context = GestureContext(leftHand: touching, rightHand: .zero, deltaTime: 1)
        #expect(engine.process(context: context).isEmpty)
        #expect(engine.process(context: context).isEmpty)
    }
}
