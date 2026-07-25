//
//  MenuChrome.swift
//  Threshold
//
//  Small shared pieces of the per-platform control-menu chrome.
//
//  The Mac (hover slide-over), iPad (inspector), and visionOS (window) menus are
//  genuinely different presentation paradigms and intentionally keep their own
//  state machines — a unifying "controller" would add indirection without removing
//  duplication. But they share two bits that had drifted into copy-paste: the
//  panel spring animation (was duplicated 4×) and the "auto-hide when a scene is
//  loaded" trigger (driven by appModel.menuAutoHideRequestID). Those live here once.
//

import SwiftUI

enum MenuChrome {
    /// The spring used for showing/hiding the control panel across platforms.
    static let panelSpring = Animation.spring(response: 0.35, dampingFraction: 0.85)
}

private struct AutoHideOnSceneLoad: ViewModifier {
    @Environment(AppModel.self) private var appModel
    let action: @MainActor () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: appModel.menuAutoHideRequestID) { _, _ in
            // SwiftUI can deliver this observer while AppKit is running the
            // current Core Animation pre-commit actions. Opening an explicit
            // panel animation from that callback creates a nested NSCGS
            // transaction ("transaction during CA commit"). Yield once so the
            // current commit finishes before platform chrome is removed.
            Task { @MainActor in
                await Task.yield()
                action()
            }
        }
    }
}

extension View {
    /// Run `action` whenever a scene load asks the menu to auto-hide
    /// (`appModel.menuAutoHideRequestID` bumps). Each platform supplies its own
    /// hide behavior; the observer wiring is shared here.
    func onSceneLoadAutoHide(perform action: @escaping @MainActor () -> Void) -> some View {
        modifier(AutoHideOnSceneLoad(action: action))
    }
}
