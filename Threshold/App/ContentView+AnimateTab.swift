//
//  ContentView+AnimateTab.swift
//  Threshold
//
//  Animate tab UI extracted from ContentView.swift (Phase C refactor).
//  Stored properties remain on the main `ContentView` struct.
//

import SwiftUI

extension ContentView {
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Animate Tab
    // ═══════════════════════════════════════════════════════════════════════════
    
    var animateTabContent: some View {
        VStack(spacing: 0) {
            animateToolbar
            animatePlayContent
        }
    }

    private var animateToolbar: some View {
        HStack(spacing: 10) {
            Label("Scenes", systemImage: AppIcons.filmStack)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer()

            Picker("Mode", selection: Binding(
                get: { animateEditButtonsVisible ? 1 : 0 },
                set: { newValue in
                    withAnimation(.snappy(duration: 0.22, extraBounce: 0.10)) {
                        animateEditButtonsVisible = (newValue == 1)
                    }
                    if newValue == 0 {
                        #if os(iOS)
                        isAnimationEditorPresented = false
                        #else
                        dismissWindow(id: AppModel.animationEditorWindowID)
                        #endif
                    }
                }
            )) {
                Text("Play").tag(0)
                Text("Edit").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 170)

            if animateEditButtonsVisible {
                Button {
                    openAnimationEditor()
                } label: {
                    Image(systemName: AppIcons.plus)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.blue.opacity(0.14)))
                        .overlay(Circle().stroke(Color.blue.opacity(0.30), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22, extraBounce: 0.10), value: animateEditButtonsVisible)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
    
    private var animatePlayContent: some View {
        VStack(spacing: 0) {
            infiniteZoomCard
            if let animationManager = appModel.animationManager {
                List {
                    if animationManager.scenes.isEmpty {
                        ContentUnavailableView {
                            Label("No Scenes", systemImage: AppIcons.filmStack)
                        } description: {
                            Text("Create a scene from the current fractal, then capture another keyframe to animate between states.")
                        } actions: {
                            Button("Open Animation Editor") {
                                openAnimationEditor()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else {
                        ForEach(animationManager.scenes) { scene in
                            SceneRowView(
                                scene: scene,
                                isSelected: animationManager.currentScene?.id == scene.id,
                                isDefault: animationManager.isDefaultScene(scene),
                                isEdited: animationManager.isEditedDefault(scene),
                                onSelect: { animationManager.currentScene = scene },
                                onEdit: animateEditButtonsVisible ? {
                                    openAnimationEditor(for: scene)
                                } : nil,
                                onPlay: animateEditButtonsVisible ? nil : {
                                    animationManager.currentScene = scene
                                    animationManager.play()
                                    dismissMenuWindowIfNeeded()
                                },
                                isPlaying: animationManager.isPlaying
                                    && animationManager.currentScene?.id == scene.id,
                                isPaused: animationManager.isPaused
                                    && animationManager.currentScene?.id == scene.id,
                                onPause: animateEditButtonsVisible ? nil : {
                                    animationManager.pause()
                                },
                                onStop: animateEditButtonsVisible ? nil : {
                                    animationManager.stop()
                                }
                            )
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Infinite Zoom
    // ═══════════════════════════════════════════════════════════════════════════

    /// Continuous auto-descent into the current fractal. Independent of scenes —
    /// the driver lives in RenderSettings.interpolateToTargets and advances the
    /// zoom (detailScale) target every frame. Grab/scroll still steer on top.
    private var infiniteZoomCard: some View {
        let accent = Color.blue
        return VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { appModel.renderSettings.infiniteZoomEnabled },
                set: { appModel.renderSettings.infiniteZoomEnabled = $0 }
            )) {
                HStack(spacing: 8) {
                    Image(systemName: "infinity")
                        .font(.headline)
                        .foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Infinite Zoom")
                        Text("Continuously dives into the fractal. Set speed and direction below; grab and scroll still steer while it runs.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .tint(accent)

            // Signed speed: zoom out ← center (still) → zoom in
            HStack(spacing: 8) {
                Text("Out").font(.caption2).foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { appModel.renderSettings.infiniteZoomRate },
                        set: { appModel.renderSettings.infiniteZoomRate = $0 }
                    ),
                    in: -RenderSettings.infiniteZoomMaxRate...RenderSettings.infiniteZoomMaxRate
                )
                .tint(accent)
                Text("In").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    func openAnimationEditor(for scene: AnimationScene? = nil) {
        guard let animationManager = appModel.animationManager else { return }
        if let scene {
            animationManager.currentScene = scene
        } else if animationManager.currentScene == nil {
            animationManager.currentScene = animationManager.scenes.first
        }
        #if os(iOS)
        isAnimationEditorPresented = true
        #else
        openWindow(id: AppModel.animationEditorWindowID)
        #endif
    }
}
