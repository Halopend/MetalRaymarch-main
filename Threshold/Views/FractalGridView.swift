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
    case mixed = "Mixed"
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

    /// Distinct custom (`.threshfx`-embedded) base formulas found across every
    /// known scene preset, deduplicated by source hash. Space-warp-kind embedded
    /// payloads modify an existing formula rather than replacing it, so they're
    /// excluded here — they belong with Transformations, not the Formula picker.
    static func customFormulas(in presets: [FractalPreset]) -> [EmbeddedFormula] {
        var seenHashes = Set<String>()
        var result: [EmbeddedFormula] = []
        for preset in presets {
            guard let formula = preset.embeddedFormula, formula.effectKind == .fractal else { continue }
            guard seenHashes.insert(formula.shortHash).inserted else { continue }
            result.append(formula)
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private enum FractalSceneSelection: Equatable {
    case none
    case animation(UUID)
    case staticPreset(UUID)
}

struct FractalGridView: View {
    let animationManager: AnimationManager?
    let presetManager: PresetManager?
    var onCreateAnimation: (() -> Void)? = nil
    var onEditScene: ((AnimationScene) -> Void)? = nil
    var onLoadAnimationScene: ((AnimationScene) -> Void)? = nil
    var onLoadStaticScene: ((FractalPreset) -> Void)? = nil
    var tabSelection: Binding<FractalBrowseTab>? = nil
    @AppStorage("FractalGridView.innerTab") private var storedTabSelection: FractalBrowseTab = .jumpingOff
    @SceneStorage("FractalGridView.selectedStaticSceneID") private var selectedStaticSceneIDRaw: String?
    @State private var selectedStaticSceneForEdit: FractalPreset?
    private let sceneColumns = [GridItem(.adaptive(minimum: 170, maximum: 280), spacing: 12)]

    init(
        animationManager: AnimationManager?,
        presetManager: PresetManager?,
        tabSelection: Binding<FractalBrowseTab>? = nil,
        onCreateAnimation: (() -> Void)? = nil,
        onEditScene: ((AnimationScene) -> Void)? = nil,
        onLoadAnimationScene: ((AnimationScene) -> Void)? = nil,
        onLoadStaticScene: ((FractalPreset) -> Void)? = nil
    ) {
        self.animationManager = animationManager
        self.presetManager = presetManager
        self.tabSelection = tabSelection
        self.onCreateAnimation = onCreateAnimation
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
        let selectedTab = effectiveTabSelection.wrappedValue

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
                        animatedScenesGrid(animationManager)

                    case .mixed:
                        if let animationManager {
                            mixedScenesGrid(animationManager)
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
        .sheet(item: $selectedStaticSceneForEdit) { preset in
            if let presetManager {
                StaticSceneSettingsView(preset: preset, presetManager: presetManager)
            }
        }
    }

    @ViewBuilder
    private func animatedScenesGrid(_ animationManager: AnimationManager?) -> some View {
        // Explicit self: the local binding shadows the method inside its own
        // initializer on release-toolchain Swift (CI) even though the beta
        // toolchain resolves it — "cannot call value of non-function type".
        let animatedScenes = animationManager.map { self.animatedScenes(in: $0) } ?? []
        let staticScenePresets = filteredStaticPresets()
        let activeSelection = currentSceneSelection(
            currentScene: animationManager?.currentScene,
            visibleAnimationScenes: animatedScenes,
            staticScenePresets: staticScenePresets
        )

        VStack(alignment: .leading, spacing: 10) {
            browserHeader(
                title: "Animated Scenes",
                systemImage: AppIcons.sparklesRectangleStack,
                description: "Keyframed motion studies and full visual sequences.",
                current: currentSceneSelectionLabel(
                    selection: activeSelection,
                    visibleAnimationScenes: animatedScenes,
                    staticScenePresets: staticScenePresets
                ),
                accentColor: .purple
            )

            if animatedScenes.isEmpty {
                ContentUnavailableView {
                    Label("No Animated Scenes", systemImage: AppIcons.sparklesRectangleStack)
                } description: {
                    Text("Create an animation with at least two keyframes to make it available here.")
                } actions: {
                    if let onCreateAnimation {
                        Button(action: onCreateAnimation) {
                            Label("Create Animation", systemImage: AppIcons.plusCircleFill)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                LazyVGrid(columns: sceneColumns, spacing: 12) {
                    ForEach(Array(animatedScenes.enumerated()), id: \.offset) { _, scene in
                        sceneCard(
                            title: scene.name,
                            subtitle: scene.fractalType?.displayName ?? "Any fractal",
                            detail: scene.attachedSong?.title ?? "Visual-only scene",
                            systemImage: scene.attachedSong == nil ? AppIcons.sparklesRectangleStack : AppIcons.musicNote,
                            showsFlashingWarning: scene.name.localizedCaseInsensitiveContains("ambient blur"),
                            isSelected: activeSelection == .animation(scene.id),
                            onEdit: onEditScene.map { editScene in
                                { editScene(scene) }
                            }
                        ) {
                            if let animationManager {
                                selectScene(scene, using: animationManager)
                            }
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
                systemImage: AppIcons.chevronLeftForwardslashChevronRight,
                description: "Externally-supplied scenes with embedded custom distance estimators.",
                current: currentSceneSelectionLabel(
                    selection: activeSelection,
                    visibleAnimationScenes: [],
                    staticScenePresets: presets
                ),
                accentColor: .mint
            )

            if presets.isEmpty {
                ContentUnavailableView {
                    Label("No Custom Scenes", systemImage: AppIcons.chevronLeftForwardslashChevronRight)
                } description: {
                    Text("Scenes with an embedded custom .threshfx formula appear here after they are opened or saved in Threshold.")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                LazyVGrid(columns: sceneColumns, spacing: 12) {
                    ForEach(Array(presets.enumerated()), id: \.offset) { _, preset in
                        sceneCard(
                            title: preset.name,
                            subtitle: preset.embeddedFormula?.name ?? preset.fractalType.displayName,
                            detail: staticSceneDetail(for: preset),
                            systemImage: AppIcons.chevronLeftForwardslashChevronRight,
                            thumbnailData: preset.thumbnailData,
                            isSelected: activeSelection == .staticPreset(preset.id),
                            onEdit: staticSceneEditAction(for: preset)
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
                systemImage: AppIcons.photoOnRectangleAngled,
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
                            systemImage: AppIcons.photo,
                            thumbnailData: preset.thumbnailData,
                            isSelected: activeSelection == .staticPreset(preset.id),
                            onEdit: staticSceneEditAction(for: preset)
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
    private func mixedScenesGrid(_ animationManager: AnimationManager) -> some View {
        let staticScenePresets = mixedScenePresets()
        let activeSelection = currentSceneSelection(
            currentScene: animationManager.currentScene,
            visibleAnimationScenes: [],
            staticScenePresets: staticScenePresets
        )

        VStack(alignment: .leading, spacing: 10) {
            browserHeader(
                title: "Mixed",
                systemImage: "circle.dashed.inset.filled",
                description: "Scenes authored for Mixed immersion — the fractal floats in your room over passthrough.",
                current: currentSceneSelectionLabel(
                    selection: activeSelection,
                    visibleAnimationScenes: [],
                    staticScenePresets: staticScenePresets
                ),
                accentColor: .mint
            )

            if staticScenePresets.isEmpty {
                emptySectionLabel("No mixed-mode scenes yet — long-press any saved scene and enable Open in Mixed Immersion")
            } else {
                LazyVGrid(columns: sceneColumns, spacing: 12) {
                    ForEach(Array(staticScenePresets.enumerated()), id: \.offset) { _, preset in
                        sceneCard(
                            title: preset.name,
                            subtitle: preset.fractalType.displayName,
                            detail: staticSceneDetail(for: preset),
                            systemImage: AppIcons.photo,
                            thumbnailData: preset.thumbnailData,
                            isSelected: activeSelection == .staticPreset(preset.id),
                            onEdit: staticSceneEditAction(for: preset)
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
                systemImage: AppIcons.musicNote,
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
                            systemImage: AppIcons.musicNote,
                            thumbnailData: preset.thumbnailData,
                            isSelected: activeSelection == .staticPreset(preset.id),
                            onEdit: staticSceneEditAction(for: preset)
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
        (presetManager?.sceneCatalogPresets ?? []).filter { preset in
            // Skip transient utility entries if they ever leak into the shared preset list.
            preset.name != "__lastState__"
        }
    }

    private func jumpingOffPresets() -> [FractalPreset] {
        filteredStaticPresets().filter { $0.isJumpingOffPreset && $0.mixedModeScene != true }
    }

    private func musicReactivePresets() -> [FractalPreset] {
        filteredStaticPresets().filter { preset in
            !preset.isCustomScenePreset && !preset.isJumpingOffPreset && preset.mixedModeScene != true
        }
    }

    private func mixedScenePresets() -> [FractalPreset] {
        filteredStaticPresets().filter { $0.mixedModeScene == true }
    }

    private func customScenePresets() -> [FractalPreset] {
        filteredStaticPresets().filter(\.isCustomScenePreset)
    }

    private func staticSceneEditAction(for preset: FractalPreset) -> (() -> Void)? {
        guard presetManager != nil else { return nil }
        return {
            selectedStaticSceneForEdit = preset
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
#if os(visionOS)
        if AppModel.shared?.immersiveSpaceState != .open {
            NotificationCenter.default.post(
                name: AppModel.requestOpenImmersiveSpaceNotification,
                object: nil,
                userInfo: ["sceneID": scene.id.uuidString]
            )
        }
#endif

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
        if preset.mixedModeScene == true {
            return "Mixed immersion scene"
        }
        if preset.isCustomScenePreset {
            return "Custom embedded formula"
        }
        if preset.hasMusicReactiveMappings {
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

    @ViewBuilder
    private func sceneCard(title: String, subtitle: String, detail: String, systemImage: String, thumbnailData: Data? = nil, showsFlashingWarning: Bool = false, isSelected: Bool, onEdit: (() -> Void)? = nil, action: @escaping () -> Void) -> some View {
        let card = Button(action: action) {
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
                    Label("Selected", systemImage: AppIcons.checkmarkCircleFill)
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])

        if let onEdit {
            card
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.6, maximumDistance: 24)
                        .onEnded { _ in onEdit() }
                )
                .accessibilityAction(named: Text("Edit Scene")) {
                    onEdit()
                }
        } else {
            card
        }
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

// MARK: - Static Scene Settings

/// Metadata editor reached by long-pressing any static scene card.
private struct StaticSceneSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State var preset: FractalPreset
    let presetManager: PresetManager
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Presentation") {
                    Toggle("Open in Mixed Immersion", isOn: Binding(
                        get: { preset.mixedModeScene == true },
                        set: { enabled in
                            preset.mixedModeScene = enabled
                            preset.sceneState?.presentation.immersionStyle = nil
                        }
                    ))

                    Text("When off, loading this scene preserves your selected Immersive, Window, or Mixed mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(preset.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
        .alert(
            "Couldn’t Save Scene",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "The scene could not be saved.")
        }
    }

    private func save() {
        switch presetManager.updatePreset(preset) {
        case .saved, .queuedForStorage:
            dismiss()
        case .failed(let detail):
            saveError = detail
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
                        Image(systemName: AppIcons.checkmarkCircleFill)
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
/// section and inside the Shape tab's Formula sub-tab. Built-in formulas are
/// always shown; a "Custom" section appears below whenever any loaded scene
/// (bundled or user-saved) carries an embedded distance-estimator formula.
struct FractalFormulaGrid: View {
    var cache: ControlStateStore
    let presetManager: PresetManager?

    @State private var exportShareItem: ExportShareItem?

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 220), spacing: 8)]
    private let orderedTypes: [FractalModelType] = FractalFormulaOrder.orderedTypes

    private var customFormulas: [EmbeddedFormula] {
        FractalFormulaOrder.customFormulas(in: presetManager?.presets ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                formulaSectionLabel("Built-in")
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(orderedTypes, id: \.self) { type in
                        FractalGridCell(
                            type: type,
                            isSelected: type == cache.fractalType && cache.activeCustomFormulaHash == nil
                        ) {
                            cache.fractalType = type
                            cache.pushFractalType(type)
                        }
                    }
                }
            }

            if !customFormulas.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    formulaSectionLabel("Custom")
                    Text("Formulas embedded in your scenes. Long-press a tile to reveal its .threshfx file.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(customFormulas, id: \.shortHash) { formula in
                            FractalCustomFormulaCell(
                                formula: formula,
                                isSelected: cache.fractalType == .custom && cache.activeCustomFormulaHash == formula.shortHash,
                                action: {
                                    cache.pushCustomFormula(formula)
                                },
                                onReveal: {
                                    revealFormulaFile(formula)
                                }
                            )
                        }
                    }
                }
            }
        }
        .sheet(item: $exportShareItem) { item in
            ShareSheet(activityItems: [item.url])
        }
    }

    private func formulaSectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
    }

    /// Writes the formula out to a standalone `.threshfx` file and hands the
    /// user straight to it: reveals it in Finder on Mac, or offers the
    /// share/Save-to-Files sheet on iOS/visionOS (there's no Finder-equivalent
    /// "reveal" API on those platforms).
    private func revealFormulaFile(_ formula: EmbeddedFormula) {
        let container = EmbeddedFormulaContainer(formula: formula)
        exportOffMain({ container.exportToFile() }) { url in
            if !PlatformFilePresentationAdapter.revealIfSupported(url) {
                exportShareItem = ExportShareItem(url: url)
            }
        }
    }
}

/// Grid cell for a custom (`.threshfx`-embedded) formula — mirrors
/// `FractalGridCell` but keys off the formula's own name/category/author
/// rather than a `FractalModelType` descriptor.
struct FractalCustomFormulaCell: View {
    let formula: EmbeddedFormula
    let isSelected: Bool
    let action: () -> Void
    var onReveal: (() -> Void)? = nil

    @ViewBuilder
    var body: some View {
        let cell = Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: AppIcons.chevronLeftForwardslashChevronRight)
                        .font(.caption)
                        .frame(width: 14)
                        .foregroundStyle(isSelected ? Color.blue : .secondary)
                    Text(formula.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: AppIcons.checkmarkCircleFill)
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                }
                Text(formula.category ?? "Custom")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if let author = formula.author {
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
        .accessibilityLabel(formula.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])

        if let onReveal {
            cell
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.6, maximumDistance: 24)
                        .onEnded { _ in onReveal() }
                )
                .accessibilityAction(named: Text("Reveal Formula File")) {
                    onReveal()
                }
        } else {
            cell
        }
    }
}
