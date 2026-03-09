import SwiftUI

struct FirstLaunchWindowView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @AppStorage("hasCompletedIntroOnboarding") private var hasCompletedIntroOnboarding = false
    @State private var shareAnalytics = UsageAnalytics.shared.analyticsEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Threshold")
                    .font(.title2.weight(.bold))
                Text("Quick setup before you jump in")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Community Highlights", systemImage: "person.3.sequence.fill")
                    .font(.headline)
                Text("Share anonymized preset and settings usage to help power future randomizer picks from community highlights.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Share anonymized usage", isOn: $shareAnalytics)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.08)))

            VStack(alignment: .leading, spacing: 8) {
                Label("How to Move Around", systemImage: "hand.raised.fingers.spread")
                    .font(.headline)
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
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.08)))

            Text("You can change these anytime in Settings.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack {
                Spacer()
                Button("Start Exploring", action: completeOnboarding)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 560, maxWidth: 640)
        .onAppear {
            shareAnalytics = UsageAnalytics.shared.analyticsEnabled
        }
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
