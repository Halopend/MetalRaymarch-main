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
                        dismissWindow(id: AppModel.animationEditorWindowID)
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
            if let animationManager = appModel.animationManager {
                List {
                    if animationManager.scenes.isEmpty {
                        ContentUnavailableView("No Scenes", systemImage: AppIcons.filmStack,
                            description: Text("Open Scene Editor to create animation scenes"))
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
                                }
                            )
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    func openAnimationEditor(for scene: AnimationScene? = nil) {
        guard let animationManager = appModel.animationManager else { return }
        if let scene {
            animationManager.currentScene = scene
        } else if animationManager.currentScene == nil {
            animationManager.currentScene = animationManager.scenes.first
        }
        openWindow(id: AppModel.animationEditorWindowID)
    }
}
