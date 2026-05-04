//
//  FractalGridView.swift
//  Threshold
//
//  Browse surface for scene discovery and recall.
//

import SwiftUI

enum FractalBrowseTab: String, CaseIterable {
    case jumpingOff = "Jumping Off"
    case musicReactive = "Music Reactive"
    case animated = "Animated"
    case customScenes = "Custom Scenes"
}

/// Category-ordered list of selectable formulas, used by both the Browse and
/// Shape tabs.
enum FractalFormulaOrder {
    static let categoryOrder = ["Box Folds", "Power / Quaternion", "Hybrid Folds", "Kaleidoscopic IFS"]

    static let orderedTypes: [FractalModelType] = makeOrderedTypes()

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
}

private enum FractalSceneSelection: Equatable {
    case none
    case animation(UUID)
    case staticPreset(UUID)
}

struct FractalGridView: View {
    private static let jumpingOffNameOverrides: Set<String> = [
        "mandel box flower",
        "replace that",
        "the lovely bones",
        "definitely aliens",
        "ladybug two",
        "ring around the rosie",
        "a space ring odyssey"
    ]

    var cache: UISettingsCache
    let gestureController: GestureController?
    let animationManager: AnimationManager?
    let presetManager: PresetManager?
    var onEditScene: ((AnimationScene) -> Void)? = nil
    var onLoadAnimationScene: ((AnimationScene) -> Void)? = nil
    var onLoadStaticScene: ((FractalPreset) -> Void)? = nil
    var tabSelection: Binding<FractalBrowseTab>? = nil
    @AppStorage("FractalGridView.innerTab") private var storedTabSelection: FractalBrowseTab = .jumpingOff
    @SceneStorage("FractalGridView.selectedStaticSceneID") private var selectedStaticSceneIDRaw: String?
    private let sceneColumns = Array(repeating: GridItem(.flexible(minimum: 150), spacing: 12), count: 4)

    init(
        cache: UISettingsCache,
        gestureController: GestureController?,
        animationManager: AnimationManager?,
        presetManager: PresetManager?,
        tabSelection: Binding<FractalBrowseTab>? = nil,
        onEditScene: ((AnimationScene) -> Void)? = nil,
        onLoadAnimationScene: ((AnimationScene) -> Void)? = nil,
        onLoadStaticScene: ((FractalPreset) -> Void)? = nil
    ) {
        self.cache = cache
        self.gestureController = gestureController
        self.animationManager = animationManager
        self.presetManager = presetManager
        self.tabSelection = tabSelection
        self.onEditScene = onEditScene
        self.onLoadAnimationScene = onLoadAnimationScene
        self.onLoadStaticScene = onLoadStaticScene
    }

    private var effectiveTabSelection: Binding<FractalBrowseTab> {
        Binding(
            get: { tabSelection?.wrappedValue ?? storedTabSelection },
            set: { newValue in
                storedTabSelection = newValue
                tabSelection?.wrappedValue = newValue
            }
        )
    }

    private var selectedStaticSceneID: UUID? {
        get {
            guard let selectedStaticSceneIDRaw else { return nil }
            return UUID(uuidString: selectedStaticSceneIDRaw)
        }
        nonmutating set {
            selectedStaticSceneIDRaw = newValue?.uuidString
        }
    }


    var body: some View {
        let allScenes = animationManager?.scenes ?? []
        let hasCustomScenes = !customScenePresets().isEmpty
        let hasAnimatedScenes = allScenes.contains { $0.keyframes.count >= 2 }
        let currentTab = effectiveTabSelection.wrappedValue
        let selectedTab = resolvedTabSelection(
            currentTab: currentTab,
            hasCustomScenes: hasCustomScenes,
            hasAnimatedScenes: hasAnimatedScenes
        )

        VStack(spacing: 10) {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    switch selectedTab {
                    case .jumpingOff:
                        if let animationManager {
                            jumpingOffScenesGrid(animationManager)
                        }

                    case .musicReactive:
                        if let animationManager {
                            musicReactiveScenesGrid(animationManager)
                        }

                    case .animated:
                        if let animationManager {
                            animatedScenesGrid(animationManager)
                        }

                    case .customScenes:
                        customScenesGrid(animationManager)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .padding(.bottom, 8)
        .onAppear {
            presetManager?.refreshBundledPresets()
        }
    }

    @ViewBuilder
    private func animatedScenesGrid(_ animationManager: AnimationManager) -> some View {
        let animatedScenes = animatedScenes(in: animationManager)
        let staticScenePresets = filteredStaticPresets()
        let activeSelection = currentSceneSelection(
            currentScene: animationManager.currentScene,
            visibleAnimationScenes: animatedScenes,
            staticScenePresets: staticScenePresets
        )

        VStack(alignment: .leading, spacing: 10) {
            browserHeader(
                title: "Animated Scenes",
                systemImage: "sparkles.rectangle.stack",
                description: "Keyframed motion studies and full visual sequences.",
                current: currentSceneSelectionLabel(
                    selection: activeSelection,
                    visibleAnimationScenes: animatedScenes,
                    staticScenePresets: staticScenePresets
                ),
                accentColor: .purple
            )

            if animatedScenes.isEmpty {
                emptySectionLabel("No animated scenes yet")
            } else {
                LazyVGrid(columns: sceneColumns, spacing: 12) {
                    ForEach(Array(animatedScenes.enumerated()), id: \.offset) { _, scene in
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
    private func customScenesGrid(_ animationManager: AnimationManager?) -> some View {
        let presets = customScenePresets()
        let activeSelection = currentSceneSelection(
            currentScene: animationManager?.currentScene,
            visibleAnimationScenes: [],
            staticScenePresets: presets
        )

        VStack(alignment: .leading, spacing: 10) {
            browserHeader(
                title: "Custom Scenes",
                systemImage: "chevron.left.forwardslash.chevron.right",
                description: "Externally-supplied scenes with embedded custom distance estimators.",
                current: currentSceneSelectionLabel(
                    selection: activeSelection,
                    visibleAnimationScenes: [],
                    staticScenePresets: presets
                ),
                accentColor: .mint
            )

            if presets.isEmpty {
                emptySectionLabel("No custom scenes yet")
            } else {
                LazyVGrid(columns: sceneColumns, spacing: 12) {
                    ForEach(Array(presets.enumerated()), id: \.offset) { _, preset in
                        sceneCard(
                            title: preset.name,
                            subtitle: preset.embeddedFormula?.name ?? preset.fractalType.displayName,
                            detail: staticSceneDetail(for: preset),
                            systemImage: "chevron.left.forwardslash.chevron.right",
                            thumbnailData: preset.thumbnailData,
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
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.mint.opacity(0.08)))
    }

    @ViewBuilder
    private func jumpingOffScenesGrid(_ animationManager: AnimationManager) -> some View {
        let staticScenePresets = jumpingOffPresets()
        let activeSelection = currentSceneSelection(
            currentScene: animationManager.currentScene,
            visibleAnimationScenes: [],
            staticScenePresets: staticScenePresets
        )

        VStack(alignment: .leading, spacing: 10) {
            browserHeader(
                title: "Jumping Off",
                systemImage: "photo.on.rectangle.angled",
                description: "Static starting points for exploring a region of the fractal.",
                current: currentSceneSelectionLabel(
                    selection: activeSelection,
                    visibleAnimationScenes: [],
                    staticScenePresets: staticScenePresets
                ),
                accentColor: .teal
            )

            if staticScenePresets.isEmpty {
                emptySectionLabel("No jumping-off scenes saved")
            } else {
                LazyVGrid(columns: sceneColumns, spacing: 12) {
                    ForEach(Array(staticScenePresets.enumerated()), id: \.offset) { _, preset in
                        sceneCard(
                            title: preset.name,
                            subtitle: preset.fractalType.displayName,
                            detail: staticSceneDetail(for: preset),
                            systemImage: "photo",
                            thumbnailData: preset.thumbnailData,
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

    @ViewBuilder
    private func musicReactiveScenesGrid(_ animationManager: AnimationManager) -> some View {
        let staticScenePresets = musicReactivePresets()
        let activeSelection = currentSceneSelection(
            currentScene: animationManager.currentScene,
            visibleAnimationScenes: [],
            staticScenePresets: staticScenePresets
        )

        VStack(alignment: .leading, spacing: 10) {
            browserHeader(
                title: "Music Reactive",
                systemImage: "music.note",
                description: "Honed-in presets with reactive mappings ready to drive the scene from audio.",
                current: currentSceneSelectionLabel(
                    selection: activeSelection,
                    visibleAnimationScenes: [],
                    staticScenePresets: staticScenePresets
                ),
                accentColor: .indigo
            )

            if staticScenePresets.isEmpty {
                emptySectionLabel("No music-reactive presets saved")
            } else {
                LazyVGrid(columns: sceneColumns, spacing: 12) {
                    ForEach(Array(staticScenePresets.enumerated()), id: \.offset) { _, preset in
                        sceneCard(
                            title: preset.name,
                            subtitle: preset.fractalType.displayName,
                            detail: staticSceneDetail(for: preset),
                            systemImage: "music.note",
                            thumbnailData: preset.thumbnailData,
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
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.indigo.opacity(0.08)))
    }

    private func filteredStaticPresets() -> [FractalPreset] {
        (presetManager?.presets ?? []).filter { preset in
            // Skip transient utility entries if they ever leak into the shared preset list.
            preset.name != "__lastState__"
        }
    }

    private func isJumpingOffPreset(_ preset: FractalPreset) -> Bool {
        // Custom-formula presets belong exclusively in the Custom Scenes tab.
        guard preset.embeddedFormula == nil else { return false }

        let normalizedName = preset.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if Self.jumpingOffNameOverrides.contains(normalizedName) {
            return true
        }

        return preset.musicReactiveMappings?.isEmpty ?? true
    }

    private func jumpingOffPresets() -> [FractalPreset] {
        filteredStaticPresets().filter { isJumpingOffPreset($0) }
    }

    private func musicReactivePresets() -> [FractalPreset] {
        filteredStaticPresets().filter { preset in
            preset.embeddedFormula == nil && !isJumpingOffPreset(preset)
        }
    }

    private func customScenePresets() -> [FractalPreset] {
        filteredStaticPresets().filter { $0.embeddedFormula != nil }
    }

    private func resolvedTabSelection(currentTab: FractalBrowseTab, hasCustomScenes: Bool, hasAnimatedScenes: Bool) -> FractalBrowseTab {
        switch currentTab {
        case .customScenes where !hasCustomScenes:
            return .jumpingOff
        case .animated where !hasAnimatedScenes:
            return hasCustomScenes ? .customScenes : .jumpingOff
        default:
            return currentTab
        }
    }

    private func animatedScenes(in animationManager: AnimationManager) -> [AnimationScene] {
        animationManager.scenes.filter { $0.keyframes.count >= 2 }
    }
    private func emptySectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }
    private func currentSceneSelection(
        currentScene: AnimationScene?,
        visibleAnimationScenes: [AnimationScene],
        staticScenePresets: [FractalPreset]
    ) -> FractalSceneSelection {
        if let sceneID = currentScene?.id,
           visibleAnimationScenes.contains(where: { $0.id == sceneID }) {
            return .animation(sceneID)
        }

        guard let staticID = selectedStaticSceneID,
              staticScenePresets.contains(where: { $0.id == staticID }) else {
            return .none
        }
        return .staticPreset(staticID)
    }

    private func currentSceneSelectionLabel(
        selection: FractalSceneSelection,
        visibleAnimationScenes: [AnimationScene],
        staticScenePresets: [FractalPreset]
    ) -> String {
        switch selection {
        case .none:
            return "Choose a scene"
        case .animation(let sceneID):
            return visibleAnimationScenes.first(where: { $0.id == sceneID })?.name
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

    private func selectStaticScenePreset(_ preset: FractalPreset, using animationManager: AnimationManager?) {
        selectedStaticSceneID = preset.id
        animationManager?.clearCurrentSceneSelection()
        onLoadStaticScene?(preset)
    }

    private func staticSceneDetail(for preset: FractalPreset) -> String {
        if preset.embeddedFormula != nil {
            return "Custom embedded formula"
        }
        if preset.musicReactiveMappings?.isEmpty == false {
            return "Music-reactive preset"
        }
        return "Static starting scene"
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

    private func sceneCard(title: String, subtitle: String, detail: String, systemImage: String, thumbnailData: Data? = nil, showsFlashingWarning: Bool = false, isSelected: Bool, onEdit: (() -> Void)? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    sceneCardIcon(systemImage: systemImage, thumbnailData: thumbnailData)

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

    @ViewBuilder
    private func sceneCardIcon(systemImage: String, thumbnailData: Data?) -> some View {
        if let thumbnailData,
           let image = FractalPreset(id: UUID(), name: "Preview", thumbnailData: thumbnailData).thumbnailImage {
            #if os(visionOS) || os(iOS)
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1))
            #elseif os(macOS)
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1))
            #else
            Image(systemName: systemImage)
                .font(.subheadline)
                .frame(width: 18)
            #endif
        } else {
            Image(systemName: systemImage)
                .font(.subheadline)
                .frame(width: 18)
        }
    }
}

// MARK: - Grid Cell

struct FractalGridCell: View {
    let type: FractalModelType
    let isSelected: Bool
    let action: () -> Void

    private var formulaAuthor: String? {
        FormulaCatalog.shared.descriptor(for: type)?.author
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: type.icon)
                        .font(.caption)
                        .frame(width: 14)
                        .foregroundStyle(isSelected ? Color.blue : .secondary)
                    Text(type.displayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                }
                Text(type.category)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if let author = formulaAuthor {
                    Text(author)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.blue.opacity(0.18) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.blue.opacity(0.5) : Color.secondary.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(type.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Formula Grid

/// Reusable formula picker grid. Used both inside the Browse tab's Formulas
/// section and inside the Shape tab's Formula sub-tab.
struct FractalFormulaGrid: View {
    var cache: UISettingsCache
    let gestureController: GestureController?

    private let columns = Array(repeating: GridItem(.flexible(minimum: 120), spacing: 8), count: 3)
    private let orderedTypes: [FractalModelType] = FractalFormulaOrder.orderedTypes

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
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
}
