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
}
