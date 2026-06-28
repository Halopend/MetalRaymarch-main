import SwiftUI
import AVKit

/// Five-page welcome flow:
///   0. Safety (photosensitive-epilepsy warning, must acknowledge)
///   1. Welcome (what Threshold is, what the app does)
///   2. Hand controls (movement video + handedness)
///   3. Fingers (per-finger actions, read-only) + menu-open gesture picker
///   4. Sharing (analytics on by default; user can opt out + username)
///
/// All four navigation dots and back/next buttons update the same
/// `currentPage` state, so the flow is a single TabView.
struct FirstLaunchWindowView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @AppStorage("hasCompletedIntroOnboarding") private var hasCompletedIntroOnboarding = false

    /// Per-page state, kept here because the page views are local to this
    /// struct and don't need to survive a re-render.
    @State private var currentPage = 0
    @State private var acknowledgedFlash = false
    @State private var leftHanded = false
    @State private var menuGestureStyle: MenuGestureStarterStyle = .palmer
    @State private var shareAnalytics = UsageAnalytics.shared.analyticsEnabled
    @State private var communityDisplayName = UsageAnalytics.shared.communityDisplayName

    private let pageCount = 5

    var body: some View {
        VStack(spacing: 0) {
            // Page indicator (5 dots, current one is accent).
            HStack(spacing: 8) {
                ForEach(0..<pageCount, id: \.self) { i in
                    Circle()
                        .fill(i == currentPage ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Page \(i + 1) of \(pageCount)")
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 8)

            TabView(selection: $currentPage) {
                safetyPage.tag(0)
                welcomePage.tag(1)
                controlsPage.tag(2)
                fingersPage.tag(3)
                sharingPage.tag(4)
            }
            #if os(visionOS)
            .tabViewStyle(.automatic)
            #endif
        }
        .frame(minWidth: 680, idealWidth: 980, maxWidth: 980, minHeight: 600, idealHeight: 820, maxHeight: 820)
        .background(windowSurfaceFill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(windowSurfaceStroke, lineWidth: 1)
        )
#if os(visionOS)
        .glassBackgroundEffect(in: .rect(cornerRadius: 24))
#endif
        .onAppear {
            shareAnalytics = UsageAnalytics.shared.analyticsEnabled
            communityDisplayName = UsageAnalytics.shared.communityDisplayName
            leftHanded = appModel.renderSettings.leftHandedMode
            menuGestureStyle = MenuGestureStarterStyle.style(for: appModel.renderSettings.menuToggleGestureMode) ?? .palmer
        }
    }

    private var windowSurfaceFill: Color {
        colorScheme == .dark ? Color.black.opacity(0.82) : Color.white.opacity(0.76)
    }

    private var windowSurfaceStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    // MARK: - Page 0: Safety

    private var safetyPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Heads up: flashing lights", systemImage: AppIcons.boltTrianglebadgeExclamationmarkFill)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                Text("Some Threshold scenes contain rapidly changing colors, gradients, and audio-driven flashes that may be uncomfortable for people sensitive to flashing or strobing light.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Big, unmistakable warning panel.
            HStack(alignment: .top, spacing: 12) {
                FlashingLightIndicator()
                    .font(.system(size: 36))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Photosensitive-epilepsy warning")
                        .font(.headline)
                    Text("A small fraction of users may experience seizures or loss of consciousness when exposed to flashing lights or patterns, even without a prior history. Symptoms include dizziness, nausea, vision changes, twitching, and disorientation. If you experience any of these, stop using Threshold and consult a doctor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.10)))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
            )

            // The music-reactive system can also produce rapid flashes at
            // high audio levels. Make this explicit so the user knows it's
            // not only the visuals.
            IntroTipRow(
                icon: "waveform.path.ecg",
                title: "Audio-reactive flashes",
                detail: "When music-reactive mappings are enabled, bass hits and beat onsets can drive the lights to flash in time with the audio. Lower the audio amount or disable the mapping if this is uncomfortable."
            )

            // Acknowledgement gate. The Next button is disabled until this
            // is checked, so the user can't skip the warning. Use a real
            // checkbox on macOS (where `ToggleStyle.checkbox` exists) and
            // a prominent toggle on every other platform.
#if os(macOS)
            Toggle(isOn: $acknowledgedFlash) {
                Text("I understand that some scenes may contain flashing lights and audio-driven flashes.")
                    .font(.subheadline.weight(.medium))
            }
            .toggleStyle(.checkbox)
            .tint(.orange)
#else
            Toggle(isOn: $acknowledgedFlash) {
                Text("I understand that some scenes may contain flashing lights and audio-driven flashes.")
                    .font(.subheadline.weight(.medium))
            }
            .tint(.orange)
#endif

            Spacer()

            HStack {
                Spacer()
                Button("Next") { withAnimation { currentPage = 1 } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!acknowledgedFlash)
            }
        }
        .padding(20)
    }

    // MARK: - Page 1: Welcome

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Threshold")
                    .font(.title2.weight(.bold))
                Text("Explore infinite fractal worlds in spatial computing.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                IntroTipRow(
                    icon: "cube.transparent.fill",
                    title: "Raymarched Fractals",
                    detail: "Real-time GPU-rendered 3D fractals you can fly through and reshape with your hands."
                )
                IntroTipRow(
                    icon: "hand.raised.fingers.spread",
                    title: "Hand Gesture Controls",
                    detail: "Pinch, grab, and sculpt fractal parameters using natural hand tracking. More on the next pages."
                )
                IntroTipRow(
                    icon: "arrow.counterclockwise.circle",
                    title: "Reset + Create",
                    detail: "Tap Reset to jump back to your saved baseline. Hold Reset to save the current setup as a new reset point or create a named preset."
                )
                IntroTipRow(
                    icon: "person.2.wave.2",
                    title: "Sharing is on by default",
                    detail: "Threshold can share your settings with the community so they can become future collections. You can opt out anytime in Settings > Sharing."
                )
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.06)))

            Spacer()

            HStack {
                Button("Back") { withAnimation { currentPage = 0 } }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Next") { withAnimation { currentPage = 2 } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    // MARK: - Page 2: Hand Controls + Handedness

    private var controlsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Movement and Scale")
                    .font(.title2.weight(.bold))
                Text("Use your hands to translate, scale, and orbit through fractal space.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            movementTutorialVideoPlayer
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 8) {
                IntroTipRow(
                    icon: "move.3d",
                    title: "Translate",
                    detail: "Pinch with both hands, then move them together to move the fractal."
                )
                IntroTipRow(
                    icon: "arrow.up.left.and.arrow.down.right",
                    title: "Scale + Rotate",
                    detail: "Move hands apart to scale up, together to scale down, and rotate your hands to orbit."
                )
                IntroTipRow(
                    icon: "hand.point.up.left.fill",
                    title: "Choose your dominant hand",
                    detail: "Some per-finger tap defaults are mirrored for left-handed users. You can change this anytime in Settings > Display."
                )
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.06)))

            // Handedness picker. Sets `RenderSettings.leftHandedMode`
            // immediately on toggle (not just on completion), so the
            // Settings tab reflects the user's choice if they bail out
            // and re-open it.
            HStack(spacing: 12) {
                Image(systemName: leftHanded ? AppIcons.handRaisedFingersSpread : AppIcons.handRaisedFingersSpreadFill)
                    .font(.title3)
                    .foregroundStyle(leftHanded ? .indigo : .blue)
                Picker("Dominant hand", selection: $leftHanded) {
                    Label("Left",  systemImage: AppIcons.handRaisedFingersSpread).tag(true)
                    Label("Right", systemImage: AppIcons.handRaisedFingersSpreadFill).tag(false)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                .onChange(of: leftHanded) { _, newValue in
                    appModel.renderSettings.leftHandedMode = newValue
                }
            }

            Spacer()

            HStack {
                Button("Back") { withAnimation { currentPage = 1 } }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Next") { withAnimation { currentPage = 3 } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    // MARK: - Page 3: Per-Finger Actions (read-only)

    /// Shows the user which finger currently triggers which action, and
    /// which gesture opens/closes the menu. The chips are read-only here
    /// — full editing lives in Settings > Gestures. The intro just makes
    /// the mapping obvious so the user knows what to expect.
    private var fingersPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Each finger is its own shortcut")
                    .font(.title2.weight(.bold))
                Text("Tap any finger to your palm to trigger its assigned action. Below are your current assignments — change them anytime in Settings > Gestures.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The five left-hand fingers, in tap-to-palm order. Names
            // and icons mirror those used by the per-finger gesture editor
            // in Settings > Gestures for visual consistency.
            VStack(spacing: 6) {
                ForEach(0..<5, id: \.self) { finger in
                    fingerAssignmentRow(finger: finger)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.purple.opacity(0.06)))

            // Menu toggle — let the user pick how they open the menu from the
            // supported set. Selecting a card writes the mode straight to
            // RenderSettings (like the handedness picker), so it sticks even if
            // the user bails out of onboarding. The same picker lives in
            // Settings > Gestures.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill")
                        .font(.headline)
                        .foregroundStyle(.purple)
                    Text("How do you want to open the menu?")
                        .font(.headline)
                    Spacer()
                }
                ForEach(MenuGestureStarterStyle.allCases) { style in
                    menuGestureStyleCard(style)
                }
                Text("This is the gesture you'll use most. Change it anytime in Settings > Gestures.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.purple.opacity(0.10)))

            Spacer()

            HStack {
                Button("Back") { withAnimation { currentPage = 2 } }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Next") { withAnimation { currentPage = 4 } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    /// One row of the per-finger assignment list on Page 3. Shows the
    /// finger name + icon, then the current action as a small chip.
    private func fingerAssignmentRow(finger: Int) -> some View {
        let names = ["Thumb", "Index", "Middle", "Ring", "Pinky"]
        let icons = ["hand.thumbsup.fill", "1.circle.fill", "2.circle.fill", "3.circle.fill", "4.circle.fill"]
        let action = finger < appModel.renderSettings.perFingerTapLeftActions.count
            ? appModel.renderSettings.perFingerTapLeftActions[finger]
            : .none
        return HStack(spacing: 10) {
            Image(systemName: icons[finger])
                .font(.title3)
                .foregroundStyle(.purple)
                .frame(width: 28)
            Text(names[finger])
                .font(.subheadline.weight(.medium))
            Spacer()
            // The chip uses a low-emphasis background so the user reads
            // it as a label, not a button.
            HStack(spacing: 4) {
                Image(systemName: action.icon)
                Text(action.displayName)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(action == .none ? .secondary : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(action == .none
                               ? Color.secondary.opacity(0.10)
                               : Color.purple.opacity(0.18))
            )
        }
    }

    /// One selectable menu-gesture style card on Page 3. Tapping it updates both
    /// the local highlight and `RenderSettings.menuToggleGestureMode`, which
    /// persists and is read live by the gesture engine.
    private func menuGestureStyleCard(_ style: MenuGestureStarterStyle) -> some View {
        let isSelected = menuGestureStyle == style
        return Button {
            menuGestureStyle = style
            appModel.renderSettings.menuToggleGestureMode = style.mode
        } label: {
            HStack(spacing: 12) {
                Image(systemName: style.icon)
                    .font(.title3)
                    .foregroundStyle(isSelected ? .purple : .secondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(style.title)
                            .font(.subheadline.weight(.semibold))
                        if style.mode.requiresBothHands {
                            Text("Two hands")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }
                    }
                    Text(style.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? AppIcons.checkmarkCircleFill : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? .purple : .secondary.opacity(0.5))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.purple.opacity(0.16) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.purple.opacity(0.45) : Color.secondary.opacity(0.12), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.title)
        .accessibilityHint(style.subtitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Page 4: Sharing (opt-out)

    private var sharingPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sharing is on by default")
                    .font(.title2.weight(.bold))
                Text("Threshold can share your settings so they may be added to future community collections. No account, no email, no location. You can turn this off below or anytime in Settings > Sharing.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: shareAnalytics ? AppIcons.person3Fill : AppIcons.personSlash)
                        .font(.title3)
                        .foregroundStyle(shareAnalytics ? .blue : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shareAnalytics ? "Sharing with the community" : "Sharing is off")
                            .font(.headline)
                        Text(shareAnalytics
                             ? "Your settings can be reviewed for future community features."
                             : "Tap below to turn sharing back on.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $shareAnalytics) {
                    Text(shareAnalytics ? "Sharing is on (turn off)" : "Sharing is off (turn on)")
                }
                .tint(.blue)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Display Name (optional)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("Leave blank to share anonymously", text: $communityDisplayName)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled(true)
                    Text("Used only for community credits. Stays on this device — never leaves your Mac. Leave blank to share anonymously.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Label("What you're sharing:", systemImage: AppIcons.checkmarkCircle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("• Settings snapshots that can become community collections\n• Aggregated usage stats (e.g. which fractals are popular)\n• Your display name, if you add one, for attribution")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Label("What we don't collect:", systemImage: AppIcons.xmarkCircle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    Text("• No account is created\n• No Apple ID, email, or location\n• No photos, recordings, or personal files")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.blue.opacity(0.15), lineWidth: 1)
            )

            Spacer()

            HStack {
                Button("Back") { withAnimation { currentPage = 3 } }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Start Exploring", action: completeOnboarding)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    // MARK: - Tutorial Video Player

    private var movementTutorialVideoPlayer: some View {
        OnboardingTutorialVideoView(
            clip: .movementAndScale,
            missingTitle: "Movement tutorial video",
            missingDetail: "Add movement_and_scale.mp4 to Resources/OnboardingVideos to show the hand movement walkthrough here."
        )
    }

    // MARK: - Completion

    private func completeOnboarding() {
        // Persist the state the user just configured: sharing toggle,
        // username, handedness, and menu-open gesture. (Handedness and the
        // gesture are also written live on change, so this is belt-and-braces.)
        // The acknowledgement checkbox is intentionally not persisted — it's a
        // one-time consent, not a setting.
        UsageAnalytics.shared.communityDisplayName = communityDisplayName
        UsageAnalytics.shared.analyticsEnabled = shareAnalytics
        appModel.renderSettings.leftHandedMode = leftHanded
        appModel.renderSettings.menuToggleGestureMode = menuGestureStyle.mode
        hasCompletedIntroOnboarding = true
        openWindow(id: appModel.menuWindowID)
        dismissWindow(id: AppModel.onboardingWindowID)
    }
}

private struct IntroTipRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private enum OnboardingTutorialClip {
    case movementAndScale

    var resourceName: String {
        switch self {
        case .movementAndScale:
            return "movement_and_scale"
        }
    }
}

private struct OnboardingTutorialVideoView: View {
    let clip: OnboardingTutorialClip
    let missingTitle: String
    let missingDetail: String

    @StateObject private var controller: OnboardingTutorialVideoController

    init(clip: OnboardingTutorialClip, missingTitle: String, missingDetail: String) {
        self.clip = clip
        self.missingTitle = missingTitle
        self.missingDetail = missingDetail
        _controller = StateObject(wrappedValue: OnboardingTutorialVideoController(resourceName: clip.resourceName))
    }

    var body: some View {
        Group {
            if controller.isReady {
                VideoPlayer(player: controller.player)
                    .disabled(true)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: AppIcons.handsSparkles)
                        .font(.system(size: IconSize.hero))
                        .foregroundStyle(.secondary)
                    Text(missingTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(missingDetail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.06))
            }
        }
        .onAppear {
            controller.play()
        }
        .onDisappear {
            controller.pause()
        }
    }
}

@MainActor
private final class OnboardingTutorialVideoController: ObservableObject {
    let player = AVQueuePlayer()

    private var looper: AVPlayerLooper?

    var isReady: Bool {
        looper != nil
    }

    init(resourceName: String) {
        guard let videoURL = Self.videoURL(for: resourceName) else {
            return
        }

        let item = AVPlayerItem(url: videoURL)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
    }

    func play() {
        guard isReady else { return }
        player.play()
    }

    func pause() {
        player.pause()
    }

    private static func videoURL(for resourceName: String) -> URL? {
        Bundle.main.url(forResource: resourceName, withExtension: "mp4", subdirectory: "Resources/OnboardingVideos")
            ?? Bundle.main.url(forResource: resourceName, withExtension: "mp4", subdirectory: "OnboardingVideos")
            ?? Bundle.main.url(forResource: resourceName, withExtension: "mp4")
    }
}
