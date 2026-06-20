//
//  ImmersiveSpaceAutoOpener.swift
//  Threshold
//
//  Invisible helper view that listens for
//  `AppModel.requestOpenImmersiveSpaceNotification` and calls
//  `@Environment(\.openImmersiveSpace)` to bring the immersive space up
//  automatically. Mounted inside the menu window so it can react to
//  external-file imports that landed while the user was on the menu — a
//  `.threshfx` import needs the renderer (and therefore the immersive
//  space) to come up so the custom MTLLibrary can be compiled and the
//  imported preset applied.
//
//  This is a no-op on platforms that don't have an immersive space
//  (iOS, macOS) and a no-op when the immersive space is already open.
//

import SwiftUI

struct ImmersiveSpaceAutoOpener: View {
    @Environment(AppModel.self) private var appModel

#if os(visionOS)
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
#endif

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task {
#if os(visionOS)
                let notifications = NotificationCenter.default.notifications(
                    named: AppModel.requestOpenImmersiveSpaceNotification
                )
                for await _ in notifications {
                    // The notification fires from `AppModel` whenever a
                    // queued preset is waiting for the renderer. Only act
                    // when the immersive space is fully closed — if it's
                    // already open or mid-transition, ignore this signal.
                    guard appModel.immersiveSpaceState == .closed else { continue }
                    appModel.immersiveSpaceState = .inTransition
                    let result = await openImmersiveSpace(id: appModel.immersiveSpaceID)
                    if case .userCancelled = result {
                        appModel.immersiveSpaceState = .closed
                    } else if case .error = result {
                        appModel.immersiveSpaceState = .closed
                    }
                    // On `.opened` leave the state as `.inTransition` so
                    // the normal `ImmersiveView.onAppear` path can flip it
                    // to `.open` (matches the existing toggle button).
                }
#endif
            }
    }
}
