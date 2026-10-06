import SwiftUI

/// The welcome copy lives in its own source file so copy and epigraph iteration
/// doesn't recompile the rest of the first-launch flow.
struct FirstLaunchWelcomePage: View {
    var body: some View {
        OnboardingPageShell(
            icon: "cube.transparent.fill",
            title: "Welcome to Threshold",
            subtitle: "A real-time instrument for exploring fractals, distance estimators, and higher-dimensional mathematics.",
            accent: .blue
        ) {
            VStack(alignment: .leading, spacing: 18) {
                epigraph
                VStack(alignment: .leading, spacing: 14) {
                    Text("AN EXPERIMENT IN REAL-TIME FRACTALS")
                        .font(.caption.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(.blue)
                    Text("Threshold began as an experiment in real-time fractal rendering. It grew into a way to investigate the mathematics behind each image: how distance estimators guide a ray, how repeated rules shape a form, and how simple operations produce patterns between order and chaos.\n\nEach view is computed through a finite number of iterations. By changing the rules and observing what follows, we can build intuition for fractals and higher-dimensional mathematics. The exploration continues.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.blue.opacity(0.18), .purple.opacity(0.10)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.blue.opacity(0.22), lineWidth: 1)
                )
            }
        } detail: {
            VStack(alignment: .leading, spacing: 8) {
                Text("FROM ITERATION TO IMAGE")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.purple)
                Text("Fractal formulas apply a rule repeatedly. Threshold calculates each view through a finite number of iterations—the computation that makes real-time exploration possible. In Metal DE Studio, you can work directly with a distance-estimator formula and see its mathematics take shape.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.purple.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.purple.opacity(0.18), lineWidth: 1)
            )
        }
    }

    private var epigraph: some View {
        VStack(alignment: .center, spacing: 10) {
            Text("To see a world in a grain of sand\nAnd a heaven in a wild flower,\nHold infinity in the palm of your hand\nAnd eternity in an hour.")
                .font(.system(size: 22, weight: .regular, design: .serif))
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("— William Blake, “Auguries of Innocence”")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
        .padding(.vertical, 8)
    }
}
