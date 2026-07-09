import SwiftUI
import AVKit

/// Five-page welcome flow:
///   0. Safety (photosensitive-epilepsy warning, must acknowledge)
///   1. Welcome (what Threshold is, what the app does)
///   2. Hand controls (movement video + handedness)
///   3. Fingers (per-finger actions, read-only) + menu-open gesture picker
///   4. Sharing (analytics on by default; user can opt out + username)
///
/// Each page scrolls independently; a shared footer pins Back/Next and
/// the page indicator to the bottom so they stay reachable at any
/// window size. Deliberately NOT a TabView — on visionOS a TabView
/// grows a left tab-bar ornament with blank icons.
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
            ScrollView {
                Group {
                    switch currentPage {
                    case 0: safetyPage
                    case 1: welcomePage
                    case 2: controlsPage
                    case 3: fingersPage
                    default: sharingPage
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .animation(.default, value: currentPage)

            Divider()

            navigationFooter
        }
        .frame(minWidth: 760, idealWidth: 1040, maxWidth: .infinity, minHeight: 620, idealHeight: 780, maxHeight: .infinity)
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

    // MARK: - Navigation footer

    /// Shared bottom bar: large Back/Next buttons flanking simple page
    /// dots. Buttons get a generous minimum size so they're easy to hit
    /// (especially with eye/hand targeting on visionOS).
    private var navigationFooter: some View {
        HStack(spacing: 16) {
            Button {
                withAnimation { currentPage -= 1 }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline.weight(.semibold))
                    .frame(width: 44, height: 36)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .opacity(currentPage == 0 ? 0 : 1)
            .disabled(currentPage == 0)
            .accessibilityLabel("Previous page")

            Spacer()

            VStack(spacing: 6) {
                Text(onboardingStepLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(0..<pageCount, id: \.self) { i in
                        Capsule()
                            .fill(i == currentPage ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(width: i == currentPage ? 24 : 8, height: 7)
                            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: currentPage)
                            .accessibilityLabel("Page \(i + 1) of \(pageCount)")
                    }
                }
            }

            Spacer()

            Button {
                if currentPage == pageCount - 1 {
                    completeOnboarding()
                } else {
                    withAnimation { currentPage += 1 }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(currentPage == pageCount - 1 ? "Start" : "Continue")
                    Image(systemName: currentPage == pageCount - 1 ? "sparkles" : "chevron.right")
                }
                .font(.headline.weight(.semibold))
                .frame(minWidth: 128, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(currentPage == 0 && !acknowledgedFlash)
            .accessibilityLabel(currentPage == pageCount - 1 ? "Start exploring" : "Next page")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var onboardingStepLabel: String {
        switch currentPage {
        case 0: "Safety"
        case 1: "Overview"
        case 2: "Movement"
        case 3: "Gestures"
        default: "Sharing"
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
        OnboardingPageShell(
            icon: AppIcons.boltTrianglebadgeExclamationmarkFill,
            title: "Flashing lights",
            subtitle: "Some scenes contain rapidly changing colors, gradients, and audio-driven flashes.",
            accent: .orange
        ) {
            VStack(alignment: .leading, spacing: 14) {
                IntroTipRow(
                    icon: "waveform.path.ecg",
                    title: "Audio-reactive flashes",
                    detail: "Bass hits and beat onsets can drive lights in time with the audio."
                )
                IntroTipRow(
                    icon: "slider.horizontal.3",
                    title: "You stay in control",
                    detail: "Lower audio amounts, reduce bloom, or disable reactive mappings if the scene feels uncomfortable."
                )
                IntroTipRow(
                    icon: "eye.trianglebadge.exclamationmark",
                    title: "Stop immediately",
                    detail: "Stop using Threshold if you feel dizziness, nausea, vision changes, twitching, or disorientation."
                )
            }
        } detail: {
            VStack(alignment: .leading, spacing: 16) {
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
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))

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
            }
        }
    }

    // MARK: - Page 1: Welcome

    private var welcomePage: some View {
        OnboardingPageShell(
            icon: "cube.transparent.fill",
            title: "Threshold",
            subtitle: "Explore infinite fractal worlds in spatial computing.",
            accent: .blue
        ) {
            VStack(alignment: .leading, spacing: 12) {
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
        } detail: {
            VStack(alignment: .leading, spacing: 14) {
                Text("Start with curated scenes, then shape them with hands, audio, and parameter controls.")
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("You can always return to this window from Settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    IntroPill(icon: "square.grid.2x2.fill", title: "Scenes")
                    IntroPill(icon: "hand.raised.fingers.spread", title: "Hands")
                    IntroPill(icon: "waveform", title: "Music")
                }
            }
        }
    }

    // MARK: - Page 2: Hand Controls + Handedness

    private var controlsPage: some View {
        OnboardingPageShell(
            icon: "move.3d",
            title: "Movement and scale",
            subtitle: "Use both hands to translate, scale, and orbit through fractal space.",
            accent: .green
        ) {
            movementTutorialVideoPlayer
                .frame(maxWidth: .infinity)
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )
        } detail: {
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
        }
    }

    // MARK: - Page 3: Per-Finger Actions (read-only)

    /// Shows the user which finger currently triggers which action, and
    /// which gesture opens/closes the menu. The chips are read-only here
    /// — full editing lives in Settings > Gestures. The intro just makes
    /// the mapping obvious so the user knows what to expect.
    private var fingersPage: some View {
        OnboardingPageShell(
            icon: "hand.tap.fill",
            title: "Finger shortcuts",
            subtitle: "Tap any finger to your palm to trigger its assigned action.",
            accent: .purple
        ) {
            VStack(spacing: 6) {
                ForEach(0..<5, id: \.self) { finger in
                    fingerAssignmentRow(finger: finger)
                }
            }
        } detail: {
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
        }
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
        OnboardingPageShell(
            icon: shareAnalytics ? AppIcons.person3Fill : AppIcons.personSlash,
            title: "Community sharing",
            subtitle: "Threshold can share settings snapshots for future community collections. No account, email, or location.",
            accent: .blue
        ) {
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

            }
        } detail: {
            VStack(alignment: .leading, spacing: 8) {
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
        }
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

private struct OnboardingPageShell<Primary: View, Detail: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let accent: Color
    @ViewBuilder var primary: Primary
    @ViewBuilder var detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(accent.opacity(0.16))
                    Image(systemName: icon)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.title.weight(.bold))
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    primary
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 12) {
                    detail
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 500, alignment: .topLeading)
        .padding(28)
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

private struct IntroPill: View {
    let icon: String
    let title: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.secondary.opacity(0.10)))
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
