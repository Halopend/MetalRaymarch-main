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
    @State private var isShowingMusicCueGroupEditor = false

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 10) {
                    headerSection
                    transitionTimeSection
                    musicCueSceneSection
                }
                .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $isShowingMusicCueGroupEditor) {
            MusicCueSceneGroupEditor(animationManager: animationManager)
        }
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
                Label("Same Scene Transition Time", systemImage: AppIcons.timer)
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

    private var musicCueSceneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Cue Scene Switcher", systemImage: "rectangle.stack.badge.play")
                    .font(.subheadline.bold())
                Spacer()
                Text(animationManager.musicCueSceneGroupSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("Combine scene sources, then choose how music cues and the canvas arrow keys select the next scene.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Scene Sources")
                    .font(.caption.bold())

                ForEach(MusicCueSceneSource.allCases) { source in
                    Toggle(isOn: sceneSourceBinding(for: source)) {
                        HStack(spacing: 8) {
                            Image(systemName: source.systemImage)
                                .foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(source.displayName)
                                    .font(.caption)
                                Text(source.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tint(.purple)
                }

                Text("Active: \(animationManager.musicCueSceneSourceSummary). Sources can be combined; duplicate scenes are used once.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))

            HStack {
                Button {
                    isShowingMusicCueGroupEditor = true
                } label: {
                    Label("Configure Group", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)

                Picker("Selection", selection: $animationManager.musicCueSceneTraversalMode) {
                    ForEach(MusicCueSceneTraversalMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }

            Text(animationManager.musicCueSceneTraversalMode.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Toggle(isOn: $animationManager.musicCueSceneSwitchEnabled) {
                Label("Advance Scene on Music Cue", systemImage: "music.note.list")
                    .font(.subheadline.bold())
            }
            .tint(.purple)

            Text("A qualifying Drop cue uses this selection setup. Use ← or → while the canvas has focus to step the same pool manually.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let warning = animationManager.musicCueSceneSelectionWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if animationManager.musicCueSceneSwitchEnabled {
                VStack(spacing: 8) {
                    HStack {
                        Text("Required Drop")
                            .font(.caption)
                        Spacer()
                        Text(cueThresholdLabel)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $animationManager.musicCueThreshold,
                        in: 0.05...1,
                        step: 0.05
                    )

                    Text("Lower values trigger more readily.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack {
                        Text("Minimum Gap")
                            .font(.caption)
                        Spacer()
                        Text(cueMinimumIntervalLabel)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $animationManager.musicCueMinimumInterval,
                        in: 0...30,
                        step: 0.5
                    )
                }
            }

            if let nextSceneName = animationManager.nextMusicCueSceneName {
                Label("Next: \(nextSceneName)", systemImage: "forward.end.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Previous", systemImage: "backward.end.fill") {
                        _ = animationManager.stepMusicCueSceneGroup(by: -1)
                    }
                    .disabled(!animationManager.canStepMusicCueSceneGroupBackward)

                    Button("Next Scene", systemImage: "forward.end.fill") {
                        _ = animationManager.advanceToNextSceneForMusicCue()
                    }
                    .disabled(!animationManager.canStepMusicCueSceneGroup)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.purple.opacity(0.06)))
    }

    private var durationLabel: String {
        if animationManager.sceneTransitionDuration <= 0 {
            return "Off"
        }
        return String(format: "%.2f s", animationManager.sceneTransitionDuration)
    }

    private var cueThresholdLabel: String {
        "\(Int((animationManager.musicCueThreshold * 100).rounded()))%"
    }

    private var cueMinimumIntervalLabel: String {
        String(format: "%.1f s", animationManager.musicCueMinimumInterval)
    }

    private func sceneSourceBinding(for source: MusicCueSceneSource) -> Binding<Bool> {
        Binding(
            get: { animationManager.isMusicCueSceneSourceEnabled(source) },
            set: { animationManager.setMusicCueSceneSource(source, isEnabled: $0) }
        )
    }
}

private struct MusicCueSceneGroupEditor: View {
    let animationManager: AnimationManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTag: String?

    var body: some View {
        NavigationStack {
            List {
                if targets.isEmpty {
                    ContentUnavailableView(
                        "No Switchable Scenes",
                        systemImage: "rectangle.stack.badge.play",
                        description: Text("Add keyframes to an animation or save a static scene before adding it to the cue group.")
                    )
                } else {
                    Section {
                        Text("Use tags to find a collection quickly, then select the visible scenes together. Enable Configured Group in the Transition menu to use this curated set alone or combine it with either library.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !availableTags.isEmpty {
                        tagFilterSection
                    }

                    if visibleTargets.isEmpty {
                        Section {
                            Text("No scenes use this tag.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        if !visibleAnimationTargets.isEmpty {
                            targetSection("Animation Sequences", targets: visibleAnimationTargets)
                        }

                        if !visibleStaticSceneTargets.isEmpty {
                            targetSection("Static Scenes", targets: visibleStaticSceneTargets)
                        }
                    }
                }
            }
            .navigationTitle("Cue Scene Group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") {
                        animationManager.clearMusicCueSceneGroup()
                    }
                    .disabled(animationManager.musicCueSceneGroupTargetIDs.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Select All") {
                        animationManager.selectAllMusicCueTargets()
                    }
                    .disabled(targets.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var targets: [MusicCueSceneTarget] {
        animationManager.musicCueGroupAvailableTargets
    }

    private var availableTags: [String] {
        Array(Set(SceneTagging.normalized(targets.flatMap(\.tags))))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var visibleTargets: [MusicCueSceneTarget] {
        guard let selectedTag else { return targets }
        return targets.filter { SceneTagging.contains($0.tags, tag: selectedTag) }
    }

    private var visibleAnimationTargets: [MusicCueSceneTarget] {
        visibleTargets.filter { $0.kind == .animation }
    }

    private var visibleStaticSceneTargets: [MusicCueSceneTarget] {
        visibleTargets.filter { $0.kind == .staticScene }
    }

    private var tagFilterSection: some View {
        Section("Filter by Tag") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button("All") {
                        selectedTag = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(selectedTag == nil ? .purple : .secondary)

                    ForEach(availableTags, id: \.self) { tag in
                        Button {
                            selectedTag = tag
                        } label: {
                            SceneTagPill(
                                tag: tag,
                                isSelected: selectedTag?.caseInsensitiveCompare(tag) == .orderedSame
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Text(selectedTag == nil
                     ? "Showing all scenes"
                     : "Showing \(visibleTargets.count) tagged scenes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Select Visible") {
                    animationManager.selectMusicCueTargets(visibleTargets)
                }
                .buttonStyle(.bordered)
                Button("Clear Visible") {
                    animationManager.clearMusicCueTargets(visibleTargets)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func targetSection(_ title: String, targets: [MusicCueSceneTarget]) -> some View {
        Section(title) {
            ForEach(targets) { target in
                Toggle(isOn: selectionBinding(for: target)) {
                    HStack(spacing: 8) {
                        Image(systemName: target.kind.systemImage)
                            .foregroundStyle(target.kind == .animation ? .purple : .blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(target.name)
                            Text(target.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            SceneTagRow(tags: target.tags)
                        }
                    }
                }
            }
        }
    }

    private func selectionBinding(for target: MusicCueSceneTarget) -> Binding<Bool> {
        Binding(
            get: { animationManager.isMusicCueTargetSelected(target) },
            set: { animationManager.setMusicCueTarget(target, isSelected: $0) }
        )
    }
}
