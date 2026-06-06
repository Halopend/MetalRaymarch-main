//
//  TransitionTabContent.swift
//  Threshold
//
//  Controls for smoothed scene transitions. Hosts the
//  "Same Scene Transition Time" slider which eases live parameters
//  toward a newly selected scene's starting keyframe over time.
//

import SwiftUI

struct TransitionTabContent: View {
    @Bindable var animationManager: AnimationManager

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 10) {
                    headerSection
                    transitionTimeSection
                }
                .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scene Transitions")
                .font(.subheadline.bold())
            Text("Smoothly ease parameters toward a new scene's starting point instead of jumping instantly.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.08)))
    }

    private var transitionTimeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Same Scene Transition Time", systemImage: "timer")
                    .font(.subheadline.bold())
                Spacer()
                Text(durationLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: $animationManager.sceneTransitionDuration,
                in: 0...3,
                step: 0.05
            )

            Text(animationManager.sceneTransitionDuration <= 0
                 ? "Off — scenes switch instantly."
                 : "Parameters play out over time toward the new starting point.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private var durationLabel: String {
        if animationManager.sceneTransitionDuration <= 0 {
            return "Off"
        }
        return String(format: "%.2f s", animationManager.sceneTransitionDuration)
    }
}
