//
//  TransitionTabContent.swift
//  Threshold
//
//  Controls for smoothed scene transitions. Hosts the
//  "Same Scene Transition Time" slider which eases live parameters
//  toward a newly selected scene's starting keyframe over time, and the
//  Cue Scene Switcher's saved scene sets — named subsets of scenes the
//  performer can switch between, optionally driven by an attached song.
//

import SwiftUI

struct TransitionTabContent: View {
    @Bindable var animationManager: AnimationManager
    var musicService: MusicService?

    private struct EditingSet: Identifiable {
        let id: UUID
    }
    @State private var editingSet: EditingSet?

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 10) {
                    headerSection
                    transitionTimeSection
                    sceneSetsSection
                    musicCueSceneSection
                }
                .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $editingSet) { editing in
            MusicCueSceneSetEditor(
                animationManager: animationManager,
                musicService: musicService,
                setID: editing.id
            )
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Move Between Scenes")
                .font(.subheadline.bold())
            Text("Choose how one scene gives way to the next, then decide which scenes are in the rotation.")
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
                Label("Blend Duration", systemImage: AppIcons.timer)
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
                 : "The current look eases into the next scene instead of jumping.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    // MARK: Scene sets

    private var sceneSetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Collections", systemImage: "square.stack.3d.up")
                    .font(.subheadline.bold())
                Spacer()
                Button {
                    let set = animationManager.createMusicCueSceneSet()
                    editingSet = EditingSet(id: set.id)
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text("A collection is a reusable rotation of animated and still scenes. Make one active to use it with arrow keys or music cues.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if animationManager.musicCueSceneSets.isEmpty {
                Text("No collections yet. Create one and choose the scenes you want to move between.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(animationManager.musicCueSceneSets) { set in
                        sceneSetRow(set)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.teal.opacity(0.06)))
    }

    private func sceneSetRow(_ set: MusicCueSceneSet) -> some View {
        let isActive = animationManager.activeMusicCueSceneSetID == set.id
        return HStack(spacing: 8) {
            Button {
                animationManager.activateMusicCueSceneSet(set.id)
            } label: {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isActive ? .teal : .secondary)
            }
            .buttonStyle(.plain)
            .help(isActive ? "Active collection" : "Make this collection active")

            Button {
                editingSet = EditingSet(id: set.id)
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(set.name)
                            .font(.caption.bold())
                            .foregroundStyle(.primary)
                        Text(sceneSetDetail(set))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit this collection")

            if set.attachedSong != nil {
                Button {
                    animationManager.startMusicCueSceneSet(set.id)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.teal)
                }
                .buttonStyle(.plain)
                .help("Start this set: play its song and advance scenes on music cues")
            }

            Menu {
                Button("Edit Collection", systemImage: "slider.horizontal.3") {
                    editingSet = EditingSet(id: set.id)
                }
                Button(role: .destructive) {
                    animationManager.deleteMusicCueSceneSet(set.id)
                } label: {
                    Label("Delete Collection", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.teal.opacity(0.12) : Color.primary.opacity(0.035))
        )
    }

    private func sceneSetDetail(_ set: MusicCueSceneSet) -> String {
        let count = set.targetIDs.count
        let scenes = count == 1 ? "1 scene" : "\(count) scenes"
        if let song = set.attachedSong {
            return "\(scenes) · \(song.title) — \(song.artist)"
        }
        return scenes
    }

    // MARK: Cue switcher

    private var musicCueSceneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Scene Rotation", systemImage: "rectangle.stack.badge.play")
                    .font(.subheadline.bold())
                Spacer()
                Text(animationManager.musicCueSceneGroupSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("Choose how the next scene is selected. Animated scenes move through keyframes; still scenes hold one saved look.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Picker("Play Order", selection: $animationManager.musicCueSceneTraversalMode) {
                ForEach(MusicCueSceneTraversalMode.allCases) { mode in
                    Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.menu)

            Text(animationManager.musicCueSceneTraversalMode.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Toggle(isOn: $animationManager.musicCueSceneSwitchEnabled) {
                Label("Advance on Music Cues", systemImage: "music.note.list")
                    .font(.subheadline.bold())
            }
            .tint(.purple)

            Text("Use ← or → while the canvas has focus to move through this same rotation manually.")
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
                        Text("Cue Strength")
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
                        Text("Time Between Changes")
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
}

// MARK: - Set editor

private struct MusicCueSceneSetEditor: View {
    let animationManager: AnimationManager
    let musicService: MusicService?
    let setID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTag: String?
    @State private var showSongPicker = false

    var body: some View {
        NavigationStack {
            List {
                nameSection
                songSection

                if targets.isEmpty {
                    ContentUnavailableView(
                        "No Scenes Available",
                        systemImage: "rectangle.stack.badge.play",
                        description: Text("Create an animated scene with at least two keyframes, or save a still scene, then return here.")
                    )
                } else {
                    Section {
                        Text("Choose the scenes in this collection. Animated scenes play their keyframes; still scenes keep one saved look.")
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
                            targetSection("Animated Scenes", targets: visibleAnimationTargets)
                        }

                        if !visibleStaticSceneTargets.isEmpty {
                            targetSection("Still Scenes", targets: visibleStaticSceneTargets)
                        }
                    }
                }
            }
            .navigationTitle("Edit Collection")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") {
                        animationManager.clearMusicCueSceneSetTargets(in: setID)
                    }
                    .disabled(editedSet?.targetIDs.isEmpty ?? true)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Select All") {
                        animationManager.selectAllMusicCueTargets(in: setID)
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
        .sheet(isPresented: $showSongPicker) {
            SongPickerSheet(musicService: musicService) { track in
                Task {
                    guard let musicService else { return }
                    let attachment = await musicService.makeAttachment(from: track)
                    animationManager.setAttachedSong(attachment, forMusicCueSceneSet: setID)
                }
            }
        }
    }

    private var editedSet: MusicCueSceneSet? {
        animationManager.musicCueSceneSet(id: setID)
    }

    private var nameSection: some View {
        Section("Name") {
            TextField(
                "Set name",
                text: Binding(
                    get: { editedSet?.name ?? "" },
                    set: { animationManager.renameMusicCueSceneSet(setID, to: $0) }
                )
            )
        }
    }

    @ViewBuilder
    private var songSection: some View {
        Section("Attached Song") {
            if let song = editedSet?.attachedSong {
                HStack(spacing: 8) {
                    Image(systemName: AppIcons.musicNote)
                        .foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(song.title).font(.caption).lineLimit(1)
                        Text(song.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button {
                        animationManager.setAttachedSong(nil, forMusicCueSceneSet: setID)
                    } label: {
                        Image(systemName: AppIcons.xmarkCircleFill)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            #if os(macOS)
            Text("Attached-song playback isn't available in the macOS build. Use audio input reactivity for music-driven scene changes.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            #else
            Text("Starting the set plays this song and advances scenes on music cues automatically.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button {
                Task {
                    guard let musicService,
                          let attachment = await musicService.captureAttachmentWithFallbacks() else { return }
                    animationManager.setAttachedSong(attachment, forMusicCueSceneSet: setID)
                }
            } label: {
                Label(
                    editedSet?.attachedSong == nil ? "Attach Now Playing" : "Replace with Now Playing",
                    systemImage: AppIcons.linkBadgePlus
                )
                .font(.caption)
            }
            .disabled(musicService?.nowPlayingUnified == nil)

            Button {
                showSongPicker = true
            } label: {
                Label(
                    editedSet?.attachedSong == nil ? "Browse Library" : "Choose from Library",
                    systemImage: AppIcons.musicNoteList
                )
                .font(.caption)
            }
            .disabled(!(musicService?.hasAnyConnection ?? false))
            #endif
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
                    animationManager.selectMusicCueTargets(visibleTargets, in: setID)
                }
                .buttonStyle(.bordered)
                Button("Clear Visible") {
                    animationManager.clearMusicCueTargets(visibleTargets, in: setID)
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
            get: { animationManager.isMusicCueTargetSelected(target, in: setID) },
            set: { animationManager.setMusicCueTarget(target, isSelected: $0, in: setID) }
        )
    }
}
