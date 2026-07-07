//
//  ToggleImmersiveSpaceButton.swift
//  MetalProject
//
//  Created by MU on 18/11/24.
//

import SwiftUI

struct ToggleImmersiveSpaceButton: View {
    @Environment(AppModel.self) private var appModel

#if os(visionOS)
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
#elseif os(macOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
#endif

    var body: some View {
#if os(visionOS)
        Button {
            Task { @MainActor in
                switch appModel.immersiveSpaceState {
                    case .open:
                        appModel.immersiveSpaceState = .inTransition
                        
                        // Ensure window content is visible BEFORE dismissing immersive space
                        // This prevents the user from seeing an empty window
                        appModel.ensureWindowContentVisible()
                        
                        await dismissImmersiveSpace()
                        // Don't set immersiveSpaceState to .closed because there
                        // are multiple paths to ImmersiveView.onDisappear().
                        // Only set .closed in ImmersiveView.onDisappear().

                    case .closed:
                        appModel.immersiveSpaceState = .inTransition
                        switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
                            case .opened:
                                // Don't set immersiveSpaceState to .open because there
                                // may be multiple paths to ImmersiveView.onAppear().
                                // Only set .open in ImmersiveView.onAppear().
                                break

                            case .userCancelled, .error:
                                // On error, we need to mark the immersive space
                                // as closed because it failed to open.
                                fallthrough
                            @unknown default:
                                // On unknown response, assume space did not open.
                                appModel.immersiveSpaceState = .closed
                        }

                    case .inTransition:
                        // This case should not ever happen because button is disabled for this case.
                        break
                }
            }
        } label: {
            Text(appModel.immersiveSpaceState == .open ? "Exit" : "Launch")
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .disabled(appModel.immersiveSpaceState == .inTransition)
        .animation(.none, value: 0)
        .fontWeight(.semibold)
#elseif os(macOS)
        // Toggles the controls between the slide-over sidebar and their own window.
        // The label + action flip with `isControlsWindowOpen` so the same button
        // sends the controls out and brings them back.
        Button {
            if appModel.isControlsWindowOpen {
                dismissWindow(id: AppModel.controlsWindowID)
            } else {
                openWindow(id: AppModel.controlsWindowID)
            }
        } label: {
            Text(appModel.isControlsWindowOpen ? "Merge Into Window" : "Open in Separate Window")
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .animation(.none, value: 0)
        .fontWeight(.semibold)
#else
        Button {
        } label: {
            Text("Open in Separate Window")
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .disabled(true)
        .animation(.none, value: 0)
        .fontWeight(.semibold)
#endif
    }
}

#if os(visionOS)
/// Immersion style picker: Immersive (takes over the whole view; the Digital
/// Crown dials it down to a third, and the bottom of the dial hands off to
/// Mixed) or Mixed (no portal — the fractal floats in the real room over
/// passthrough). Requires visionOS 26 (CompositorServices portal render
/// context) — renders nothing on earlier systems.
struct ImmersionStylePicker: View {
    @Environment(AppModel.self) private var appModel
    var showsCaption: Bool = true

    var body: some View {
        if #available(visionOS 26.0, *) {
            @Bindable var appModel = appModel
            VStack(spacing: 4) {
                Picker("Immersion", selection: $appModel.immersionStylePreference) {
                    Text("Immersive").tag(AppModel.ImmersionStylePreference.immersive)
                    Text("Mixed").tag(AppModel.ImmersionStylePreference.mixed)
                }
                .pickerStyle(.segmented)

                if showsCaption && appModel.immersionStylePreference == .immersive {
                    Text("Digital Crown dials immersion — all the way down switches to Mixed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
#endif
