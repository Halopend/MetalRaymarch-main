//
//  AnimationViews.swift
//  MetalRaymarch
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
                                },
                                onOverwrite: {
                                    // Overwrite this keyframe with current settings
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
                    Text("Keyframes capture shape, position & quality only. Colors and effects stay as currently set — save a Preset to remember everything.")
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
                
                // ═══════════════════════════════════════════════════════════════
                // EASING / BEZIER CURVE
                // ═══════════════════════════════════════════════════════════════
                
                Section {
                    // Easing type picker
                    Picker("Easing", selection: $keyframe.easingType) {
                        ForEach(EasingFunction.allCases, id: \.self) { easing in
                            Label(easing.displayName, systemImage: easing.icon)
                                .tag(easing)
                        }
                    }
                    
                    if keyframe.easingType == .bezier {
                        // Bezier preset picker
                        HStack {
                            Text("Preset")
                            Spacer()
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
                                Text("Apply Preset")
                                    .font(.caption)
                            }
                        }
                        
                        // Bezier curve preview
                        BezierCurvePreview(handle: keyframe.bezierHandle)
                            .frame(height: 120)
                            .padding(.vertical, 4)
                        
                        // Control point sliders
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Control Point 1").font(.caption).foregroundStyle(.secondary)
                            parameterSlider("CP1 X (time)", value: $keyframe.bezierHandle.cp1x, range: 0...1)
                            parameterSlider("CP1 Y (value)", value: $keyframe.bezierHandle.cp1y, range: -0.5...1.5)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Control Point 2").font(.caption).foregroundStyle(.secondary)
                            parameterSlider("CP2 X (time)", value: $keyframe.bezierHandle.cp2x, range: 0...1)
                            parameterSlider("CP2 Y (value)", value: $keyframe.bezierHandle.cp2y, range: -0.5...1.5)
                        }
                    }
                } header: {
                    Text("Easing Curve")
                } footer: {
                    if keyframe.easingType == .bezier {
                        Text("Drag control points or use presets. Y values outside 0-1 create overshoot/anticipation effects.")
                    } else {
                        Text("Controls how the transition to this keyframe is timed.")
                    }
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

// MARK: - Preview

#Preview {
    SceneListView(
        animationManager: AnimationManager(),
        appModel: AppModel()
    )
}
