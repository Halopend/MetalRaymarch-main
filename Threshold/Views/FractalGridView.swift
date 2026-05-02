//
//  FractalGridView.swift
//  Threshold
//
//  Grid-based fractal type selector — dedicated "Formulas" tab.
//

import SwiftUI

private enum FractalBrowseInnerTab: String, CaseIterable {
    case formulas = "Formulas"
    case staticScenes = "Static"
    case animated = "Animated"
}

private enum FractalSceneSelection: Equatable {
    case none
    case animation(UUID)
    case staticPreset(UUID)
}

struct FractalGridView: View {
    var cache: UISettingsCache
    let gestureController: GestureController?
    let animationManager: AnimationManager?
    let presetManager: PresetManager?
    var onEditScene: ((AnimationScene) -> Void)? = nil
    var onLoadAnimationScene: ((AnimationScene) -> Void)? = nil
    var onLoadStaticScene: ((FractalPreset) -> Void)? = nil
    @AppStorage("FractalGridView.innerTab") private var innerTab: FractalBrowseInnerTab = .formulas
    @SceneStorage("FractalGridView.selectedStaticSceneID") private var selectedStaticSceneIDRaw: String?

    private let columns = Array(repeating: GridItem(.flexible(minimum: 180), spacing: 12), count: 3)
    private let sceneColumns = Array(repeating: GridItem(.flexible(minimum: 150), spacing: 12), count: 4)
    private static let categoryOrder = ["Box Folds", "Power / Quaternion", "Hybrid Folds", "Kaleidoscopic IFS"]

    /// Formula types sorted by category order first, then display name.
    private let orderedTypes: [FractalModelType] = Self.cachedOrderedTypes

    private static let cachedOrderedTypes = Self.makeOrderedTypes()

    private var selectedStaticSceneID: UUID? {
        get {
            guard let selectedStaticSceneIDRaw else { return nil }
            return UUID(uuidString: selectedStaticSceneIDRaw)
        }
        nonmutating set {
            selectedStaticSceneIDRaw = newValue?.uuidString
        }
    }

    private static func makeOrderedTypes() -> [FractalModelType] {
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
        return (preferredOrder + remainingOrder)
            .flatMap { category in
                (seen[category] ?? []).sorted {
                    $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
            }
    }

    var body: some View {
        let hasScenes = animationManager?.scenes.isEmpty == false
        // If the persisted tab is "animated" but there are no animation scenes,
        // gracefully fall back to formulas without overwriting the stored choice.
        let selectedTab: FractalBrowseInnerTab = (innerTab == .animated && !hasScenes) ? .formulas : innerTab

        VStack(spacing: 10) {
            Picker("Browse", selection: $innerTab) {
                ForEach(FractalBrowseInnerTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    switch selectedTab {
                    case .formulas:
                        VStack(alignment: .leading, spacing: 10) {
                            browserHeader(
                                title: "Fractal Formulas",
                                systemImage: "square.grid.2x2",
                                description: "Choose a formula from the same card browser used for scenes.",
                                current: cache.fractalType.displayName,
                                accentColor: .pink
                            )

                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(orderedTypes, id: \.self) { type in
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
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.pink.opacity(0.08)))

                    case .animated:
                        if let animationManager {
                            animatedScenesGrid(animationManager)
                        }

                    case .staticScenes:
                        if let animationManager {
                            staticScenesGrid(animationManager)
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
    private func animatedScenesGrid(_ animationManager: AnimationManager) -> some View {
        let staticScenePresets = filteredStaticPresets()
        let activeSelection = currentSceneSelection(using: animationManager, staticScenePresets: staticScenePresets)

        VStack(alignment: .leading, spacing: 10) {
            browserHeader(
                title: "Animated Scenes",
                systemImage: "sparkles.rectangle.stack",
                description: "Keyframed animations and music-attached scenes.",
                current: currentSceneSelectionLabel(selection: activeSelection, animationManager: animationManager, staticScenePresets: staticScenePresets),
                accentColor: .purple
            )

            if animationManager.scenes.isEmpty {
                emptySectionLabel("No animated scenes yet")
            } else {
                LazyVGrid(columns: sceneColumns, spacing: 12) {
                    ForEach(Array(animationManager.scenes.enumerated()), id: \.offset) { _, scene in
                        sceneCard(
                            title: scene.name,
                            subtitle: scene.fractalType?.displayName ?? "Any fractal",
                            detail: scene.attachedSong?.title ?? "Visual-only scene",
                            systemImage: scene.attachedSong == nil ? "sparkles.rectangle.stack" : "music.note",
                            showsFlashingWarning: scene.name.localizedCaseInsensitiveContains("ambient blur"),
                            isSelected: activeSelection == .animation(scene.id),
                            onEdit: { onEditScene?(scene) }
                        ) {
                            selectScene(scene, using: animationManager)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.purple.opacity(0.08)))
    }

    @ViewBuilder
    private func staticScenesGrid(_ animationManager: AnimationManager) -> some View {
        let staticScenePresets = filteredStaticPresets()
        let activeSelection = currentSceneSelection(using: animationManager, staticScenePresets: staticScenePresets)

        VStack(alignment: .leading, spacing: 10) {
            browserHeader(
                title: "Static Scenes",
                systemImage: "photo.on.rectangle.angled",
                description: "Saved still presets — tap to load instantly.",
                current: currentSceneSelectionLabel(selection: activeSelection, animationManager: animationManager, staticScenePresets: staticScenePresets),
                accentColor: .teal
            )

            if staticScenePresets.isEmpty {
                emptySectionLabel("No static scenes saved")
            } else {
                LazyVGrid(columns: sceneColumns, spacing: 12) {
                    ForEach(Array(staticScenePresets.enumerated()), id: \.offset) { _, preset in
                        sceneCard(
                            title: preset.name,
                            subtitle: preset.fractalType.displayName,
                            detail: staticSceneDetail(for: preset),
                            systemImage: (preset.musicReactiveMappings?.isEmpty == false) ? "music.note" : "photo",
                            isSelected: activeSelection == .staticPreset(preset.id),
                            onEdit: nil
                        ) {
                            selectStaticScenePreset(preset, using: animationManager)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.teal.opacity(0.08)))
    }

    private func filteredStaticPresets() -> [FractalPreset] {
        (presetManager?.presets ?? []).filter { preset in
            // Skip transient utility entries if they ever leak into the shared preset list.
            preset.name != "__lastState__"
        }
    }

    private func emptySectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }
    private func currentSceneSelection(using animationManager: AnimationManager, staticScenePresets: [FractalPreset]) -> FractalSceneSelection {
        if let sceneID = animationManager.currentScene?.id {
            return .animation(sceneID)
        }

        guard let staticID = selectedStaticSceneID,
              staticScenePresets.contains(where: { $0.id == staticID }) else {
            return .none
        }
        return .staticPreset(staticID)
    }

    private func currentSceneSelectionLabel(selection: FractalSceneSelection, animationManager: AnimationManager, staticScenePresets: [FractalPreset]) -> String {
        switch selection {
        case .none:
            return "Choose a scene"
        case .animation(let sceneID):
            return animationManager.scenes.first(where: { $0.id == sceneID })?.name
                ?? animationManager.currentScene?.name
                ?? "Scene"
        case .staticPreset(let presetID):
            return staticScenePresets.first(where: { $0.id == presetID })?.name
                ?? "Static Scene"
        }
    }

    private func selectScene(_ scene: AnimationScene, using animationManager: AnimationManager) {
        selectedStaticSceneID = nil
        animationManager.currentScene = scene
        onLoadAnimationScene?(scene)

        if scene.keyframes.count == 1 {
            animationManager.jumpToKeyframe(0)
            return
        }

        guard scene.keyframes.count >= 2 else { return }
        animationManager.play()
    }

    private func selectStaticScenePreset(_ preset: FractalPreset, using animationManager: AnimationManager) {
        selectedStaticSceneID = preset.id
        animationManager.clearCurrentSceneSelection()
        onLoadStaticScene?(preset)
    }

    private func staticSceneDetail(for preset: FractalPreset) -> String {
        if preset.musicReactiveMappings?.isEmpty == false {
            return "Static music-reactive scene"
        }
        return "Static scene preset"
    }

    private func browserHeader(title: String, systemImage: String, description: String, current: String, accentColor: Color) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 4) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .lineLimit(1)

                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            Text("Current: \(current)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(accentColor)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(accentColor.opacity(0.12))
                )
        }
    }

    private func sceneCard(title: String, subtitle: String, detail: String, systemImage: String, showsFlashingWarning: Bool = false, isSelected: Bool, onEdit: (() -> Void)? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.subheadline)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            if showsFlashingWarning {
                                FlashingLightIndicator()
                                    .help("Contains flashing or rapidly changing light.")
                            }
                        }

                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
            .frame(maxWidth: .infinity, minHeight: 116, maxHeight: 116, alignment: .leading)
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: type.icon)
                        .font(.subheadline)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(type.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        Text(type.category)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Color.secondary.opacity(0.12))
                            )
                    }
                }

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
        .accessibilityLabel(type.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
