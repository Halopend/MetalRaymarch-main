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
        #expect(engine.lastActivationHand == .right)
        #expect(process(.zero).isEmpty) // release and cooldown elapse
        #expect(process(touching).isEmpty)
        #expect(process(touching) == [.toggleMenu])
    }

    @Test("wrist mode middle-finger fallback reports the right hand")
    func wristModeFallbackReportsRightHand() {
        let engine = MenuToggleGestureEngine()
        let configuration = GestureConfigurationSnapshot(
            version: 1,
            menuToggleEnabled: true,
            menuToggleMode: .wristTap,
            perFingerTapEnabled: false,
            leftTapActions: Array(repeating: .none, count: 5),
            rightTapActions: Array(repeating: .none, count: 5),
            tapActivateThreshold: 0.55,
            tapReleaseThreshold: 0.25,
            tapHoldDuration: 0.08,
            tapCooldown: 0.4
        )
        var left = HandData.zero
        left.isTracked = true
        var right = HandData.zero
        right.isTracked = true
        right.palmCenter = SIMD3<Float>(0, 1, 0)
        right.middleTip = SIMD3<Float>(0, 1.01, 0)
        right.ringTip = SIMD3<Float>(0, 1.20, 0)
        let context = GestureContext(
            leftHand: left,
            rightHand: right,
            deltaTime: 1
        )

        #expect(engine.process(context: context, configuration: configuration).isEmpty)
        #expect(engine.process(context: context, configuration: configuration) == [.toggleMenu])
        #expect(engine.lastActivationHand == .right)
    }

    @Test("spatial shortcut reports the hand that actually opened it")
    func perFingerReportsActivationHand() {
        let engine = PerFingerTapGestureEngine()
        engine.isEnabled = true
        engine.leftHandActions = [
            .none, .none, .none, .openShapeMenu, .none,
        ]
        engine.rightHandActions = Array(repeating: .none, count: 5)
        engine.activateThreshold = 0.3
        engine.holdDuration = 0.08
        engine.cooldown = 0

        var left = HandData.zero
        left.isTracked = true
        left.palmCenter = SIMD3<Float>(0, 1, 0)
        left.ringTip = SIMD3<Float>(0.01, 1, 0)
        let context = GestureContext(
            leftHand: left,
            rightHand: .zero,
            deltaTime: 1
        )

        #expect(engine.process(context: context).isEmpty)
        #expect(engine.process(context: context) == [.openShapeMenu])
        #expect(engine.lastMenuActivationHand == .left)
    }

    @Test("default right-ring pose dispatches one menu command at 90 Hz")
    func defaultRightRingCollisionIsArbitrated() {
        let tapEngine = PerFingerTapGestureEngine()
        tapEngine.isEnabled = GestureDefaults.perFingerTapGestureEnabled
        tapEngine.leftHandActions = GestureDefaults.perFingerTapLeftActions
        tapEngine.rightHandActions = GestureDefaults.perFingerTapRightActions
        tapEngine.activateThreshold = GestureDefaults.perFingerTapActivateThreshold
        tapEngine.releaseThreshold = GestureDefaults.perFingerTapReleaseThreshold
        tapEngine.holdDuration = GestureDefaults.perFingerTapHoldDuration
        tapEngine.cooldown = GestureDefaults.perFingerTapCooldown

        let menuEngine = MenuToggleGestureEngine()
        let configuration = GestureConfigurationSnapshot(
            version: 1,
            menuToggleEnabled: GestureDefaults.menuToggleGestureEnabled,
            menuToggleMode: GestureDefaults.menuToggleGestureMode,
            perFingerTapEnabled: GestureDefaults.perFingerTapGestureEnabled,
            leftTapActions: GestureDefaults.perFingerTapLeftActions,
            rightTapActions: GestureDefaults.perFingerTapRightActions,
            tapActivateThreshold: GestureDefaults.perFingerTapActivateThreshold,
            tapReleaseThreshold: GestureDefaults.perFingerTapReleaseThreshold,
            tapHoldDuration: GestureDefaults.perFingerTapHoldDuration,
            tapCooldown: GestureDefaults.perFingerTapCooldown
        )

        var rightRingToPalm = HandData.zero
        rightRingToPalm.isTracked = true
        rightRingToPalm.palmCenter = SIMD3<Float>(0, 1, 0)
        rightRingToPalm.ringTip = SIMD3<Float>(0.01, 1, 0)
        let context = GestureContext(
            leftHand: .zero,
            rightHand: rightRingToPalm,
            deltaTime: 1 / 90
        )

        var rawCollisionWasObserved = false
        var emittedCommands: [AppCommand] = []
        for _ in 0..<12 {
            let tapOperations = tapEngine.process(context: context)
            let menuOperations = menuEngine.process(
                context: context,
                configuration: configuration
            )
            if tapOperations.contains(.openQuickToggles),
               menuOperations.contains(.toggleMenu) {
                rawCollisionWasObserved = true
            }
            emittedCommands += GestureCommandArbitration.commands(
                tapOperations: tapOperations,
                menuOperations: menuOperations,
                recoveryPoseClaimed: menuEngine.isClaimingPose
            )
        }

        #expect(rawCollisionWasObserved)
        #expect(emittedCommands == [.toggleRadialMenu])
    }

    @Test("recovery-menu ownership suppresses every same-frame tap shortcut")
    func recoveryMenuSuppressesAllTapCommands() {
        #expect(GestureCommandArbitration.commands(
            tapOperations: [
                .toggleAnimationPlayer,
                .openShapeMenu,
                .openRenderMenu,
                .openQuickToggles,
            ],
            menuOperations: [.toggleMenu],
            recoveryPoseClaimed: true
        ) == [.toggleRadialMenu])
    }

    @Test("held recovery pose cannot leak a later tap shortcut and rearms")
    func heldRecoveryPoseOwnsEveryFrameUntilRelease() {
        let tapEngine = PerFingerTapGestureEngine()
        tapEngine.isEnabled = true
        tapEngine.leftHandActions = GestureDefaults.perFingerTapLeftActions
        tapEngine.rightHandActions = GestureDefaults.perFingerTapRightActions
        tapEngine.activateThreshold = GestureDefaults.perFingerTapActivateThreshold
        tapEngine.releaseThreshold = GestureDefaults.perFingerTapReleaseThreshold
        // Deliberately diverge from the recovery hold so Quick Toggles would
        // otherwise leak several frames after Toggle Menu has already fired.
        tapEngine.holdDuration = 0.14
        tapEngine.cooldown = GestureDefaults.perFingerTapCooldown

        let menuEngine = MenuToggleGestureEngine()
        let configuration = GestureConfigurationSnapshot(
            version: 1,
            menuToggleEnabled: true,
            menuToggleMode: .middleOrRingToPalm,
            perFingerTapEnabled: true,
            leftTapActions: GestureDefaults.perFingerTapLeftActions,
            rightTapActions: GestureDefaults.perFingerTapRightActions,
            tapActivateThreshold: GestureDefaults.perFingerTapActivateThreshold,
            tapReleaseThreshold: GestureDefaults.perFingerTapReleaseThreshold,
            tapHoldDuration: 0.14,
            tapCooldown: GestureDefaults.perFingerTapCooldown
        )

        var held = HandData.zero
        held.isTracked = true
        held.palmCenter = SIMD3<Float>(0, 1, 0)
        held.ringTip = SIMD3<Float>(0.01, 1, 0)
        var released = held
        released.ringTip = SIMD3<Float>(0.20, 1, 0)

        var emittedCommands: [AppCommand] = []
        var didEmitRecoveryToggle = false
        var observedLateRawTap = false

        func process(_ hand: HandData) {
            let context = GestureContext(
                leftHand: .zero,
                rightHand: hand,
                deltaTime: 1 / 90
            )
            let tapOperations = tapEngine.process(context: context)
            let menuOperations = menuEngine.process(
                context: context,
                configuration: configuration
            )
            if didEmitRecoveryToggle,
               tapOperations.contains(.openQuickToggles) {
                observedLateRawTap = true
            }
            if menuOperations.contains(.toggleMenu) {
                didEmitRecoveryToggle = true
            }
            emittedCommands += GestureCommandArbitration.commands(
                tapOperations: tapOperations,
                menuOperations: menuOperations,
                recoveryPoseClaimed: menuEngine.isClaimingPose
            )
        }

        for _ in 0..<20 { process(held) }
        #expect(observedLateRawTap)
        #expect(emittedCommands == [.toggleRadialMenu])

        // Keep tracking while released so both engines' cooldowns elapse.
        for _ in 0..<45 { process(released) }
        for _ in 0..<20 { process(held) }
        #expect(emittedCommands == [.toggleRadialMenu, .toggleRadialMenu])
    }

    @Test("tap shortcut dispatches when recovery pose does not own it")
    func nonOverlappingTapStillDispatches() {
        #expect(GestureCommandArbitration.commands(
            tapOperations: [.openQuickToggles],
            menuOperations: [],
            recoveryPoseClaimed: false
        ) == [.selectRoute(.quickToggles)])
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
