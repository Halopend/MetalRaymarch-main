import SwiftUI
import AVKit

struct FirstLaunchWindowView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @AppStorage("hasCompletedIntroOnboarding") private var hasCompletedIntroOnboarding = false
    @State private var shareAnalytics = UsageAnalytics.shared.analyticsEnabled
    @State private var showAnalyticsDetail = false
    @State private var currentPage = 0

    var body: some View {
        VStack(spacing: 0) {
            // Page indicator
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(i == currentPage ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 8)

            TabView(selection: $currentPage) {
                welcomePage.tag(0)
                navigationPage.tag(1)
                analyticsPage.tag(2)
            }
            #if os(visionOS)
            .tabViewStyle(.automatic)
            #endif
        }
        .frame(minWidth: 580, maxWidth: 660, minHeight: 500, maxHeight: 620)
        .onAppear {
            shareAnalytics = UsageAnalytics.shared.analyticsEnabled
        }
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
                    detail: "Pinch, grab, and sculpt fractal parameters using natural hand tracking."
                )
                IntroTipRow(
                    icon: "waveform.path.ecg",
                    title: "Audio Reactive",
                    detail: "Connect to Apple Music and watch fractals pulse with the beat."
                )
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.06)))

            Spacer()

            HStack {
                Spacer()
                Button("Next") { withAnimation { currentPage = 1 } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    // MARK: - Page 2: Navigation Tutorial

    private var navigationPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("How to Move Around")
                    .font(.title2.weight(.bold))
                Text("Use your hands to navigate fractal space.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Navigation tutorial video
            navigationVideoPlayer
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
                    icon: "menucard",
                    title: "Open / Close Menu",
                    detail: "Use your menu toggle gesture anytime. You can customize it in Settings > General."
                )
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.06)))

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

    // MARK: - Navigation Video Player

    @ViewBuilder
    private var navigationVideoPlayer: some View {
        if let videoURL = Bundle.main.url(forResource: "NavigationTutorial", withExtension: "mp4") {
            let player = AVPlayer(url: videoURL)
            VideoPlayer(player: player)
                .onAppear { player.play() }
                .disabled(true)  // Prevent interaction — just a demo loop
        } else {
            // Fallback when video asset is not yet bundled
            VStack(spacing: 12) {
                Image(systemName: "hands.sparkles")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Navigation tutorial video")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("Place NavigationTutorial.mp4 in the bundle to show a walkthrough here.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.secondary.opacity(0.06))
        }
    }

    // MARK: - Page 3: Analytics Consent

    private var analyticsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Anonymous Usage Data")
                    .font(.title2.weight(.bold))
                Text("Your choice — off by default.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Prominent opt-in card
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.title3)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Help Improve Threshold")
                            .font(.headline)
                        Text("Share anonymous usage stats to help us prioritize features and improve performance.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Send anonymous usage data", isOn: $shareAnalytics)
                    .tint(.blue)

                // What we collect / don't collect
                VStack(alignment: .leading, spacing: 6) {
                    Label("What's shared:", systemImage: "checkmark.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("• Which fractals and color schemes are popular\n• Average performance (FPS) per device\n• Which features are used (gestures, audio, SharePlay)\n• Preset parameter averages (no personal content)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Label("Never shared:", systemImage: "xmark.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    Text("• No names, emails, or Apple IDs\n• No location or IP address\n• No photos, recordings, or personal files\n• No data sold to third parties")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Button {
                    showAnalyticsDetail.toggle()
                } label: {
                    HStack {
                        Text("Technical details")
                            .font(.caption2)
                        Image(systemName: showAnalyticsDetail ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                if showAnalyticsDetail {
                    Text("Data is stored in Apple's CloudKit public database under your app's iCloud container. Each upload is a timestamped snapshot of aggregated session metrics — no user identifier is attached. You can toggle this off anytime in Settings > General.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.blue.opacity(0.15), lineWidth: 1)
            )

            Text("You can change this anytime in Settings > General.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer()

            HStack {
                Button("Back") { withAnimation { currentPage = 1 } }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Start Exploring", action: completeOnboarding)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    private func completeOnboarding() {
        UsageAnalytics.shared.analyticsEnabled = shareAnalytics
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
            Image(systemName: icon)
                .font(.caption)
                .frame(width: 16)
                .foregroundStyle(.secondary)
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
