import SwiftUI
import AVKit

/// Four-page welcome flow:
///   0. Safety (photosensitive-epilepsy warning, must acknowledge)
///   1. Welcome (what Threshold is, what the app does)
///   2. Controls (movement + gestures on visionOS; navigation + creation elsewhere)
///   3. Setup (storage, microphone-at-launch, and anonymous analytics)
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
    @Environment(\.dismiss) private var dismiss

    @AppStorage("hasCompletedIntroOnboarding") private var hasCompletedIntroOnboarding = false

    /// Per-page state, kept here because the page views are local to this
    /// struct and don't need to survive a re-render.
    @State private var currentPage = 0
    @State private var acknowledgedFlash = false
    @State private var leftHanded = false
    @State private var menuGestureStyle: MenuGestureStarterStyle = .palmer
    @State private var shareAnalytics = UsageAnalytics.shared.analyticsEnabled
    @State private var storageMode = StorageLocation.shared.mode
    @State private var microphoneStartsAtLaunch = AudioInputLaunchPreference.microphoneStartsAtLaunch()

    private let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Group {
                    switch currentPage {
                    case 0: safetyPage
                    case 1: welcomePage
                    case 2: controlsPage
                    default: storagePage
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .animation(.default, value: currentPage)

            Divider()

            navigationFooter
        }
        #if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        .frame(minWidth: 720, idealWidth: 940, maxWidth: .infinity, minHeight: 540, idealHeight: 660, maxHeight: .infinity)
        #endif
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
            storageMode = StorageLocation.shared.mode
            microphoneStartsAtLaunch = AudioInputLaunchPreference.microphoneStartsAtLaunch()
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
        case 2: "Controls"
        default: "Setup"
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

    private var welcomeSubtitle: String {
        #if os(visionOS)
        "Explore infinite fractal worlds in spatial computing."
        #else
        "Explore, shape, animate, and save infinite GPU-rendered fractal worlds."
        #endif
    }

    private var welcomeWorkflowSummary: String {
        #if os(visionOS)
        "Start with curated scenes, then shape them with hands, audio, and parameter controls."
        #else
        "Start with curated scenes, then shape them with the control workspace, audio, and precise parameter tools."
        #endif
    }

    private var welcomePage: some View {
        OnboardingPageShell(
            icon: "cube.transparent.fill",
            title: "Threshold",
            subtitle: welcomeSubtitle,
            accent: .blue
        ) {
            VStack(alignment: .leading, spacing: 12) {
                IntroTipRow(
                    icon: "cube.transparent.fill",
                    title: "Raymarched Fractals",
                    detail: "Real-time GPU-rendered 3D fractals you can fly through, reshape, animate, and save."
                )
                #if os(visionOS)
                IntroTipRow(
                    icon: "hand.raised.fingers.spread",
                    title: "Hand Gesture Controls",
                    detail: "Pinch, grab, and sculpt fractal parameters using natural hand tracking. More on the next pages."
                )
                #else
                IntroTipRow(
                    icon: AppIcons.magnifyingglass,
                    title: "Find Any Control",
                    detail: "Search by feature or intent, then jump directly to the right workspace and section."
                )
                #endif
                IntroTipRow(
                    icon: "arrow.counterclockwise.circle",
                    title: "Reset + Create",
                    detail: "Tap Reset to jump back to your saved baseline. Use Save to create a named preset or deliberately update that reset point."
                )
            }
        } detail: {
            VStack(alignment: .leading, spacing: 14) {
                Text(welcomeWorkflowSummary)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("You can always return to this window from Settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    IntroPill(icon: "square.grid.2x2.fill", title: "Scenes")
                    #if os(visionOS)
                    IntroPill(icon: "hand.raised.fingers.spread", title: "Hands")
                    #else
                    IntroPill(icon: AppIcons.magnifyingglass, title: "Find")
                    #endif
                    IntroPill(icon: "waveform", title: "Music")
                }
            }
        }
    }

    // MARK: - Page 3: Storage + Audio + Analytics

    private var storagePage: some View {
        OnboardingPageShell(
            icon: "externaldrive.badge.icloud",
            title: "Finish setup",
            subtitle: "Choose storage, live audio, and anonymous analytics preferences in one place.",
            accent: .cyan
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(StorageMode.allCases, id: \.self) { mode in
                    storageModeCard(mode)
                }
            }
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                Label("Launch preferences", systemImage: "switch.2")
                    .font(.headline)

                Text("Storage can be changed later and both locations are merged. A local safety backup is always kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: microphoneStartsAtLaunch ? "mic.fill" : "mic")
                            .font(.title3)
                            .foregroundStyle(microphoneStartsAtLaunch ? .cyan : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Live audio input")
                                .font(.headline)
                            Text("Use microphone levels to drive audio-reactive scenes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("Start microphone at launch", isOn: $microphoneStartsAtLaunch)
                        .tint(.cyan)
                        .help("Automatically start microphone input when Threshold opens.")

                    Text("Threshold will request microphone access when you finish setup. You can change this anytime in the Music controls.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: shareAnalytics ? AppIcons.person3Fill : AppIcons.personSlash)
                            .font(.title3)
                            .foregroundStyle(shareAnalytics ? .blue : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Help improve Threshold")
                                .font(.headline)
                            Text("Share anonymous feature, quality, and performance totals.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("Share anonymous analytics", isOn: $shareAnalytics)
                        .tint(.blue)

                    Text("Never includes your name, account, files, scene position, preset names, or custom distance-estimator details.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func storageModeCard(_ mode: StorageMode) -> some View {
        let isSelected = storageMode == mode
        return Button {
            storageMode = mode
        } label: {
            HStack(spacing: 12) {
                Image(systemName: mode.iconName)
                    .font(.title2)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.displayName)
                        .font(.headline)
                    Text(mode == .local
                         ? "Stored privately on this device."
                         : "Synced across your devices and available in the Files app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .cyan : .secondary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.cyan.opacity(0.14) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.cyan.opacity(0.6) : Color.secondary.opacity(0.12), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Page 2: Controls + Creation

    private var controlsPage: some View {
        #if os(visionOS)
        OnboardingPageShell(
            icon: "move.3d",
            title: "Move and open controls",
            subtitle: "Learn the core movement gestures and choose how to summon the floating controls.",
            accent: .green
        ) {
            VStack(alignment: .leading, spacing: 12) {
                movementTutorialVideoPlayer
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                    )

                Picker("Dominant hand", selection: $leftHanded) {
                    Label("Left", systemImage: AppIcons.handRaisedFingersSpread).tag(true)
                    Label("Right", systemImage: AppIcons.handRaisedFingersSpreadFill).tag(false)
                }
                .pickerStyle(.segmented)
                .onChange(of: leftHanded) { _, newValue in
                    appModel.renderSettings.leftHandedMode = newValue
                }
            }
        } detail: {
            VStack(alignment: .leading, spacing: 10) {
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

                Divider()

                Text("Open the controls")
                    .font(.headline)
                ForEach(MenuGestureStarterStyle.allCases) { style in
                    menuGestureStyleCard(style)
                }
            }
        }
        #else
        OnboardingPageShell(
            icon: AppIcons.sliderHorizontal3,
            title: "Navigate and create",
            subtitle: "Find any control, experiment freely, and keep reliable return points.",
            accent: .green
        ) {
            VStack(alignment: .leading, spacing: 10) {
                IntroTipRow(
                    icon: AppIcons.sliderHorizontal3,
                    title: "Controls",
                    detail: "Use the labeled Controls button over the renderer to open the creative workspace."
                )
                IntroTipRow(
                    icon: AppIcons.magnifyingglass,
                    title: "Find",
                    detail: "Search for a control by name or intent—try fog, FPS, export, gradient, or animation."
                )
                IntroTipRow(
                    icon: AppIcons.pin,
                    title: "Quick Access",
                    detail: "Pin the sections you revisit so they remain one click away in the rail."
                )
            }
        } detail: {
            VStack(alignment: .leading, spacing: 10) {
                IntroTipRow(
                    icon: AppIcons.arrowCounterclockwise,
                    title: "Reset",
                    detail: "Return the current fractal to its saved baseline."
                )
                IntroTipRow(
                    icon: AppIcons.plusCircleFill,
                    title: "Save",
                    detail: "Create a named preset, include a preview, or deliberately update the Reset point."
                )
                IntroTipRow(
                    icon: AppIcons.filmStack,
                    title: "Animation Editor",
                    detail: "Capture parameter states as keyframes and preview the result."
                )
            }
        }
        #endif
    }

    /// One selectable menu-gesture style card on the combined controls page.
    /// Tapping it updates both
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
        // Persist the state the user just configured: storage, microphone launch,
        // analytics toggle, handedness, and menu-open gesture. (Handedness and the
        // gesture are also written live on change, so this is belt-and-braces.)
        // The acknowledgement checkbox is intentionally not persisted — it's a
        // one-time consent, not a setting.
        if storageMode == StorageLocation.shared.mode {
            StorageLocation.shared.markModeChosen()
        } else {
            appModel.switchStorageMode(to: storageMode)
        }
        UserDefaults.standard.set(
            microphoneStartsAtLaunch,
            forKey: AudioInputLaunchPreference.microphoneStartsAtLaunchDefaultsKey
        )
        if microphoneStartsAtLaunch {
            // The normal launch hook has already run by the time first-launch
            // onboarding completes, so begin capture now as well as persisting
            // the preference for subsequent launches.
            Task { @MainActor in
                _ = await appModel.audioHub.start(.microphone)
            }
        }
        UsageAnalytics.shared.analyticsEnabled = shareAnalytics
        appModel.renderSettings.leftHandedMode = leftHanded
        appModel.renderSettings.menuToggleGestureMode = menuGestureStyle.mode
        hasCompletedIntroOnboarding = true
        #if os(iOS)
        dismiss()
        #else
        openWindow(id: appModel.menuWindowID)
        dismissWindow(id: AppModel.onboardingWindowID)
        #endif
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(accent.opacity(0.16))
                    Image(systemName: icon)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.title.weight(.bold))
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    primary
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 12) {
                    detail
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(24)
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
