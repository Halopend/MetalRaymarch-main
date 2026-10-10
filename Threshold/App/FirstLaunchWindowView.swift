import SwiftUI
import AVKit
#if os(iOS)
import MediaPlayer
import UIKit
#endif

/// Four-page welcome flow:
///   0. Welcome (what Threshold is, what the app does)
///   1. Safety (photosensitive-epilepsy warning, must acknowledge)
///   2. Controls (movement + gestures on visionOS; navigation + creation elsewhere)
///   3. Setup (storage, audio connections, and anonymous analytics)
///
/// Each page uses one centered reading column and scrolls independently;
/// a shared footer pins Back/Next and the page indicator to the bottom so
/// they stay reachable at any window size. Deliberately NOT a TabView — on visionOS a TabView
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
    @State private var activeFormatPopover: String?

    private let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                Group {
                    switch currentPage {
                    case 0: welcomePage
                    case 1: safetyPage
                    case 2: controlsPage
                    default: storagePage
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(currentPage)

            Divider()

            navigationFooter
        }
        #if os(macOS)
        // A sheet sizes itself from its content. An unbounded frame lets the
        // scrolling page and the sheet repeatedly renegotiate their size,
        // clipping the safety warning and shifting the controls at launch.
        .frame(width: 780, height: 600)
        #elseif os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        .frame(minWidth: 680, idealWidth: 780, maxWidth: .infinity, minHeight: 500, idealHeight: 600, maxHeight: .infinity)
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
            .disabled(currentPage == 1 && !acknowledgedFlash)
            .accessibilityLabel(currentPage == pageCount - 1 ? "Start exploring" : "Next page")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var onboardingStepLabel: String {
        switch currentPage {
        case 0: "Overview"
        case 1: "Safety"
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

    // MARK: - Page 1: Safety

    private var safetyPage: some View {
        OnboardingPageShell(
            icon: AppIcons.boltTrianglebadgeExclamationmarkFill,
            title: "Flashing lights",
            subtitle: "Some scenes contain rapidly changing colors, gradients, and audio-driven flashes.",
            accent: .orange
        ) {
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
            }
        } detail: {
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

                Toggle(isOn: $acknowledgedFlash) {
                    Text("I understand that some scenes may contain flashing lights and audio-driven flashes.")
                        .font(.subheadline.weight(.medium))
                }
                .toggleStyle(OnboardingCheckboxStyle())
            }
        }
    }

    // MARK: - Page 0: Welcome

    private var welcomePage: some View {
        FirstLaunchWelcomePage()
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

                #if os(iOS)
                OnboardingAppleMusicConnection(manager: appModel.appleMusicManager)

                Divider()
                #endif

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: shareAnalytics ? AppIcons.person3Fill : AppIcons.personSlash)
                            .font(.title3)
                            .foregroundStyle(shareAnalytics ? .cyan : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Help improve Threshold")
                                .font(.headline)
                            Text("Share anonymous feature, quality, and performance totals.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("Share anonymous analytics", isOn: $shareAnalytics)
                        .tint(.cyan)

                    Text("Never includes your name, account, files, scene position, preset names, or custom distance-estimator details.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    Link("Privacy Policy", destination: URL(string: "https://github.com/Halopend/MetalRaymarch-main/blob/main/PRIVACY_POLICY.md")!)
                        .font(.caption)
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
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(isSelected ? .cyan : .secondary)
                    .frame(width: 32, height: 32)
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
            title: "Your first scene",
            subtitle: "Explore real-time fractals, distance fields, and geometry you can shape.",
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
                IntroTipRow(
                    icon: AppIcons.sliderHorizontal3,
                    title: "Edit the scene",
                    detail: "Use the floating controls to tune the fractal formula, combine it with signed distance field (SDF) primitives, and adjust color, light, and music response. Changes render live."
                )
                IntroTipRow(
                    icon: AppIcons.function,
                    title: "How the shape is rendered",
                    detail: "Distance estimators and SDFs tell the renderer how far a point is from geometry. Rays advance through those distances until they converge on a surface. Open Metal DE Studio to create or edit a formula."
                )
                fileFormatShareSection

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
            icon: "move.3d",
            title: "Your first scene",
            subtitle: "Explore real-time fractals, distance fields, and geometry you can shape.",
            accent: .green
        ) {
            VStack(alignment: .leading, spacing: 10) {
                IntroTipRow(
                    icon: "square.grid.2x2.fill",
                    title: "1. Choose a scene",
                    detail: "Open Explore and choose a built-in scene from Jumping Off."
                )
                IntroTipRow(
                    icon: "move.3d",
                    title: "2. Explore the viewport",
                    detail: viewportNavigationOnboardingDetail
                )
                IntroTipRow(
                    icon: AppIcons.sliderHorizontal3,
                    title: "3. Open Controls",
                    detail: phoneControlsOnboardingDetail
                )
            }
        } detail: {
            VStack(alignment: .leading, spacing: 10) {
                IntroTipRow(
                    icon: AppIcons.function,
                    title: "SDFs, fractals, and formulas",
                    detail: "Distance estimators and signed distance fields (SDFs) describe how far a point is from geometry. Rays advance through those distances until they converge on a surface. Combine fractals with SDF primitives, then use Metal DE Studio to create or edit a formula."
                )
                fileFormatShareSection
                IntroTipRow(
                    icon: "waveform",
                    title: "Music Reactive",
                    detail: "In Input, choose an audio source and map bands or beats to controls to make the scene respond."
                )
                IntroTipRow(
                    icon: AppIcons.filmStack,
                    title: "Animation Editor",
                    detail: "Capture parameter states as keyframes and preview the result."
                )
                Text("Use Find to jump to any control. Save a preset you like; Reset returns to its saved baseline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        #endif
    }

    private var fileFormatShareSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SAVE AND SHARE WHAT YOU MAKE")
                .font(.caption.weight(.bold))
                .tracking(1.1)
                .foregroundStyle(.blue)
            Text("Export scenes, animations, and custom formulas as JSON-based Threshold files. Select a format to see what it contains.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 8) {
                ForEach(ThresholdExportFormat.allCases, id: \.ext) { format in
                    Button {
                        activeFormatPopover = format.ext
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Image(systemName: format.iconName)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(format.accentColor)
                            Text(".\(format.ext)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Text(format.displayName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
                        .padding(9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(format.accentColor.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(format.accentColor.opacity(0.18), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel(".\(format.ext), \(format.displayName). Show file format details.")
                    .popover(isPresented: Binding(
                        get: { activeFormatPopover == format.ext },
                        set: { isPresented in
                            if !isPresented && activeFormatPopover == format.ext {
                                activeFormatPopover = nil
                            }
                        }
                    )) {
                        fileFormatDetails(for: format)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.blue.opacity(0.05))
        )
    }

    private func fileFormatDetails(for format: ThresholdExportFormat) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(".\(format.ext)", systemImage: format.iconName)
                .font(.headline)
                .foregroundStyle(format.accentColor)
            Text(format.displayName)
                .font(.subheadline.weight(.semibold))
            Text(fileFormatDescription(for: format))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    private func fileFormatDescription(for format: ThresholdExportFormat) -> String {
        switch format {
        case .scenePreset:
            return "A JSON scene document with render settings and optional audio mappings. It can also include a custom Metal distance estimator in its embeddedFormula field, keeping the scene and the formula that defines its geometry together in one shareable file."
        case .animationScene:
            return "A JSON animation scene containing its keyframe sequence and the scene state needed to load and play it in Threshold."
        case .customFormula:
            return "A versioned JSON container for a standalone custom Metal formula or effect. It carries the Metal source and formula metadata so it can be imported and reused in Threshold."
        }
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
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(isSelected ? .purple : .secondary.opacity(0.5))
                    .frame(width: 32, height: 32)
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

    private var viewportNavigationOnboardingDetail: String {
#if os(iOS)
        "Explore the scene directly in the viewport."
#else
        "Drag to orbit, right-drag to pan, scroll to zoom, or use WASD to move through the fractal."
#endif
    }

    private var phoneControlsOnboardingDetail: String {
#if os(iOS)
        "Tap Controls to tune the scene."
#else
        "Use the labeled Controls button over the renderer to open the creative workspace."
#endif
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
        guard acknowledgedFlash else { return }
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

private struct OnboardingCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(configuration.isOn ? Color.orange : Color.clear)
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.orange, lineWidth: 2)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 30, height: 30)

                configuration.label
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(configuration.isOn ? "Checked" : "Unchecked")
    }
}

struct OnboardingPageShell<Primary: View, Detail: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let accent: Color
    @ViewBuilder var primary: Primary
    @ViewBuilder var detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
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

            VStack(alignment: .leading, spacing: 18) {
                primary
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: 760, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
        .tint(accent)
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

#if os(iOS)
private struct OnboardingAppleMusicConnection: View {
    let manager: AppleMusicManager
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Apple Music", systemImage: "apple.logo")
                .font(.headline)
                .foregroundStyle(.pink)

            Text("Connect your library to choose songs and playlists in the Music controls.")
                .font(.caption)
                .foregroundStyle(.secondary)

            switch AppleMusicServiceAdapter(manager: manager).connectionStatus {
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            case .connecting:
                ProgressView("Connecting to Apple Music…")
                    .font(.caption)
            case .disconnected:
                connectButton
            case .error(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if manager.authorizationStatus == .denied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                    .buttonStyle(.bordered)
                } else if manager.authorizationStatus != .restricted {
                    connectButton
                }
            }

            Text("Optional. You can also connect later in the Music controls.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { manager.refreshAuthorizationStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                manager.refreshAuthorizationStatus()
            }
        }
    }

    private var connectButton: some View {
        Button("Connect to Apple Music") {
            manager.requestAuthorization()
        }
        .buttonStyle(.bordered)
        .tint(.pink)
    }
}
#endif

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
