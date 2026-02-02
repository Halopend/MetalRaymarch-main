//
//  AnimationViews.swift
//  MetalRaymarch
//
//  UI for scene management, keyframe editing, and playback controls.
//

import SwiftUI

// MARK: - Scene List View

/// Main view showing all saved scenes with create/edit/delete actions
struct SceneListView: View {
    @Bindable var animationManager: AnimationManager
    @Bindable var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingCreateSheet = false
    @State private var newSceneName = ""
    @State private var selectedSceneForEdit: AnimationScene?
    
    var body: some View {
        NavigationStack {
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
                            onSelect: {
                                animationManager.currentScene = scene
                            },
                            onEdit: {
                                selectedSceneForEdit = scene
                            },
                            onPlay: {
                                animationManager.currentScene = scene
                                animationManager.play()
                            }
                        )
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            animationManager.deleteScene(animationManager.scenes[index])
                        }
                    }
                }
            }
            .navigationTitle("Scenes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
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
            .sheet(isPresented: $showingCreateSheet) {
                CreateSceneSheet(
                    sceneName: $newSceneName,
                    onCreate: {
                        let scene = animationManager.createScene(name: newSceneName)
                        animationManager.currentScene = scene
                        showingCreateSheet = false
                        // Automatically open editor for new scene
                        selectedSceneForEdit = scene
                    },
                    onCancel: {
                        showingCreateSheet = false
                    }
                )
            }
            .sheet(item: $selectedSceneForEdit) { scene in
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
    }
}

// MARK: - Scene Row

struct SceneRowView: View {
    let scene: AnimationScene
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onPlay: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(scene.name)
                        .font(.headline)
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
                Button {
                    onPlay()
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.bordered)
                .disabled(scene.keyframes.count < 2)
                
                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.bordered)
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
    
    @State private var selectedKeyframeForEdit: AnimationKeyframe?
    @State private var defaultDuration: Double = 2.0
    
    var body: some View {
        NavigationStack {
            List {
                // Scene Settings Section
                Section("Scene Settings") {
                    TextField("Name", text: $scene.name)
                    
                    Toggle("Loop Animation", isOn: $scene.isLooping)
                    
                    HStack {
                        Text("Total Duration")
                        Spacer()
                        Text(formatDuration(scene.totalDuration))
                            .foregroundStyle(.secondary)
                    }
                }
                
                // Default Duration for New Keyframes
                Section("New Keyframe Duration") {
                    HStack {
                        Text("\(String(format: "%.1f", defaultDuration))s")
                            .monospacedDigit()
                        Slider(value: $defaultDuration, in: 0.5...10.0, step: 0.5)
                    }
                }
                
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
                                    // Apply this keyframe's values immediately
                                    applyKeyframe(keyframe)
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
                    Text("Tap + to capture current parameters as a new keyframe. Swipe to delete.")
                }
            }
            .navigationTitle("Edit Scene")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        animationManager.updateScene(scene)
                        onDismiss()
                    }
                }
                
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
            .sheet(item: $selectedKeyframeForEdit) { keyframe in
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
        }
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
            
            // Jump to button
            Button {
                onJump()
            } label: {
                Image(systemName: "arrow.right.circle")
            }
            .buttonStyle(.plain)
            
            // Edit button
            Button {
                onEdit()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.plain)
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
            Form {
                Section("Basic") {
                    TextField("Name", text: $keyframe.name)
                    
                    HStack {
                        Text("Duration")
                        Spacer()
                        Text("\(String(format: "%.1f", keyframe.duration))s")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $keyframe.duration, in: 0...20, step: 0.5)
                }
                
                Section("Shape Parameters") {
                    parameterSlider("Min Distance", value: $keyframe.minDistance, range: 0.1...10.0)
                    parameterSlider("Folding Limit", value: $keyframe.foldingLimit, range: 0.1...20.0)
                    parameterSlider("Sphere Radius", value: $keyframe.sphereRadius, range: 0.01...5.0)
                    parameterSlider("Fractal Scale", value: $keyframe.fractalScale, range: 0.5...6.0)
                }
                
                Section {
                    Stepper("Iterations: \(keyframe.baseFractalIterations)", value: $keyframe.baseFractalIterations, in: 4...32)
                    Stepper("Max Ray Steps: \(keyframe.baseMaxRaySteps)", value: $keyframe.baseMaxRaySteps, in: 32...1024, step: 16)
                } header: {
                    Text("Quality Settings")
                } footer: {
                    Text("Note: These snap between values and do not vary smoothly over time.")
                }
                
                Section("Position") {
                    parameterSlider("X", value: $keyframe.positionX, range: -5...5)
                    parameterSlider("Y", value: $keyframe.positionY, range: -5...5)
                    parameterSlider("Z", value: $keyframe.positionZ, range: -5...5)
                }
            }
            .navigationTitle("Edit Keyframe")
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
        .presentationDetents([.large])
    }
    
    private func parameterSlider(_ label: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.3f", value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
        }
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

// MARK: - Preview

#Preview {
    SceneListView(
        animationManager: AnimationManager(),
        appModel: AppModel()
    )
}
