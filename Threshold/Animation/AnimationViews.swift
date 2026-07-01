//
//  AnimationViews.swift
//  Threshold
//
//  UI for scene management, keyframe editing, and playback controls.
//

import SwiftUI

/// Compact duration label ("12.3s" under a minute, "2m 5s" over) shared by the
/// scene rows and the scene editor (was duplicated verbatim in both).
fileprivate func formatDuration(_ duration: TimeInterval) -> String {
    if duration < 60 {
        return String(format: "%.1fs", duration)
    } else {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return "\(minutes)m \(seconds)s"
    }
}

fileprivate enum AnimationEditorLayout {
    static let sceneEditorMinWidth: CGFloat = 560
    static let workspaceInset: CGFloat = 6

    static let headerHorizontalPadding: CGFloat = 18
    static let headerVerticalPadding: CGFloat = 12
    static let headerSpacing: CGFloat = 12

    static let metaSpacing: CGFloat = 12
    static let defaultRowHeight: CGFloat = 34
    static let keyframeRowHeight: CGFloat = 46

    static let settingsPopoverWidth: CGFloat = 392
    static let settingsPopoverHeight: CGFloat = 640
    static let settingsContentPadding: CGFloat = 18
    static let settingsSectionSpacing: CGFloat = 14
    static let settingsLabelWidth: CGFloat = 110
    static let settingsValueWidth: CGFloat = 52
    static let settingsSliderMinWidth: CGFloat = 150
    static let settingsSliderMaxWidth: CGFloat = 200

    static let keyframeSheetMinWidth: CGFloat = 720
    static let keyframeSheetIdealWidth: CGFloat = 820
    static let keyframeSheetRightPaneWidth: CGFloat = 286
    static let keyframeSheetHorizontalPadding: CGFloat = 18
    static let keyframeSheetSectionSpacing: CGFloat = 14
    static let keyframeSheetRowHeight: CGFloat = 24
    static let keyframeSheetControlRowHeight: CGFloat = 32
}

// MARK: - Animation Editor Window

/// Utility window for scene management and editing.
struct AnimationEditorWindowView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            if let animationManager = appModel.animationManager {
                AnimationEditorWorkspaceView(animationManager: animationManager, appModel: appModel)
            } else {
                ContentUnavailableView(
                    "Not Available",
                    systemImage: AppIcons.exclamationmarkTriangle,
                    description: Text("Animation manager not initialized")
                )
            }
        }
        .frame(minWidth: 920, minHeight: 620)
#if os(visionOS)
        .glassBackgroundEffect()
#endif
    }
}

private struct AnimationEditorWorkspaceView: View {
    @Bindable var animationManager: AnimationManager
    @Bindable var appModel: AppModel

    var body: some View {
        Group {
            if let scene = animationManager.currentScene {
                SceneEditorView(
                    scene: scene,
                    animationManager: animationManager,
                    appModel: appModel,
                    onDismiss: {
                        animationManager.currentScene = nil
                    },
                    isInline: true
                )
                .id(scene.id)
                .frame(minWidth: AnimationEditorLayout.sceneEditorMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, AnimationEditorLayout.workspaceInset)
            } else {
                ContentUnavailableView(
                    "No Scene Selected",
                    systemImage: AppIcons.pencilAndListClipboard,
                    description: Text("Pick a scene in Video and open Edit to edit it here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, AnimationEditorLayout.workspaceInset)
            }
        }
    }
}

// MARK: - Scene List View

/// Main view showing all saved scenes with create/edit/delete actions
struct SceneListView: View {
    @Bindable var animationManager: AnimationManager
    @Bindable var appModel: AppModel
    var onEditScene: ((AnimationScene) -> Void)? = nil
    var isInline: Bool = false
    var isEditing: Bool = false
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingCreateSheet = false
    @State private var newSceneName = ""
    @State private var selectedSceneForEdit: AnimationScene?
    @State private var showCreatePlaylist = false
    @State private var playlistCreationStatus: String?
    
    var body: some View {
        if isInline {
            inlineContent
        } else {
            standaloneContent
        }
    }
    
    // Inline variant: no NavigationStack, no toolbar – used when embedded in sidebar
    private var inlineContent: some View {
        VStack(spacing: 0) {
            // Header with title and add button
            HStack(spacing: 10) {
                Text("Scenes").font(.headline)
                Spacer()
                if !isEditing {
                    Button {
                        newSceneName = "Scene \(animationManager.scenes.count + 1)"
                        showingCreateSheet = true
                    } label: {
                        Image(systemName: AppIcons.plusCircleFill)
                            .font(.title3)
                    }
                }
            }
            .padding(.horizontal, AnimationEditorLayout.headerHorizontalPadding)
            .padding(.vertical, AnimationEditorLayout.headerVerticalPadding)
            
            sceneList
        }
        .sheet(isPresented: $showingCreateSheet) { createSheet }
        .sheet(item: $selectedSceneForEdit) { scene in editorSheet(for: scene) }
    }
    
    // Standalone variant: full NavigationStack with toolbar – used in its own window/sheet
    private var standaloneContent: some View {
        NavigationStack {
            sceneList
            .navigationTitle("Scenes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newSceneName = "Scene \(animationManager.scenes.count + 1)"
                        showingCreateSheet = true
                    } label: {
                        Image(systemName: AppIcons.plus)
                    }
                }
            }
            .sheet(isPresented: $showingCreateSheet) { createSheet }
            .sheet(item: $selectedSceneForEdit) { scene in editorSheet(for: scene) }
        }
    }
    
    // Shared scene list content
    private var sceneList: some View {
        List {
            if animationManager.scenes.isEmpty {
                ContentUnavailableView(
                    "No Scenes",
                    systemImage: AppIcons.filmStack,
                    description: Text("Create a scene to animate between parameter states")
                )
            } else {
                if !scenesWithSongs.isEmpty {
                    Section("Accompanied") {
                        ForEach(scenesWithSongs) { scene in
                            sceneListRow(scene)
                        }
                    }
                }

                if !silentScenes.isEmpty {
                    Section("Solo") {
                        ForEach(silentScenes) { scene in
                            sceneListRow(scene)
                        }
                    }
                }
            }
            
            // Show hidden defaults with a Restore option
            if !animationManager.hiddenDefaultScenes.isEmpty {
                Section {
                    ForEach(animationManager.hiddenDefaultScenes) { scene in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(scene.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("Hidden")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button {
                                animationManager.restoreDefaultScene(scene.id)
                            } label: {
                                Label("Restore", systemImage: AppIcons.arrowUturnBackward)
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .tint(.blue)
                        }
                    }
                } header: {
                    Text("Hidden Scenes")
                }
            }

            // Create playlist from scene songs
            if scenesWithSongs.count > 0 {
                Section {
                    Button {
                        showCreatePlaylist = true
                    } label: {
                        Label("Create Playlist from Scenes", systemImage: AppIcons.musicNoteList)
                    }
                    if let status = playlistCreationStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Playlist")
                }
            }
        }
        .listStyle(.plain)
        .alert("Create Playlist", isPresented: $showCreatePlaylist) {
            Button("Create") { createPlaylistFromScenes(name: "Threshold Scenes") }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Create an Apple Music playlist with \(scenesWithSongs.count) song(s) from your scenes?")
        }
    }

    private var scenesWithSongs: [AnimationScene] {
        animationManager.scenes.filter { $0.attachedSong != nil }
    }

    private var silentScenes: [AnimationScene] {
        animationManager.scenes.filter { $0.attachedSong == nil }
    }

    @ViewBuilder
    private func sceneListRow(_ scene: AnimationScene) -> some View {
        Group {
            if isInline {
                // Minimal row for the editor sidebar — name only
                HStack {
                    Text(scene.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer()
                    if animationManager.currentScene?.id == scene.id {
                        Image(systemName: AppIcons.checkmark)
                            .foregroundStyle(.blue)
                            .font(.caption)
                    }
                }
                .frame(minHeight: 34)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture {
                    animationManager.currentScene = scene
                    if let onEditScene { onEditScene(scene) }
                }
            } else {
                SceneRowView(
                    scene: scene,
                    isSelected: animationManager.currentScene?.id == scene.id,
                    isDefault: animationManager.isDefaultScene(scene),
                    isEdited: animationManager.isEditedDefault(scene),
                    onSelect: {
                        animationManager.currentScene = scene
                    },
                    onEdit: isEditing ? nil : {
                        if let onEditScene {
                            onEditScene(scene)
                        } else {
                            selectedSceneForEdit = scene
                        }
                    },
                    onResetDefault: animationManager.isEditedDefault(scene) ? {
                        animationManager.resetDefaultScene(scene.id)
                    } : nil
                )
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                animationManager.deleteScene(scene)
            } label: {
                if animationManager.isDefaultScene(scene) {
                    Label("Hide", systemImage: AppIcons.eyeSlash)
                } else {
                    Label("Delete", systemImage: AppIcons.trash)
                }
            }
        }
    }

    private func createPlaylistFromScenes(name: String) {
        let attachments = scenesWithSongs.compactMap(\.attachedSong)
        guard !attachments.isEmpty else { return }

        playlistCreationStatus = "Creating\u{2026}"
        Task {
            if let result = await appModel.musicService.createPlaylist(name: name, from: attachments) {
                playlistCreationStatus = "Created \"\(result)\""
            } else {
                playlistCreationStatus = "Failed to create playlist"
            }
            try? await Task.sleep(for: .seconds(4))
            playlistCreationStatus = nil
        }
    }

    private var createSheet: some View {
        CreateSceneSheet(
            sceneName: $newSceneName,
            onCreate: {
                let scene = animationManager.createScene(name: newSceneName)
                animationManager.currentScene = scene
                showingCreateSheet = false
                if let onEditScene {
                    onEditScene(scene)
                } else {
                    selectedSceneForEdit = scene
                }
            },
            onCancel: {
                showingCreateSheet = false
            }
        )
    }
    
    private func editorSheet(for scene: AnimationScene) -> some View {
        SceneEditorView(
            scene: scene,
            animationManager: animationManager,
            appModel: appModel,
            onDismiss: {
                selectedSceneForEdit = nil
            }
        )
    }
}

// MARK: - Scene Row

struct SceneRowView: View {
    let scene: AnimationScene
    let isSelected: Bool
    var isDefault: Bool = false
    var isEdited: Bool = false
    let onSelect: () -> Void
    var onEdit: (() -> Void)? = nil
    var onPlay: (() -> Void)? = nil
    var onResetDefault: (() -> Void)? = nil

    @State private var isResetButtonPressed = false
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(scene.name)
                        .font(.headline)
                    if isDefault {
                        Text(isEdited ? "edited" : "default")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(isEdited ? .orange : .blue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill((isEdited ? Color.orange : Color.blue).opacity(0.15))
                            )
                    }
                    if isSelected {
                        Image(systemName: AppIcons.checkmarkCircleFill)
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
                
                HStack(spacing: 12) {
                    Label("\(scene.keyframes.count)", systemImage: AppIcons.squareStack3dUp)
                    Label(formatDuration(scene.totalDuration), systemImage: AppIcons.clock)
                    if scene.isLooping {
                        Image(systemName: AppIcons.repeatIcon)
                    }
                    if scene.playbackMode != .forward {
                        Image(systemName: scene.playbackMode.icon)
                    }
                    if scene.attachedSong != nil {
                        Image(systemName: AppIcons.musicNote)
                            .foregroundStyle(.pink)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            HStack(spacing: 16) {
                // Reset edited default back to original
                if let onResetDefault {
                    Button {
                        onResetDefault()
                    } label: {
                        Image(systemName: AppIcons.arrowUturnBackward)
                    }
                    .buttonStyle(.bordered)
                    .tint(isResetButtonPressed ? .green : .red)
                    .help("Reset to original")
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.01)
                            .onChanged { _ in
                                isResetButtonPressed = true
                            }
                            .onEnded { _ in
                                isResetButtonPressed = false
                            }
                    )
                }
                if let onPlay {
                    Button { onPlay() } label: {
                        Image(systemName: AppIcons.playFill)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                    .disabled(scene.keyframes.count < 2)
                }
                if let onEdit {
                    Button { onEdit() } label: {
                        Image(systemName: AppIcons.pencil)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }
    
}

// MARK: - Create Scene Sheet

struct CreateSceneSheet: View {
    @Binding var sceneName: String
    let onCreate: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Scene Name", text: $sceneName)
                } footer: {
                    Text("Current parameters will be captured as the first keyframe.")
                }
            }
            .navigationTitle("New Scene")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: onCreate)
                        .disabled(sceneName.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Scene Editor View

struct SceneEditorView: View {
    @State var scene: AnimationScene
    @Bindable var animationManager: AnimationManager
    @Bindable var appModel: AppModel
    let onDismiss: () -> Void
    var isInline: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    @State private var selectedKeyframeForEdit: AnimationKeyframe?
    @State private var defaultDuration: Double = 2.0
#if !os(macOS)
    @State private var isEditMode: EditMode = .inactive
#endif
    @State private var showSceneSettings = false
    @State private var showSongPicker = false
    @State private var showCapturedFlash = false
    
    var body: some View {
        if isInline {
            inlineContent
        } else {
            standaloneContent
        }
    }
    
    // Inline: simple VStack with header – renders correctly inside an HStack pane
    private var inlineContent: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AnimationEditorLayout.headerSpacing) {
                HStack(spacing: AnimationEditorLayout.headerSpacing) {
                    Button {
                        closeEditor()
                    } label: {
                        Image(systemName: AppIcons.xmarkCircleFill)
                            .foregroundStyle(.secondary)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)

                    TextField("Scene Name", text: $scene.name)
                        .font(.headline)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1)
                        .frame(minWidth: 180)

                    Spacer(minLength: 0)

#if !os(macOS)
                    Button(isEditMode == .active ? "Done Reorder" : "Reorder") {
                        withMotionSensitiveAnimation(.default) {
                            isEditMode = isEditMode == .active ? .inactive : .active
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
#endif

                    Button {
                        updateLightingAcrossKeyframes()
                    } label: {
                        Label("Update Lighting", systemImage: AppIcons.lightbulbMax)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(scene.keyframes.isEmpty)

                    Button {
                        showSceneSettings.toggle()
                    } label: {
                        Label("Settings", systemImage: AppIcons.gearshape)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .popover(isPresented: $showSceneSettings, arrowEdge: .top) {
                        sceneSettingsPopover
                    }
                }

                ViewThatFits(in: .horizontal) {
                    inlineMetaRow
                    VStack(alignment: .leading, spacing: 10) {
                        inlineMetaLeadingRow
                        durationControlRow
                    }
                }
            }
            .padding(.horizontal, AnimationEditorLayout.headerHorizontalPadding)
            .padding(.vertical, AnimationEditorLayout.headerVerticalPadding)
            
            Divider()
            
            inlineEditorList
        }
        .sheet(item: $selectedKeyframeForEdit) { keyframe in keyframeSheet(for: keyframe) }
        .onChange(of: scene) { _, _ in persistSceneIfNeeded() }
        .onDisappear { persistSceneIfNeeded() }
    }
    
    // Scene settings popover
    private var sceneSettingsPopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AnimationEditorLayout.settingsSectionSpacing) {
                Text("Scene Settings").font(.headline)
                TextField("Name", text: $scene.name)
                    .textFieldStyle(.roundedBorder)
                Toggle("Loop Animation", isOn: $scene.isLooping)
                HStack {
                    Text("Playback")
                        .frame(width: AnimationEditorLayout.settingsLabelWidth, alignment: .leading)
                    Spacer()
                    Picker("Playback", selection: $scene.playbackMode) {
                        ForEach(AnimationPlaybackMode.allCases, id: \.self) { mode in
                            Label(mode.displayName, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 180)
                }
                Toggle("Use Scene Playback Speed", isOn: Binding(
                get: { scene.playbackSpeedOverride != nil },
                set: { enabled in
                    if enabled {
                        scene.playbackSpeedOverride = scene.playbackSpeedOverride ?? 1.0
                    } else {
                        scene.playbackSpeedOverride = nil
                    }
                }
                ))

                if scene.playbackSpeedOverride != nil {
                    settingsSliderRow(
                        label: "Speed",
                        value: Binding(
                            get: { scene.playbackSpeedOverride ?? 1.0 },
                            set: { scene.playbackSpeedOverride = $0 }
                        ),
                        range: 0.1...4.0,
                        step: 0.05,
                        format: "%.2f",
                        suffix: "x"
                    )
                }
                HStack {
                    Text("Total Duration")
                        .frame(width: AnimationEditorLayout.settingsLabelWidth, alignment: .leading)
                    Spacer()
                    Text(formatDuration(scene.totalDuration))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Source Fractal")
                        .frame(width: AnimationEditorLayout.settingsLabelWidth, alignment: .leading)
                    Spacer()
                    if let fractalType = scene.fractalType {
                        Label(fractalType.displayName, systemImage: fractalType.icon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Unspecified")
                            .foregroundStyle(.secondary)
                    }
                }
                
                Divider()
                
                // Safety bubble / blend window
                VStack(alignment: .leading, spacing: 6) {
                    Text("Safety Bubble")
                        .font(.subheadline.bold())
                
                    Toggle("Enabled", isOn: Binding(
                        get: { scene.safetyBubbleEnabled ?? true },
                        set: { scene.safetyBubbleEnabled = $0 }
                    ))
                    .font(.subheadline)
                
                    if scene.safetyBubbleEnabled ?? true {
                        VStack(spacing: 10) {
                            settingsSliderRow(
                                label: "Radius",
                                value: Binding(
                                    get: { scene.safetyBubbleRadius ?? 0.5 },
                                    set: { scene.safetyBubbleRadius = $0 }
                                ),
                                range: 0.1...2.0,
                                step: 0.05,
                                format: "%.2f"
                            )
                            settingsSliderRow(
                                label: "Shape",
                                value: Binding(
                                    get: { scene.safetyBubbleShape ?? 0.5 },
                                    set: { scene.safetyBubbleShape = $0 }
                                ),
                                range: 0.0...1.0,
                                step: 0.05,
                                format: "%.2f"
                            )
                            settingsSliderRow(
                                label: "Blend",
                                value: Binding(
                                    get: { UISettingsCache.blendValueToSlider(scene.safetyBubbleBlend ?? 0.5) },
                                    set: { scene.safetyBubbleBlend = UISettingsCache.blendSliderToValue($0) }
                                ),
                                range: 0.0...1.0,
                                step: 0.05,
                                format: "%.2f"
                            )
                        }
                    }
                
                    Button {
                        let settings = appModel.renderSettings
                        scene.safetyBubbleEnabled = settings.safetyBubbleEnabled
                        scene.safetyBubbleRadius = settings.safetyBubbleRadius
                        scene.safetyBubbleShape = settings.safetyBubbleShape
                        scene.safetyBubbleBlend = settings.safetyBubbleBlend
                    } label: {
                        Label("Capture Current Settings", systemImage: AppIcons.cameraFill)
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                
                Divider()
                
                // Attached song
                VStack(alignment: .leading, spacing: 6) {
                    Text("Attached Song")
                        .font(.subheadline.bold())
                
                if let song = scene.attachedSong {
                    HStack(spacing: 8) {
                        // Show icons for ALL available services
                        HStack(spacing: 3) {
                            ForEach(song.trackIDs, id: \.self) { tid in
                                Image(systemName: iconName(for: tid.serviceID))
                                    .font(.caption2)
                                    .foregroundStyle(iconColor(for: tid.serviceID))
                            }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(song.title).font(.caption).lineLimit(1)
                            Text(song.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            if song.trackIDs.count > 1 {
                                Text("\(song.trackIDs.count) services")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Button {
                            scene.attachedSong = nil
                        } label: {
                            Image(systemName: AppIcons.xmarkCircleFill)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
                } else {
                    #if os(macOS)
                    Text("Attached-song playback isn't available in the macOS build. Use audio input reactivity for music-driven scenes.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    #else
                    Text("Auto-plays when the scene starts.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    #endif
                }
                
                #if !os(macOS)
                Button {
                    Task {
                        if let attachment = await appModel.musicService.captureAttachmentWithFallbacks() {
                            scene.attachedSong = attachment
                        }
                    }
                } label: {
                    Label(
                        scene.attachedSong == nil ? "Attach Now Playing" : "Replace with Now Playing",
                        systemImage: AppIcons.linkBadgePlus
                    )
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appModel.musicService.nowPlayingUnified == nil)

                Button {
                    showSongPicker = true
                } label: {
                    Label(
                        scene.attachedSong == nil ? "Browse Library" : "Choose from Library",
                        systemImage: AppIcons.musicNoteList
                    )
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!appModel.musicService.hasAnyConnection)

                if scene.attachedSong != nil {
                    Divider().padding(.vertical, 2)

                    Toggle("Fade Out Quick Stop", isOn: Binding(
                        get: {
                            let fadeDuration = scene.songFadeOutDuration ?? 0
                            let fadeOffset = scene.songFadeOutOffset ?? 0
                            return fadeDuration > 0 || fadeOffset > 0
                        },
                        set: { enabled in
                            if enabled {
                                if (scene.songFadeOutDuration ?? 0) <= 0 {
                                    scene.songFadeOutDuration = 0.35
                                }
                                if scene.songFadeOutOffset == nil {
                                    scene.songFadeOutOffset = 0.0
                                }
                            } else {
                                scene.songFadeOutDuration = nil
                                scene.songFadeOutOffset = nil
                            }
                        }
                    ))
                    .font(.subheadline)

                    let fadeControlsEnabled = (scene.songFadeOutDuration ?? 0) > 0 || (scene.songFadeOutOffset ?? 0) > 0
                    if fadeControlsEnabled {
                        VStack(spacing: 10) {
                            settingsSliderRow(
                                label: "Fade Duration",
                                value: Binding(
                                    get: { scene.songFadeOutDuration ?? 0.35 },
                                    set: { scene.songFadeOutDuration = $0 }
                                ),
                                range: 0.05...2.0,
                                step: 0.05,
                                format: "%.2f",
                                suffix: "s"
                            )
                            settingsSliderRow(
                                label: "Fade Offset",
                                value: Binding(
                                    get: { scene.songFadeOutOffset ?? 0.0 },
                                    set: { scene.songFadeOutOffset = $0 }
                                ),
                                range: 0.0...3.0,
                                step: 0.05,
                                format: "%.2f",
                                suffix: "s"
                            )
                        }
                        Text("Shape-stream velocity dampens near the song tail. Offset holds a near-stop before the end.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                #endif
                }
            }
            .padding(AnimationEditorLayout.settingsContentPadding)
        }
        .frame(width: AnimationEditorLayout.settingsPopoverWidth, height: AnimationEditorLayout.settingsPopoverHeight)
        .sheet(isPresented: $showSongPicker) {
            SongPickerSheet(musicService: appModel.musicService) { track in
                Task {
                    scene.attachedSong = await appModel.musicService.makeAttachment(from: track)
                }
            }
        }
    }
    
    // Standalone: NavigationStack with toolbar – for sheet presentation
    private var standaloneContent: some View {
        NavigationStack {
            editorList
            .navigationTitle(scene.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        closeEditor()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        Button {
                            updateLightingAcrossKeyframes()
                        } label: {
                            Image(systemName: AppIcons.lightbulbMax)
                        }
                        .disabled(scene.keyframes.isEmpty)

                        Button {
                            showSceneSettings.toggle()
                        } label: {
                            Image(systemName: AppIcons.gearshape)
                        }
                        .popover(isPresented: $showSceneSettings) {
                            sceneSettingsPopover
                        }
#if !os(macOS)
                        EditButton()
#endif
                    }
                }
            }
            .sheet(item: $selectedKeyframeForEdit) { keyframe in keyframeSheet(for: keyframe) }
        }
        .onChange(of: scene) { _, _ in persistSceneIfNeeded() }
        .onDisappear { persistSceneIfNeeded() }
    }
    
    @ViewBuilder
    private var inlineEditorList: some View {
#if os(macOS)
        editorList
#else
        editorList
            .environment(\.editMode, $isEditMode)
#endif
    }

    // Shared list content
    private var editorList: some View {
        List {
            // Keyframes Section
            Section {
                if scene.keyframes.isEmpty {
                    Text("No keyframes yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(scene.keyframes.enumerated()), id: \.element.id) { index, keyframe in
                        KeyframeRowView(
                            keyframe: keyframe,
                            index: index,
                            onEdit: {
                                selectedKeyframeForEdit = keyframe
                            },
                            onJump: {
                                applyKeyframe(keyframe)
                            },
                            onOverwrite: {
                                overwriteKeyframe(at: index)
                            },
                            onDuplicate: {
                                duplicateKeyframe(at: index)
                            },
                            onDurationChanged: { newDuration in
                                guard index < scene.keyframes.count else { return }
                                scene.keyframes[index].duration = newDuration
                            }
                        )
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            scene.removeKeyframe(at: index)
                        }
                    }
                    .onMove { source, destination in
                        scene.moveKeyframe(from: source, to: destination)
                    }
                }
            } header: {
                HStack {
                    Text("Keyframes")
                    Spacer()
                    if showCapturedFlash {
                        Text("Captured!")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                    Button {
                        addKeyframe()
                        withMotionSensitiveAnimation(.easeInOut(duration: 0.2)) {
                            showCapturedFlash = true
                        }
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.2))
                            guard !Task.isCancelled else { return }
                            withMotionSensitiveAnimation(.easeOut(duration: 0.3)) {
                                showCapturedFlash = false
                            }
                        }
                    } label: {
                        Label("Capture", systemImage: AppIcons.plusCircleFill)
                            .font(.caption)
                    }
                }
            } footer: {
                Text("Keyframes capture shape, position, quality, color, and music-reactive controls. Save a Preset to persist the full scene outside animation.")
            }
        }
        .listStyle(.plain)
    }

    private func withMotionSensitiveAnimation(_ animation: Animation, _ updates: () -> Void) {
        if reduceMotion {
            updates()
        } else {
            withAnimation(animation, updates)
        }
    }
    
    private func keyframeSheet(for keyframe: AnimationKeyframe) -> some View {
        KeyframeEditorView(
            keyframe: keyframe,
            onSave: { updatedKeyframe in
                if let index = scene.keyframes.firstIndex(where: { $0.id == keyframe.id }) {
                    scene.keyframes[index] = updatedKeyframe
                }
                selectedKeyframeForEdit = nil
            },
            onCancel: {
                selectedKeyframeForEdit = nil
            }
        )
    }

    private func persistSceneIfNeeded() {
        animationManager.updateScene(scene)
    }

    private func closeEditor() {
        persistSceneIfNeeded()
        onDismiss()
    }

    private var inlineMetaRow: some View {
        HStack(spacing: AnimationEditorLayout.metaSpacing) {
            inlineMetaLeadingRow
            Spacer(minLength: 0)
            durationControlRow
        }
    }

    private var inlineMetaLeadingRow: some View {
        HStack(spacing: AnimationEditorLayout.metaSpacing) {
            Toggle(isOn: $scene.isLooping) {
                Label("Loop", systemImage: AppIcons.repeatIcon)
                    .font(.caption)
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .tint(scene.isLooping ? .blue : .secondary)

            Picker("Playback", selection: $scene.playbackMode) {
                ForEach(AnimationPlaybackMode.allCases, id: \.self) { mode in
                    Label(mode.displayName, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.regular)
        }
    }

    private var durationControlRow: some View {
        HStack(spacing: 10) {
            Label("Duration", systemImage: AppIcons.timer)
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $defaultDuration, in: 0.5...10.0, step: 0.5)
                .frame(minWidth: 140, maxWidth: 210)
            Text("\(String(format: "%.1f", defaultDuration))s")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .frame(minHeight: AnimationEditorLayout.defaultRowHeight)
    }

    private func settingsSliderRow(label: String, value: Binding<Float>, range: ClosedRange<Float>, step: Float, format: String = "%.2f") -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .frame(width: AnimationEditorLayout.settingsLabelWidth, alignment: .leading)
            Slider(value: value, in: range, step: step)
                .frame(minWidth: AnimationEditorLayout.settingsSliderMinWidth, maxWidth: AnimationEditorLayout.settingsSliderMaxWidth)
            Text(String(format: format, value.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: AnimationEditorLayout.settingsValueWidth, alignment: .trailing)
        }
        .frame(minHeight: AnimationEditorLayout.defaultRowHeight)
    }

    private func settingsSliderRow(label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: String = "%.2f", suffix: String = "") -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .frame(width: AnimationEditorLayout.settingsLabelWidth, alignment: .leading)
            Slider(value: value, in: range, step: step)
                .frame(minWidth: AnimationEditorLayout.settingsSliderMinWidth, maxWidth: AnimationEditorLayout.settingsSliderMaxWidth)
            Text("\(String(format: format, value.wrappedValue))\(suffix)")
                .font(.caption.monospacedDigit())
                .frame(width: AnimationEditorLayout.settingsValueWidth, alignment: .trailing)
        }
        .frame(minHeight: AnimationEditorLayout.defaultRowHeight)
    }
    
    private func addKeyframe() {
        let settings = appModel.renderSettings
        var keyframe = AnimationKeyframe(from: settings, name: "Keyframe \(scene.keyframes.count + 1)", duration: defaultDuration)
        
        // First keyframe has 0 duration
        if scene.keyframes.isEmpty {
            keyframe.duration = 0
        }
        
        scene.keyframes.append(keyframe)
    }
    
    private func applyKeyframe(_ keyframe: AnimationKeyframe) {
        let settings = appModel.renderSettings
        settings.targetMinDistance = keyframe.minDistance
        settings.targetFoldingLimit = keyframe.foldingLimit
        settings.targetSphereRadius = keyframe.sphereRadius
        settings.fractalScale = keyframe.fractalScale
        settings.targetFractalScale = keyframe.fractalScale
        settings.targetPosition = keyframe.position
        
        // Apply formula params (unified path — covers Mandelbox shape params too)
        if let vals = keyframe.formulaParamValues {
            var fp = settings.formulaParams
            for i in 0..<min(16, vals.count) {
                FormulaCatalog.setParam(&fp, index: i, value: vals[i])
            }
            settings.formulaParams = fp
        }
        
        // Apply quality settings
        settings.baseFractalIterations = keyframe.baseFractalIterations
        settings.baseMaxRaySteps = keyframe.baseMaxRaySteps

        if let musicConfig = keyframe.musicReactiveConfig,
           settings.audioReactiveConfig != musicConfig {
            settings.audioReactiveConfig = musicConfig
        }
        
        // Ensure pipeline is prepared for these values
        appModel.preparePipeline(iterations: keyframe.baseFractalIterations, raySteps: keyframe.baseMaxRaySteps)
    }
    
    private func overwriteKeyframe(at index: Int) {
        guard index < scene.keyframes.count else { return }
        let settings = appModel.renderSettings
        
        // Update the existing keyframe's values in place (preserves name, duration, ID)
        scene.keyframes[index].minDistance = settings.targetMinDistance
        scene.keyframes[index].foldingLimit = settings.targetFoldingLimit
        scene.keyframes[index].sphereRadius = settings.targetSphereRadius
        scene.keyframes[index].fractalScale = settings.fractalScale
        scene.keyframes[index].position = settings.targetPosition
        scene.keyframes[index].baseFractalIterations = settings.baseFractalIterations
        scene.keyframes[index].baseMaxRaySteps = settings.baseMaxRaySteps
        
        // Capture formula params (unified path — includes Mandelbox)
        let fp = settings.formulaParams
        var vals = [Float](repeating: 0, count: 16)
        for i in 0..<16 { vals[i] = FormulaCatalog.getParam(fp, index: i) }
        scene.keyframes[index].formulaParamValues = vals
        scene.keyframes[index].musicReactiveConfig = settings.audioReactiveConfig
    }
    
    private func duplicateKeyframe(at index: Int) {
        guard index < scene.keyframes.count else { return }
        var copy = scene.keyframes[index]
        copy = AnimationKeyframe(
            id: UUID(),
            name: copy.name + " Copy",
            duration: copy.duration,
            minDistance: copy.minDistance,
            foldingLimit: copy.foldingLimit,
            sphereRadius: copy.sphereRadius,
            fractalScale: copy.fractalScale,
            baseFractalIterations: copy.baseFractalIterations,
            baseMaxRaySteps: copy.baseMaxRaySteps,
            scale: copy.scale,
            position: copy.position,
            detailScale: copy.detailScale,
            worldRotation: copy.worldRotation,
            lightingMode: copy.lightingMode,
            lightingPreset: copy.lightingPreset,
            hueRotationEffect: copy.hueRotationEffect,
            pulseEffect: copy.pulseEffect,
            glowEffect: copy.glowEffect,
            bloomEffect: copy.bloomEffect,
            fogEffect: copy.fogEffect,
            gradientCycleEffect: copy.gradientCycleEffect,
            musicReactiveConfig: copy.musicReactiveConfig,
            easingType: copy.easingType,
            bezierHandle: copy.bezierHandle,
            formulaParamValues: copy.formulaParamValues
        )
        scene.keyframes.insert(copy, at: index + 1)
    }

    private func updateLightingAcrossKeyframes() {
        guard !scene.keyframes.isEmpty else { return }

        // Snapshot current lighting/effects once, then apply to all keyframes.
        let snapshot = AnimationKeyframe(from: appModel.renderSettings, name: "Lighting Snapshot", duration: 0)

        for index in scene.keyframes.indices {
            scene.keyframes[index].lightingMode = snapshot.lightingMode
            scene.keyframes[index].lightingPreset = snapshot.lightingPreset
            scene.keyframes[index].hueRotationEffect = snapshot.hueRotationEffect
            scene.keyframes[index].pulseEffect = snapshot.pulseEffect
            scene.keyframes[index].glowEffect = snapshot.glowEffect
            scene.keyframes[index].bloomEffect = snapshot.bloomEffect
            scene.keyframes[index].fogEffect = snapshot.fogEffect
            scene.keyframes[index].gradientCycleEffect = snapshot.gradientCycleEffect
            scene.keyframes[index].lightingSoftness = snapshot.lightingSoftness
        }
    }
    

    // ── Service icon / color helpers ──────────────────────────────────────

    private func iconName(for serviceID: String) -> String {
        appModel.musicService.provider(for: serviceID)?.iconName ?? "music.note"
    }

    private func iconColor(for serviceID: String) -> Color {
        appModel.musicService.provider(for: serviceID)?.accentColor ?? .secondary
    }
}

// MARK: - Keyframe Row

struct KeyframeRowView: View {
    let keyframe: AnimationKeyframe
    let index: Int
    let onEdit: () -> Void
    let onJump: () -> Void
    let onOverwrite: () -> Void
    var onDuplicate: (() -> Void)? = nil
    var onDurationChanged: ((TimeInterval) -> Void)? = nil
    
    @State private var isDraggingDuration = false
    @State private var dragDuration: TimeInterval = 0
    
    var body: some View {
        HStack(spacing: 10) {
            // Index badge
            Text("\(index + 1)")
                .font(.caption.bold())
                .frame(width: 28, height: 28)
                .background(Circle().fill(.secondary.opacity(0.3)))
            
            Text(keyframe.name)
                .font(.subheadline.bold())
                .lineLimit(1)
            
            Spacer()
            
            // Duration (except for first keyframe) — draggable
            if index > 0 {
                let displayDuration = isDraggingDuration ? dragDuration : keyframe.duration
                Text("\(String(format: "%.1f", displayDuration))s")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(isDraggingDuration ? Color.blue.opacity(0.3) : Color.secondary.opacity(0.2)))
                    .accessibilityLabel("Segment duration")
                    .accessibilityValue("\(String(format: "%.1f", displayDuration)) seconds")
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                if !isDraggingDuration {
                                    isDraggingDuration = true
                                    dragDuration = keyframe.duration
                                }
                                // 100pt drag = 1 second change
                                let delta = TimeInterval(value.translation.width / 100.0)
                                dragDuration = max(0.1, keyframe.duration + delta)
                            }
                            .onEnded { _ in
                                isDraggingDuration = false
                                onDurationChanged?(dragDuration)
                            }
                    )
            }
            
            HStack(spacing: 6) {
                // Preview — apply keyframe to current render
                Button { onJump() } label: {
                    Image(systemName: AppIcons.eye)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Preview — apply this keyframe's values")
                .accessibilityLabel("Preview keyframe")
                
                // Edit easing / details
                Button { onEdit() } label: {
                    Image(systemName: AppIcons.sliderHorizontal3)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Edit keyframe details")
                .accessibilityLabel("Edit keyframe details")
                
                // More actions
                Menu {
                    Button { onOverwrite() } label: {
                        Label("Replace with Current", systemImage: AppIcons.arrowDownCircle)
                    }
                    if let onDuplicate {
                        Button { onDuplicate() } label: {
                            Label("Duplicate", systemImage: AppIcons.plusSquareOnSquare)
                        }
                    }
                } label: {
                    Image(systemName: AppIcons.ellipsisCircle)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("More actions")
                .accessibilityLabel("More keyframe actions")
            }
        }
        .frame(minHeight: AnimationEditorLayout.keyframeRowHeight)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Keyframe Editor

struct KeyframeEditorView: View {
    @State var keyframe: AnimationKeyframe
    let onSave: (AnimationKeyframe) -> Void
    let onCancel: () -> Void
    
    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                // ── LEFT COLUMN: Editable core + read-only parameter summary ──
                ScrollView {
                    VStack(spacing: AnimationEditorLayout.keyframeSheetSectionSpacing) {
                        // ── Core (editable) ──
                        summarySection("Core") {
                            HStack {
                                Text("Name").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                TextField("Keyframe Name", text: $keyframe.name)
                                    .font(.caption)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 220)
                            }
                            .frame(height: AnimationEditorLayout.keyframeSheetControlRowHeight)
                            HStack {
                                Text("Duration").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Slider(value: $keyframe.duration, in: 0.0...30.0, step: 0.1)
                                    .frame(maxWidth: 170)
                                Text(String(format: "%.1fs", keyframe.duration))
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 46, alignment: .trailing)
                            }
                            .frame(height: AnimationEditorLayout.keyframeSheetControlRowHeight)
                            summaryRow("Easing", text: keyframe.easingType.displayName)
                        }
                        
                        // ── Shape ──
                        summarySection("Shape") {
                            summaryRow("Min Distance", value: keyframe.minDistance)
                            summaryRow("Folding Limit", value: keyframe.foldingLimit)
                            summaryRow("Sphere Radius", value: keyframe.sphereRadius)
                            summaryRow("Fractal Scale", value: keyframe.fractalScale)
                            summaryRow("Detail Scale", value: keyframe.detailScale)
                            summaryRow("Scale", value: keyframe.scale)
                        }
                        
                        // ── Position ──
                        summarySection("Position") {
                            summaryRow("X", value: keyframe.positionX)
                            summaryRow("Y", value: keyframe.positionY)
                            summaryRow("Z", value: keyframe.positionZ)
                        }
                        
                        // ── Rotation ──
                        summarySection("Rotation") {
                            summaryRow("X", value: keyframe.worldRotationX)
                            summaryRow("Y", value: keyframe.worldRotationY)
                            summaryRow("Z", value: keyframe.worldRotationZ)
                            summaryRow("W", value: keyframe.worldRotationW)
                        }
                        
                        // ── Quality ──
                        summarySection("Quality") {
                            summaryRow("Iterations", text: "\(keyframe.baseFractalIterations)")
                            summaryRow("Ray Steps", text: "\(keyframe.baseMaxRaySteps)")
                        }
                        
                        // ── Visual Effects ──
                        if hasVisualEffects {
                            summarySection("Visual Effects") {
                                optionalEffectRow("Lighting Mode", value: keyframe.lightingMode?.displayName)
                                optionalEffectRow("Lighting Preset", value: keyframe.lightingPreset?.displayName)
                                optionalEffectRow("Glow", effect: keyframe.glowEffect, describe: { "intensity \(String(format: "%.2f", $0.intensity))" })
                                optionalEffectRow("Bloom", effect: keyframe.bloomEffect, describe: { "strength \(String(format: "%.2f", $0.strength))" })
                                optionalEffectRow("Fog", effect: keyframe.fogEffect, describe: { "intensity \(String(format: "%.2f", $0.intensity))" })
                                optionalEffectRow("Hue Rotation", effect: keyframe.hueRotationEffect, describe: { "speed \(String(format: "%.2f", $0.speed))" })
                                optionalEffectRow("Pulse", effect: keyframe.pulseEffect, describe: { "speed \(String(format: "%.2f", $0.speed))" })
                                optionalEffectRow("Gradient Cycle", effect: keyframe.gradientCycleEffect, describe: { "speed \(String(format: "%.2f", $0.speed))" })
                            }
                        }
                        
                        // ── Color ──
                        if hasColorOverrides {
                            summarySection("Color") {
                                optionalRow("Mapping Mode", value: keyframe.colorMappingMode?.displayName)
                                optionalRow("Gradient Preset", value: keyframe.gradientPreset?.displayName)
                                optionalRow("Gradient Repeat", float: keyframe.gradientRepeat)
                                optionalRow("Gradient Offset", float: keyframe.gradientOffset)
                                optionalRow("Gradient Smoothing", float: keyframe.gradientSmoothing)
                                optionalRow("Saturation", float: keyframe.colorSchemeSaturation)
                                optionalRow("Contrast", float: keyframe.colorSchemeContrast)
                                optionalRow("Gamma", float: keyframe.colorSchemeGamma)
                                optionalRow("Vibrance", float: keyframe.colorSchemeVibrance)
                                optionalRow("Curve", float: keyframe.colorSchemeCurve)
                                optionalRow("Shadows", float: keyframe.colorSchemeShadows)
                                optionalRow("Highlights", float: keyframe.colorSchemeHighlights)
                                optionalRow("Lighting Softness", float: keyframe.lightingSoftness)
                            }
                        }

                        if hasMusicOverrides {
                            summarySection("Music Reactive") {
                                if let musicConfig = keyframe.musicReactiveConfig {
                                    summaryRow("Enabled", text: musicConfig.fractalAudioReactiveEnabled ? "On" : "Off")
                                    summaryRow("Amount", value: musicConfig.fractalAudioAmount)
                                    summaryRow("Drop", value: musicConfig.fractalBeatPunch)
                                    summaryRow("Mappings", text: "\(musicConfig.musicReactiveMappings.count)")
                                    summaryRow("Groups", text: "\(musicConfig.tripletMusicGains.count)")
                                }
                            }
                        }
                        
                        // ── Formula Params ──
                        if let vals = keyframe.formulaParamValues, !vals.allSatisfy({ $0 == 0 }) {
                            summarySection("Formula Parameters") {
                                ForEach(Array(vals.enumerated()), id: \.offset) { i, val in
                                    if val != 0 {
                                        summaryRow("Param \(i)", value: val)
                                    }
                                }
                            }
                        }
                        
                        Spacer(minLength: 20)
                    }
                    .padding(.top, 10)
                }
                
                Divider()
                
                // ── RIGHT COLUMN: Easing (interactive) ──
                ScrollView {
                    VStack(spacing: AnimationEditorLayout.keyframeSheetSectionSpacing) {
                        sectionHeader("Easing Curve")
                        
                        Picker("Easing", selection: $keyframe.easingType) {
                            ForEach(EasingFunction.allCases, id: \.self) { easing in
                                Label(easing.displayName, systemImage: easing.icon)
                                    .tag(easing)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        
                        if keyframe.easingType == .bezier {
                            Menu {
                                Button("Linear") { keyframe.bezierHandle = .linear }
                                Button("Ease In") { keyframe.bezierHandle = .easeIn }
                                Button("Ease Out") { keyframe.bezierHandle = .easeOut }
                                Button("Ease In/Out") { keyframe.bezierHandle = .easeInOut }
                                Divider()
                                Button("Overshoot") { keyframe.bezierHandle = .overshoot }
                                Button("Anticipate") { keyframe.bezierHandle = .anticipate }
                                Button("Snappy") { keyframe.bezierHandle = .snappy }
                            } label: {
                                Label("Bezier Preset", systemImage: AppIcons.curveBezier)
                                    .font(.subheadline)
                            }
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            
                            BezierCurvePreview(handle: keyframe.bezierHandle)
                                .frame(height: 120)
                                .padding(.horizontal, 16)
                            
                            compactSliderRow(icon: "1.circle", label: "CP1 X",
                                             value: $keyframe.bezierHandle.cp1x, range: 0...1, format: "%.2f")
                            compactSliderRow(icon: "1.circle", label: "CP1 Y",
                                             value: $keyframe.bezierHandle.cp1y, range: -0.5...1.5, format: "%.2f")
                            compactSliderRow(icon: "2.circle", label: "CP2 X",
                                             value: $keyframe.bezierHandle.cp2x, range: 0...1, format: "%.2f")
                            compactSliderRow(icon: "2.circle", label: "CP2 Y",
                                             value: $keyframe.bezierHandle.cp2y, range: -0.5...1.5, format: "%.2f")
                        } else {
                            EasingCurvePreview(easing: keyframe.easingType)
                                .frame(height: 120)
                                .padding(.horizontal, 16)
                            
                            Text(keyframe.easingType.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer(minLength: 20)
                    }
                    .padding(.top, 10)
                }
                .frame(width: AnimationEditorLayout.keyframeSheetRightPaneWidth)
            }
            .navigationTitle("Keyframe Details")
#if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(keyframe)
                    }
                }
            }
        }
        .frame(minWidth: AnimationEditorLayout.keyframeSheetMinWidth, idealWidth: AnimationEditorLayout.keyframeSheetIdealWidth, minHeight: 560, idealHeight: 700)
    }
    
    // MARK: - Summary Helpers
    
    private var hasVisualEffects: Bool {
        keyframe.lightingMode != nil || keyframe.lightingPreset != nil ||
        keyframe.glowEffect != nil || keyframe.bloomEffect != nil ||
        keyframe.fogEffect != nil || keyframe.hueRotationEffect != nil ||
        keyframe.pulseEffect != nil || keyframe.gradientCycleEffect != nil
    }
    
    private var hasColorOverrides: Bool {
        keyframe.colorMappingMode != nil || keyframe.gradientPreset != nil ||
        keyframe.gradientRepeat != nil || keyframe.gradientOffset != nil ||
        keyframe.gradientSmoothing != nil || keyframe.colorSchemeSaturation != nil ||
        keyframe.colorSchemeContrast != nil || keyframe.colorSchemeGamma != nil ||
        keyframe.colorSchemeVibrance != nil || keyframe.colorSchemeCurve != nil ||
        keyframe.colorSchemeShadows != nil || keyframe.colorSchemeHighlights != nil ||
        keyframe.lightingSoftness != nil
    }

    private var hasMusicOverrides: Bool {
        keyframe.musicReactiveConfig != nil
    }
    
    @ViewBuilder
    private func summarySection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(title)
            VStack(spacing: 3) {
                content()
            }
            .padding(.horizontal, AnimationEditorLayout.keyframeSheetHorizontalPadding)
        }
    }
    
    private func summaryRow(_ label: String, value: Float, format: String = "%.3f") -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(String(format: format, value))
                .font(.caption.monospacedDigit())
        }
        .frame(height: AnimationEditorLayout.keyframeSheetRowHeight)
    }
    
    private func summaryRow(_ label: String, text: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(text)
                .font(.caption.monospacedDigit())
        }
        .frame(height: AnimationEditorLayout.keyframeSheetRowHeight)
    }
    
    @ViewBuilder
    private func optionalRow(_ label: String, value: String?) -> some View {
        if let value {
            summaryRow(label, text: value)
        }
    }
    
    @ViewBuilder
    private func optionalRow(_ label: String, float: Float?) -> some View {
        if let float {
            summaryRow(label, value: float)
        }
    }
    
    @ViewBuilder
    private func optionalEffectRow<E>(_ label: String, effect: E?, describe: (E) -> String) -> some View {
        if let effect {
            summaryRow(label, text: describe(effect))
        }
    }
    
    @ViewBuilder
    private func optionalEffectRow(_ label: String, value: String?) -> some View {
        if let value {
            summaryRow(label, text: value)
        }
    }
    
    // Slider row for bezier control points (easing pane — still interactive)
    private func compactSliderRow(icon: String, label: String, value: Binding<Float>,
                                   range: ClosedRange<Float>, step: Float? = nil, format: String = "%.3f") -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.primary)
                .frame(width: 18)
            Text(label)
                .font(.subheadline)
                .frame(width: 72, alignment: .leading)
                .lineLimit(1)
            if let step {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
            Text(String(format: format, value.wrappedValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
        }
        .frame(height: 36)
        .padding(.horizontal, AnimationEditorLayout.keyframeSheetHorizontalPadding)
    }
    
    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, AnimationEditorLayout.keyframeSheetHorizontalPadding)
        .padding(.top, 6)
    }
}

// MARK: - Playback Controls View

struct LiveSessionRecordingControl: View {
    @Bindable var animationManager: AnimationManager
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            Button {
                animationManager.toggleRecording()
            } label: {
                if compact {
                    HStack(spacing: 6) {
                        Image(systemName: animationManager.isRecording ? AppIcons.stopFill : AppIcons.recordCircle)
                        if animationManager.isRecording {
                            Text(formatTime(animationManager.recordingElapsed))
                                .font(.caption.monospacedDigit())
                        }
                    }
                } else {
                    Label(
                        animationManager.isRecording ? "Stop \(formatTime(animationManager.recordingElapsed))" : "Record Session",
                        systemImage: animationManager.isRecording ? AppIcons.stopFill : AppIcons.recordCircle
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(animationManager.isRecording ? .red : .pink)
            .help(animationManager.isRecording ? "Stop live session recording" : "Record the live session as a scene")
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Preview

#Preview {
    SceneListView(
        animationManager: AnimationManager(),
        appModel: AppModel()
    )
}
