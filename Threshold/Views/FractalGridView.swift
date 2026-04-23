//
//  FractalGridView.swift
//  Threshold
//
//  Grid-based fractal type selector — dedicated "Formulas" tab.
//

import SwiftUI

private enum FractalBrowseInnerTab: String, CaseIterable {
    case formulas = "Formulas"
    case scenes = "Scenes"
}

struct FractalGridView: View {
    var cache: UISettingsCache
    let gestureController: GestureController?
    let animationManager: AnimationManager?
    var onEditScene: ((AnimationScene) -> Void)? = nil
    @State private var innerTab: FractalBrowseInnerTab = .formulas

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 12)]
    private let sceneColumns = [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 12)]
    private static let categoryOrder = ["Box Folds", "Power / Quaternion", "Hybrid Folds", "Kaleidoscopic IFS"]

    /// Categories in display order, derived once from the selectable descriptors.
    private let categorizedTypes: [(category: String, types: [FractalModelType])] = Self.cachedCategorizedTypes

    /// Cache the category grouping once so entering the tab does not redo the
    /// descriptor walk every time SwiftUI recreates the view.
    private static let cachedCategorizedTypes = Self.makeCategorizedTypes()

    private static func makeCategorizedTypes() -> [(category: String, types: [FractalModelType])] {
        let selectable = FractalModelType.selectableCases
        var seen: [String: [FractalModelType]] = [:]
        var order: [String] = []
        for type in selectable {
            let category = type.category
            if seen[category] == nil { order.append(category) }
            seen[category, default: []].append(type)
        }
        let preferredOrder = categoryOrder.filter { seen[$0] != nil }
        let remainingOrder = order.filter { !categoryOrder.contains($0) }
        return (preferredOrder + remainingOrder).map { category in (category: category, types: seen[category] ?? []) }
    }

    var body: some View {
        let hasScenes = animationManager?.scenes.isEmpty == false
        let selectedTab = hasScenes ? innerTab : .formulas

        VStack(spacing: 10) {
            if hasScenes {
                Picker("Browse", selection: $innerTab) {
                    ForEach(FractalBrowseInnerTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    switch selectedTab {
                    case .formulas:
                        ForEach(categorizedTypes, id: \.category) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.category)
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)

                                LazyVGrid(columns: columns, spacing: 12) {
                                    ForEach(group.types, id: \.self) { type in
                                        FractalGridCell(
                                            type: type,
                                            isSelected: type == cache.fractalType
                                        ) {
                                            cache.fractalType = type
                                            cache.pushFractalType(type, gestureController: gestureController)
                                        }
                                    }
                                }
                            }
                        }

                    case .scenes:
                        if let animationManager {
                            sceneGrid(animationManager)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func sceneGrid(_ animationManager: AnimationManager) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Fractal Scenes", systemImage: "film.stack")
                    .font(.headline)
                Text("Choose the active scene for the animation player and editor from a grid while you browse.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("Current: \(animationManager.currentScene?.name ?? "None")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            LazyVGrid(columns: sceneColumns, spacing: 12) {
                sceneCard(
                    title: "None",
                    subtitle: "No scene selected",
                    detail: "Animation playback is detached from scenes.",
                    systemImage: "xmark.circle",
                    isSelected: animationManager.currentScene == nil
                ) {
                    animationManager.currentScene = nil
                }

                ForEach(animationManager.scenes) { scene in
                    sceneCard(
                        title: scene.name,
                        subtitle: scene.fractalType?.displayName ?? "Any fractal",
                        detail: scene.attachedSong?.title ?? "Visual-only scene",
                        systemImage: scene.attachedSong == nil ? "sparkles.rectangle.stack" : "music.note",
                        isSelected: animationManager.currentScene?.id == scene.id,
                        onEdit: { onEditScene?(scene) }
                    ) {
                        selectScene(scene, using: animationManager)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.07)))
    }

    private func selectScene(_ scene: AnimationScene, using animationManager: AnimationManager) {
        animationManager.currentScene = scene

        guard scene.keyframes.count >= 2 else { return }
        animationManager.play()
    }

    private func sceneCard(title: String, subtitle: String, detail: String, systemImage: String, isSelected: Bool, onEdit: (() -> Void)? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.subheadline)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)

                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer(minLength: 0)

                if isSelected {
                    Label("Selected", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.blue.opacity(0.2) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.blue.opacity(0.55) : Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.6, maximumDistance: 24)
                .onEnded { _ in onEdit?() }
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Grid Cell

private struct FractalGridCell: View {
    let type: FractalModelType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: type.icon)
                    .font(.system(size: 28))
                    .frame(height: 32)

                Text(type.displayName)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.blue.opacity(0.25) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.blue.opacity(0.6) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(type.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
