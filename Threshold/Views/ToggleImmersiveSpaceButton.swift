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
        // The label and action follow both the requested and materialized Window
        // state so rapid detach/merge taps cannot race SwiftUI's scene lifecycle.
        Button {
            if appModel.isControlsWindowOpen || appModel.isControlsWindowRequested {
                appModel.requestControlsWindowDismissal()
                dismissWindow(id: AppModel.controlsWindowID)
            } else {
                appModel.requestControlsWindowPresentation()
                openWindow(id: AppModel.controlsWindowID)
            }
        } label: {
            Text(appModel.isControlsWindowOpen || appModel.isControlsWindowRequested ? "Merge" : "Detach")
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .animation(.none, value: 0)
        .fontWeight(.semibold)
#else
        Button {
        } label: {
            Text("Detach")
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

/// Widths for the Immersive / Window / Mixed switcher. The segmented control
/// divides its frame evenly between three labels, so it has to be wide enough
/// that "Immersive" never truncates — the previous 220 pt bottom-bar frame and
/// ~300 pt launch-window frame left Vision Pro users squinting at the segments.
/// These are roughly 40–45% wider than the originals.
enum ImmersionSwitcherMetrics {
    /// Bottom-bar presentation inside the immersive workspace (was 220 pt).
    static let bottomBarWidth: CGFloat = 320

    /// Launch-window presentation (was effectively capped at 300 pt by the
    /// 360 pt window minus its 30 pt padding).
    static let launchWindowPickerWidth: CGFloat = 448

    /// Launch window width: the picker plus its 30 pt padding on each side.
    static let launchWindowWidth: CGFloat = launchWindowPickerWidth + 60

    /// The launch window never shrinks below this, so the switcher keeps its
    /// readable width even if something else in the card is narrow.
    static let launchWindowMinimumWidth: CGFloat = 420
}

#if os(visionOS)
/// Immersion style picker: Immersive (takes over the whole view; the Digital
/// Crown dials it down to a window), Window (a persistent portal), or Mixed
/// (no portal — the fractal floats in the real room over
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
                    Text("Window").tag(AppModel.ImmersionStylePreference.window)
                    Text("Mixed").tag(AppModel.ImmersionStylePreference.mixed)
                }
                .pickerStyle(.segmented)

                if showsCaption && appModel.immersionStylePreference != .mixed {
                    Text("Digital Crown smoothly sizes the window")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
#endif
