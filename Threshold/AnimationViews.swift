//
//  AnimationViews.swift
//  Threshold
//
//  UI for scene management, keyframe editing, and playback controls.
//

import SwiftUI

// MARK: - Scenes Window View

/// Wrapper view for the standalone scenes window
struct ScenesWindowView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissWindow) private var dismissWindow
    
    var body: some View {
        Group {
            if let animationManager = appModel.animationManager {
                SceneListView(animationManager: animationManager, appModel: appModel)
            } else {
                ContentUnavailableView(
                    "Not Available",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Animation manager not initialized")
                )
            }
        }
        .frame(minWidth: 450, minHeight: 400)
        .glassBackgroundEffect()
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
            HStack {
                Text("Scenes").font(.headline)
                Spacer()
                if !isEditing {
                    Button {
                        newSceneName = "Scene \(animationManager.scenes.count + 1)"
                        showingCreateSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            
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
                        Image(systemName: "plus")
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
                    systemImage: "film.stack",
                    description: Text("Create a scene to animate between parameter states")
                )
            } else {
                ForEach(animationManager.scenes) { scene in
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
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            animationManager.deleteScene(scene)
                        } label: {
                            if animationManager.isDefaultScene(scene) {
                                Label("Hide", systemImage: "eye.slash")
                            } else {
                                Label("Delete", systemImage: "trash")
                            }
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
                                Label("Restore", systemImage: "arrow.uturn.backward")
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
        }
        .listStyle(.plain)
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
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
                
                HStack(spacing: 12) {
                    Label("\(scene.keyframes.count)", systemImage: "square.stack.3d.up")
                    Label(formatDuration(scene.totalDuration), systemImage: "clock")
                    if scene.isLooping {
                        Image(systemName: "repeat")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            HStack(spacing: 8) {
                // Reset edited default back to original
                if let onResetDefault {
                    Button { onResetDefault() } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .help("Reset to original")
                }
                if let onPlay {
                    Button { onPlay() } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(scene.keyframes.count < 2)
                }
                if let onEdit {
                    Button { onEdit() } label: {
                        Image(systemName: "pencil")
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
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 60 {
            return String(format: "%.1fs", duration)
        } else {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            return "\(minutes)m \(seconds)s"
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
    
    @State private var selectedKeyframeForEdit: AnimationKeyframe?
    @State private var defaultDuration: Double = 2.0
    @State private var isEditMode: EditMode = .inactive
    @State private var showSceneSettings = false
    
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
            // Header bar
            HStack {
                Button {
                    animationManager.updateScene(scene)
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                Text(scene.name).font(.headline).lineLimit(1)
                Spacer()
                Button(isEditMode == .active ? "Done Reorder" : "Reorder") {
                    withAnimation {
                        isEditMode = isEditMode == .active ? .inactive : .active
                    }
                }
                .font(.subheadline)
                Button {
                    showSceneSettings.toggle()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .font(.subheadline)
                }
                .popover(isPresented: $showSceneSettings, arrowEdge: .top) {
                    sceneSettingsPopover
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            
            Divider()
            
            // Compact default duration row
            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .font(.caption)
                    .frame(width: 16)
                Text("New KF")
                    .font(.subheadline)
                    .frame(width: 56, alignment: .leading)
                    .lineLimit(1)
                Slider(value: $defaultDuration, in: 0.5...10.0, step: 0.5)
                Text("\(String(format: "%.1f", defaultDuration))s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            .frame(height: 32)
            .padding(.horizontal, 16).padding(.vertical, 4)
            
            Divider()
            
            editorList
                .environment(\.editMode, $isEditMode)
        }
        .sheet(item: $selectedKeyframeForEdit) { keyframe in keyframeSheet(for: keyframe) }
    }
    
    // Scene settings popover
    private var sceneSettingsPopover: some View {
        VStack(spacing: 12) {
            Text("Scene Settings").font(.headline)
            TextField("Name", text: $scene.name)
                .textFieldStyle(.roundedBorder)
            Toggle("Loop Animation", isOn: $scene.isLooping)
            HStack {
                Text("Total Duration")
                Spacer()
                Text(formatDuration(scene.totalDuration))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 260)
    }
    
    // Standalone: NavigationStack with toolbar – for sheet presentation
    private var standaloneContent: some View {
        NavigationStack {
            editorList
            .navigationTitle(scene.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        animationManager.updateScene(scene)
                        onDismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        Button {
                            showSceneSettings.toggle()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .popover(isPresented: $showSceneSettings) {
                            sceneSettingsPopover
                        }
                        EditButton()
                    }
                }
            }
            .sheet(item: $selectedKeyframeForEdit) { keyframe in keyframeSheet(for: keyframe) }
        }
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
                    Button {
                        addKeyframe()
                    } label: {
                        Label("Capture", systemImage: "plus.circle.fill")
                            .font(.caption)
                    }
                }
            } footer: {
                Text("Keyframes capture shape, position, quality, and color scheme. Other effects stay as currently set — save a Preset to remember everything.")
            }
        }
        .listStyle(.plain)
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
        settings.targetPosition = keyframe.position
        
        // Apply quality settings
        settings.baseFractalIterations = keyframe.baseFractalIterations
        settings.baseMaxRaySteps = keyframe.baseMaxRaySteps
        
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
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 60 {
            return String(format: "%.1fs", duration)
        } else {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            return "\(minutes)m \(seconds)s"
        }
    }
}

// MARK: - Keyframe Row

struct KeyframeRowView: View {
    let keyframe: AnimationKeyframe
    let index: Int
    let onEdit: () -> Void
    let onJump: () -> Void
    let onOverwrite: () -> Void
    
    var body: some View {
        HStack {
            // Index badge
            Text("\(index + 1)")
                .font(.caption.bold())
                .frame(width: 24, height: 24)
                .background(Circle().fill(.secondary.opacity(0.3)))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(keyframe.name)
                    .font(.subheadline.bold())
                
                // Parameter preview
                HStack(spacing: 8) {
                    paramLabel("MD", value: keyframe.minDistance)
                    paramLabel("FL", value: keyframe.foldingLimit)
                    paramLabel("SR", value: keyframe.sphereRadius)
                    paramLabel("SC", value: keyframe.fractalScale)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Duration (except for first keyframe)
            if index > 0 {
                Text("\(String(format: "%.1f", keyframe.duration))s")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.secondary.opacity(0.2)))
            }
            
            // Overwrite button - replace keyframe with current settings
            Button {
                onOverwrite()
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.plain)
            .help("Overwrite with current settings")
            
            // Edit button
            Button {
                onEdit()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.plain)
            .help("Edit keyframe parameters")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onJump()
        }
    }
    
    private func paramLabel(_ label: String, value: Float) -> some View {
        Text("\(label):\(String(format: "%.2f", value))")
            .monospacedDigit()
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
                // ── LEFT COLUMN: Parameters ──
                ScrollView {
                    VStack(spacing: 16) {
                        // Name
                        HStack {
                            Text("Name").font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            TextField("Keyframe Name", text: $keyframe.name)
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        
                        Divider().padding(.horizontal, 16)
                        
                        // ── Duration ──
                        compactSliderRow(icon: "timer", label: "Duration",
                                         value: $keyframe.duration, range: 0...20, step: 0.5,
                                         format: "%.1fs")
                        
                        Divider().padding(.horizontal, 16)
                        
                        // ── Shape Parameters ──
                        VStack(spacing: 2) {
                            sectionHeader("Shape Parameters")
                            compactSliderRow(icon: "arrow.down.right.and.arrow.up.left", label: "Min Distance",
                                             value: $keyframe.minDistance, range: 0.1...10.0, format: "%.3f")
                            compactSliderRow(icon: "arrow.triangle.branch", label: "Folding Limit",
                                             value: $keyframe.foldingLimit, range: 0.1...20.0, format: "%.3f")
                            compactSliderRow(icon: "circle.dashed", label: "Sphere Radius",
                                             value: $keyframe.sphereRadius, range: 0.01...5.0, format: "%.3f")
                            compactSliderRow(icon: "arrow.up.left.and.arrow.down.right", label: "Fractal Scale",
                                             value: $keyframe.fractalScale, range: 0.5...6.0, format: "%.3f")
                        }
                        
                        Divider().padding(.horizontal, 16)
                        
                        // ── Quality ──
                        VStack(spacing: 2) {
                            sectionHeader("Quality")
                            compactStepperRow(icon: "square.stack.3d.up", label: "Iterations",
                                              value: $keyframe.baseFractalIterations, range: 4...32)
                            compactStepperRow(icon: "line.3.crossed.swirl.circle", label: "Ray Steps",
                                              value: $keyframe.baseMaxRaySteps, range: 32...1024, step: 16)
                        }
                        
                        Divider().padding(.horizontal, 16)
                        
                        // ── Position ──
                        VStack(spacing: 2) {
                            sectionHeader("Position")
                            compactSliderRow(icon: "arrow.left.and.right", label: "X",
                                             value: $keyframe.positionX, range: -5...5, format: "%.2f")
                            compactSliderRow(icon: "arrow.up.and.down", label: "Y",
                                             value: $keyframe.positionY, range: -5...5, format: "%.2f")
                            compactSliderRow(icon: "arrow.forward", label: "Z",
                                             value: $keyframe.positionZ, range: -5...5, format: "%.2f")
                        }
                        
                        Spacer(minLength: 20)
                    }
                    .padding(.top, 8)
                }
                
                Divider()
                
                // ── RIGHT COLUMN: Easing ──
                ScrollView {
                    VStack(spacing: 12) {
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
                            // Bezier presets
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
                                Label("Bezier Preset", systemImage: "curve.bezier")
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
                            // Preview of the selected easing curve
                            EasingCurvePreview(easing: keyframe.easingType)
                                .frame(height: 120)
                                .padding(.horizontal, 16)
                            
                            Text(keyframe.easingType.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer(minLength: 20)
                    }
                    .padding(.top, 8)
                }
                .frame(width: 260)
            }
            .navigationTitle("Edit Keyframe")
            .navigationBarTitleDisplayMode(.inline)
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
        .frame(minWidth: 680, idealWidth: 760, minHeight: 560, idealHeight: 680)
    }
    
    // ── Compact slider row matching EffectSliderRow style ──
    private func compactSliderRow(icon: String, label: String, value: Binding<Float>,
                                   range: ClosedRange<Float>, step: Float? = nil, format: String = "%.3f") -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.primary)
                .frame(width: 16)
            Text(label)
                .font(.subheadline)
                .frame(width: 135, alignment: .leading)
                .lineLimit(1)
            if let step = step {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
            Text(String(format: format, value.wrappedValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .frame(height: 32)
        .padding(.horizontal, 16)
    }
    
    // Duration-specific overload for TimeInterval binding
    private func compactSliderRow(icon: String, label: String, value: Binding<TimeInterval>,
                                   range: ClosedRange<TimeInterval>, step: Double = 0.5, format: String = "%.1fs") -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.primary)
                .frame(width: 16)
            Text(label)
                .font(.subheadline)
                .frame(width: 135, alignment: .leading)
                .lineLimit(1)
            Slider(value: value, in: range, step: step)
            Text(String(format: format, value.wrappedValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .frame(height: 32)
        .padding(.horizontal, 16)
    }
    
    private func compactStepperRow(icon: String, label: String, value: Binding<Int>,
                                    range: ClosedRange<Int>, step: Int = 1) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.primary)
                .frame(width: 16)
            Text(label)
                .font(.subheadline)
                .frame(width: 135, alignment: .leading)
                .lineLimit(1)
            Spacer()
            Stepper("\(value.wrappedValue)", value: value, in: range, step: step)
                .fixedSize()
        }
        .frame(height: 32)
        .padding(.horizontal, 16)
    }
    
    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }
}

// MARK: - Playback Controls View

/// Compact playback controls to embed in main UI
struct AnimationPlaybackControls: View {
    @Bindable var animationManager: AnimationManager
    
    var body: some View {
        VStack(spacing: 8) {
            if let scene = animationManager.currentScene {
                // Scene name and progress
                HStack {
                    Text(scene.name)
                        .font(.caption.bold())
                    Spacer()
                    Text(progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(.secondary.opacity(0.3))
                        Rectangle()
                            .fill(.blue)
                            .frame(width: geo.size.width * progressFraction)
                    }
                }
                .frame(height: 4)
                .clipShape(Capsule())
                
                // Controls
                HStack(spacing: 16) {
                    Button {
                        animationManager.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .disabled(!animationManager.isPlaying && animationManager.playhead.state != .paused)
                    
                    Button {
                        animationManager.togglePlayPause()
                    } label: {
                        Image(systemName: animationManager.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .font(.title2)
                    
                    // Speed control
                    Menu {
                        Button("0.5x") { animationManager.playbackSpeed = 0.5 }
                        Button("1x") { animationManager.playbackSpeed = 1.0 }
                        Button("2x") { animationManager.playbackSpeed = 2.0 }
                        Button("4x") { animationManager.playbackSpeed = 4.0 }
                    } label: {
                        Text("\(String(format: "%.1f", animationManager.playbackSpeed))x")
                            .font(.caption)
                    }
                    
                    // Easing function picker
                    Menu {
                        ForEach(EasingFunction.allCases, id: \.self) { easing in
                            Button {
                                animationManager.easingFunction = easing
                            } label: {
                                HStack {
                                    Text(easing.displayName)
                                    if animationManager.easingFunction == easing {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: animationManager.easingFunction == .smooth ? "waveform.path" : "curve.bezier")
                            Text(animationManager.easingFunction.displayName)
                                .font(.caption)
                        }
                    }
                    
                    Spacer()
                    
                    // Keyframe indicator
                    Text("KF \(animationManager.playhead.currentKeyframeIndex + 1)/\(scene.keyframes.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No scene selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    private var progressText: String {
        guard let scene = animationManager.currentScene else { return "" }
        let current = currentTime
        let total = scene.totalDuration
        return "\(formatTime(current)) / \(formatTime(total))"
    }
    
    private var currentTime: TimeInterval {
        guard let scene = animationManager.currentScene else { return 0 }
        
        var time: TimeInterval = 0
        for i in 0..<animationManager.playhead.currentKeyframeIndex {
            if i < scene.keyframes.count {
                time += scene.keyframes[i].duration
            }
        }
        time += animationManager.playhead.elapsedInSegment
        return time
    }
    
    private var progressFraction: CGFloat {
        guard let scene = animationManager.currentScene,
              scene.totalDuration > 0 else { return 0 }
        return CGFloat(currentTime / scene.totalDuration)
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let seconds = Int(time) % 60
        let tenths = Int((time - Double(Int(time))) * 10)
        return "\(seconds).\(tenths)"
    }
}

// MARK: - Bezier Curve Preview

/// Visual preview of a cubic Bezier easing curve.
/// Shows the curve from (0,0) to (1,1) with control point indicators.
struct BezierCurvePreview: View {
    let handle: BezierHandle
    
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let padding: CGFloat = 16
            let plotW = w - padding * 2
            let plotH = h - padding * 2
            
            Canvas { context, size in
                // Background grid
                let gridColor = Color.secondary.opacity(0.15)
                for i in 0...4 {
                    let frac = CGFloat(i) / 4.0
                    // Vertical
                    let x = padding + frac * plotW
                    context.stroke(
                        Path { p in p.move(to: CGPoint(x: x, y: padding)); p.addLine(to: CGPoint(x: x, y: padding + plotH)) },
                        with: .color(gridColor), lineWidth: 0.5
                    )
                    // Horizontal
                    let y = padding + frac * plotH
                    context.stroke(
                        Path { p in p.move(to: CGPoint(x: padding, y: y)); p.addLine(to: CGPoint(x: padding + plotW, y: y)) },
                        with: .color(gridColor), lineWidth: 0.5
                    )
                }
                
                // Diagonal reference (linear)
                context.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: padding, y: padding + plotH))
                        p.addLine(to: CGPoint(x: padding + plotW, y: padding))
                    },
                    with: .color(Color.secondary.opacity(0.25)), lineWidth: 1
                )
                
                // Bezier curve
                let curvePath = Path { p in
                    let steps = 60
                    for i in 0...steps {
                        let t = Float(i) / Float(steps)
                        let eased = CubicBezier.evaluate(t, handle: handle)
                        let x = padding + CGFloat(t) * plotW
                        let y = padding + plotH - CGFloat(eased) * plotH
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                        else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                context.stroke(curvePath, with: .color(.blue), lineWidth: 2.5)
                
                // Control point 1 handle line
                let cp1 = CGPoint(x: padding + CGFloat(handle.cp1x) * plotW,
                                  y: padding + plotH - CGFloat(handle.cp1y) * plotH)
                let start = CGPoint(x: padding, y: padding + plotH)
                context.stroke(
                    Path { p in p.move(to: start); p.addLine(to: cp1) },
                    with: .color(.orange.opacity(0.6)), lineWidth: 1
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: cp1.x - 4, y: cp1.y - 4, width: 8, height: 8)),
                    with: .color(.orange)
                )
                
                // Control point 2 handle line
                let cp2 = CGPoint(x: padding + CGFloat(handle.cp2x) * plotW,
                                  y: padding + plotH - CGFloat(handle.cp2y) * plotH)
                let end = CGPoint(x: padding + plotW, y: padding)
                context.stroke(
                    Path { p in p.move(to: end); p.addLine(to: cp2) },
                    with: .color(.green.opacity(0.6)), lineWidth: 1
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: cp2.x - 4, y: cp2.y - 4, width: 8, height: 8)),
                    with: .color(.green)
                )
                
                // Start/end dots
                context.fill(
                    Path(ellipseIn: CGRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6)),
                    with: .color(.primary)
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6)),
                    with: .color(.primary)
                )
            }
        }
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Easing Curve Preview (non-Bezier)

/// Simple curve preview that uses EasingFunction.apply() to draw the easing shape.
struct EasingCurvePreview: View {
    let easing: EasingFunction
    
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let padding: CGFloat = 16
            let plotW = w - padding * 2
            let plotH = h - padding * 2
            
            Canvas { context, _ in
                // Background grid
                let gridColor = Color.secondary.opacity(0.15)
                for i in 0...4 {
                    let frac = CGFloat(i) / 4.0
                    let x = padding + frac * plotW
                    context.stroke(
                        Path { p in p.move(to: CGPoint(x: x, y: padding)); p.addLine(to: CGPoint(x: x, y: padding + plotH)) },
                        with: .color(gridColor), lineWidth: 0.5
                    )
                    let y = padding + frac * plotH
                    context.stroke(
                        Path { p in p.move(to: CGPoint(x: padding, y: y)); p.addLine(to: CGPoint(x: padding + plotW, y: y)) },
                        with: .color(gridColor), lineWidth: 0.5
                    )
                }
                
                // Diagonal reference (linear)
                context.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: padding, y: padding + plotH))
                        p.addLine(to: CGPoint(x: padding + plotW, y: padding))
                    },
                    with: .color(Color.secondary.opacity(0.25)), lineWidth: 1
                )
                
                // Easing curve
                let curvePath = Path { p in
                    let steps = 60
                    for i in 0...steps {
                        let t = Float(i) / Float(steps)
                        let eased = easing.apply(t)
                        let x = padding + CGFloat(t) * plotW
                        let y = padding + plotH - CGFloat(eased) * plotH
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                        else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                context.stroke(curvePath, with: .color(.blue), lineWidth: 2.5)
            }
        }
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Preview

#Preview {
    SceneListView(
        animationManager: AnimationManager(),
        appModel: AppModel()
    )
}
