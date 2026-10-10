//
//  FractalGridView.swift
//  Threshold
//
//  Browse surface for scene discovery and recall.
//

import SwiftUI

enum FractalBrowseTab: String, CaseIterable, Sendable {
    case jumpingOff = "Jumping Off"
    case musicReactive = "Music Reactive"
    case animated = "Animated"
    case mixed = "Mixed"
    case customScenes = "Custom Scenes"

    var title: String { rawValue }

    var icon: String {
        switch self {
        case .jumpingOff: return "photo.on.rectangle.angled"
        case .musicReactive: return "waveform"
        case .animated: return "film.stack"
        case .mixed: return "circle.dashed.inset.filled"
        case .customScenes: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// Whether this view browses the scene store (rather than animations), and
    /// therefore offers the scene folder categories in the sidebar.
    var browsesScenes: Bool { self != .animated }
}

/// Category-ordered list of selectable formulas, used by both the Browse and
/// Shape tabs.
enum FractalFormulaOrder {
    static let orderedTypes: [FractalModelType] = makeOrderedTypes()

    /// Formula picker order: the catalog's own category declaration order, each
    /// category sorted by formula name. There is deliberately no hardcoded
    /// preferred category list — the catalog is the taxonomy
    /// (see CONTENT_MODEL_PROPOSAL.md §2.10).
    private static func makeOrderedTypes() -> [FractalModelType] {
        let selectable = FractalModelType.selectableCases
        var seen: [String: [FractalModelType]] = [:]
        var order: [String] = []
        for type in selectable {
            let category = type.category
            if seen[category] == nil { order.append(category) }
            seen[category, default: []].append(type)
        }
        return order.flatMap { category in
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
    #if os(macOS)
    @Environment(AppModel.self) private var appModel
    @State private var isHoldingSceneEditorAdjustment = false
    #endif
    let animationManager: AnimationManager?
    let presetManager: PresetManager?
    /// Filesystem-derived folder/category snapshot, so a folder with no scenes
    /// yet still appears as a category. Optional: hosts without one fall back
    /// to folder paths derived from loaded scenes.
    let libraryStore: LibraryStore?
    let usesListLayout: Bool
    var captureCurrentScene: ((FractalPreset) -> FractalPreset)? = nil
    var onCreateAnimation: (() -> Void)? = nil
    var onEditScene: ((AnimationScene) -> Void)? = nil
    var onLoadAnimationScene: ((AnimationScene) -> Void)? = nil
    var onLoadStaticScene: ((FractalPreset) -> Void)? = nil
    /// Explore is selected by a folder scope. Content traits stay filters, so
    /// they never create another competing level in the navigation.
    var librarySelection: Binding<LibrarySidebarSelection>? = nil
    @SceneStorage("FractalGridView.libraryKind") private var storedLibraryKindRaw = LibraryItemKind.scene.rawValue
    /// Held here so toggling Settings ▸ Display re-renders every browse tab
    /// live: `sceneCatalogPresets` re-filters with the current opt-in.
    @AppStorage(MixedRealitySceneCatalogSettings.defaultsKey)
    private var includesMixedRealityScenes = false
    @SceneStorage("FractalGridView.selectedStaticSceneID") private var selectedStaticSceneIDRaw: String?
    @SceneStorage("FractalGridView.selectedTag") private var selectedTag: String?
    /// Folder-derived category filter (e.g. "Caverns" or "Caverns/Ice Caves"),
    /// "/"-joined for `@SceneStorage`. nil means every category. Any folder
    /// created under Scenes/ (or the legacy Music Presets/) becomes a category
    /// here — see CONTENT_MODEL_PROPOSAL.md §2.4.
    @SceneStorage("FractalGridView.selectedCategory") private var selectedCategoryPathRaw: String?
    @SceneStorage("FractalGridView.embeddedFormulaOnly") private var embeddedFormulaOnly = false
    @State private var selectedStaticSceneForEdit: FractalPreset?
    private let sceneColumns = [GridItem(.adaptive(minimum: 170, maximum: 280), spacing: 12)]

    init(
        animationManager: AnimationManager?,
        presetManager: PresetManager?,
        libraryStore: LibraryStore? = nil,
        librarySelection: Binding<LibrarySidebarSelection>? = nil,
        usesListLayout: Bool = false,
        captureCurrentScene: ((FractalPreset) -> FractalPreset)? = nil,
        onCreateAnimation: (() -> Void)? = nil,
        onEditScene: ((AnimationScene) -> Void)? = nil,
        onLoadAnimationScene: ((AnimationScene) -> Void)? = nil,
        onLoadStaticScene: ((FractalPreset) -> Void)? = nil
    ) {
        self.animationManager = animationManager
        self.presetManager = presetManager
        self.libraryStore = libraryStore
        self.captureCurrentScene = captureCurrentScene
        self.usesListLayout = usesListLayout
        self.librarySelection = librarySelection
        self.onCreateAnimation = onCreateAnimation
        self.onEditScene = onEditScene
        self.onLoadAnimationScene = onLoadAnimationScene
        self.onLoadStaticScene = onLoadStaticScene
    }

    private var effectiveLibrarySelection: Binding<LibrarySidebarSelection> {
        Binding(
            get: {
                // Flat `if let` returns instead of chained `??`: the nested
                // coalescing here triggered a swift-frontend Mem2Reg assertion
                // ("terminator instruction must not have critical successors")
                // in Release builds (Swift 6.4, SILBuilder.cpp:843). Keep the
                // control flow simple until the compiler bug is fixed.
                if let selection = librarySelection?.wrappedValue {
                    return selection
                }
                if let kind = LibraryItemKind(rawValue: storedLibraryKindRaw) {
                    return .all(kind)
                }
                return .all(.scene)
            },
            set: { selection in
                switch selection {
                case .all(let kind):
                    storedLibraryKindRaw = kind.rawValue
                    selectedCategoryPathRaw = nil
                case .category(let kind, let path):
                    storedLibraryKindRaw = kind.rawValue
                    selectedCategoryPathRaw = path.joined(separator: "/")
                }
                librarySelection?.wrappedValue = selection
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
        VStack(spacing: 10) {
            tagFilterBar

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: usesListLayout ? 10 : 18) {
                    switch currentKind {
                    case .scene:
                        libraryScenesGrid(animationManager)
                    case .animation:
                        animatedScenesGrid(animationManager)
                    case .effect:
                        EmptyView()
                    }
                }
                .padding(.horizontal, usesListLayout ? 8 : 12)
                .padding(.vertical, usesListLayout ? 4 : 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.bottom, 8)
        .onAppear {
            presetManager?.refreshBundledPresets()
            // Refresh the folder tree so a category added in Finder/Files while
            // the app was elsewhere shows up on the next visit.
            libraryStore?.reload()
        }
        .onChange(of: availableTags) { _, tags in
            if let selectedTag, !tags.contains(where: { $0.caseInsensitiveCompare(selectedTag) == .orderedSame }) {
                self.selectedTag = nil
            }
        }
        .onChange(of: sidebarSection.rows.map(\.id)) { _, rowIDs in
            // Drop a selection whose folder disappeared, or that belongs to the
            // kind we just switched away from.
            guard let selected = selectedCategoryPath else { return }
            let stillExists = rowIDs.contains { row in
                guard case .category(let kind, let path) = row, kind == currentKind else { return false }
                return path.starts(with: selected) || selected.starts(with: path)
            }
            if !stillExists { selectedCategoryPath = nil }
        }
        .onDisappear { releaseSceneEditorAdjustment() }
        .sheet(item: $selectedStaticSceneForEdit, onDismiss: releaseSceneEditorAdjustment) { preset in
            if let presetManager {
                StaticSceneSettingsView(preset: preset, presetManager: presetManager, captureCurrentScene: captureCurrentScene)
            }
        }
    }

    @ViewBuilder
    private func libraryScenesGrid(_ animationManager: AnimationManager?) -> some View {
        let presets = filteredStaticPresets()
        let activeSelection = currentSceneSelection(
            currentScene: animationManager?.currentScene,
            visibleAnimationScenes: [],
            staticScenePresets: presets
        )

        VStack(alignment: .leading, spacing: 10) {
            browserHeader(
                title: libraryScopeLabel,
                systemImage: selectedCategoryPath == nil ? "square.grid.2x2" : "folder",
                description: embeddedFormulaOnly
                    ? "Scenes in this folder with an embedded formula."
                    : "Scenes stored in this folder and its subfolders.",
                current: currentSceneSelectionLabel(
                    selection: activeSelection,
                    visibleAnimationScenes: [],
                    staticScenePresets: presets
                ),
                accentColor: .teal
            )

            if presets.isEmpty {
                ContentUnavailableView {
                    Label("No Scenes Here", systemImage: "folder")
                } description: {
                    Text("Save or import scenes into this folder to see them here.")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                sceneCollectionLayout {
                    ForEach(Array(presets.enumerated()), id: \.offset) { _, preset in
                        sceneCard(
                            title: preset.name,
                            subtitle: preset.embeddedFormula?.name ?? preset.fractalType.displayName,
                            detail: staticSceneDetail(for: preset),
                            systemImage: "photo",
                            thumbnailData: preset.thumbnailData,
                            tags: preset.tags,
                            hasEmbeddedEffect: preset.embeddedFormula != nil,
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
                title: libraryScopeLabel,
                systemImage: AppIcons.sparklesRectangleStack,
                description: "Keyframed motion studies in this folder and its subfolders.",
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
                sceneCollectionLayout {
                    ForEach(Array(animatedScenes.enumerated()), id: \.offset) { _, scene in
                        sceneCard(
                            title: scene.name,
                            subtitle: scene.fractalType?.displayName ?? "Any fractal",
                            detail: scene.attachedSong?.title ?? "Visual-only scene",
                            systemImage: scene.attachedSong == nil ? AppIcons.sparklesRectangleStack : AppIcons.musicNote,
                            tags: scene.tags,
                            showsFlashingWarning: scene.name.localizedCaseInsensitiveContains("ambient blur"),
                            hasEmbeddedEffect: scene.embeddedFormula != nil,
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
                sceneCollectionLayout {
                    ForEach(Array(staticScenePresets.enumerated()), id: \.offset) { _, preset in
                        sceneCard(
                            title: preset.name,
                            subtitle: preset.fractalType.displayName,
                            detail: staticSceneDetail(for: preset),
                            systemImage: AppIcons.photo,
                            thumbnailData: preset.thumbnailData,
                            tags: preset.tags,
                            hasEmbeddedEffect: preset.embeddedFormula != nil,
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
                if includesMixedRealityScenes || PlatformProfile.current.platform == .visionOS {
                    emptySectionLabel("No mixed-mode scenes yet — long-press any saved scene and enable Open in Mixed Immersion")
                } else {
                    // Reachable only through a stored tab selection on a host
                    // where Mixed scenes are still hidden by the Settings gate.
                    emptySectionLabel("Mixed scenes are authored for Vision Pro. Enable \"Vision Pro Mixed Scenes\" in Settings ▸ Display to browse them here.")
                }
            } else {
                sceneCollectionLayout {
                    ForEach(Array(staticScenePresets.enumerated()), id: \.offset) { _, preset in
                        sceneCard(
                            title: preset.name,
                            subtitle: preset.fractalType.displayName,
                            detail: staticSceneDetail(for: preset),
                            systemImage: AppIcons.photo,
                            thumbnailData: preset.thumbnailData,
                            tags: preset.tags,
                            hasEmbeddedEffect: preset.embeddedFormula != nil,
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
                sceneCollectionLayout {
                    ForEach(Array(staticScenePresets.enumerated()), id: \.offset) { _, preset in
                        sceneCard(
                            title: preset.name,
                            subtitle: preset.fractalType.displayName,
                            detail: staticSceneDetail(for: preset),
                            systemImage: AppIcons.musicNote,
                            thumbnailData: preset.thumbnailData,
                            tags: preset.tags,
                            hasEmbeddedEffect: preset.embeddedFormula != nil,
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

    private func allStaticPresets() -> [FractalPreset] {
        (presetManager?.sceneCatalogPresets ?? []).filter { preset in
            // Skip transient utility entries if they ever leak into the shared preset list.
            preset.name != "__lastState__"
        }
    }

    private func filteredStaticPresets() -> [FractalPreset] {
        allStaticPresets().filter {
            matchesSelectedTag($0.tags)
                && matchesSelectedCategory($0)
                && (!embeddedFormulaOnly || $0.embeddedFormula != nil)
        }
    }

    private func jumpingOffPresets() -> [FractalPreset] {
        filteredStaticPresets().filter { $0.isJumpingOffPreset && $0.mixedModeScene != true }
    }

    private func musicReactivePresets() -> [FractalPreset] {
        // Music-reactivity is a content trait, so an embedded-DE scene with
        // mappings belongs here too — smart views do not partition.
        filteredStaticPresets().filter { preset in
            !preset.isJumpingOffPreset && preset.mixedModeScene != true
        }
    }

    private func mixedScenePresets() -> [FractalPreset] {
        filteredStaticPresets().filter { $0.mixedModeScene == true }
    }

    @ViewBuilder
    private func sceneCollectionLayout<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        if usesListLayout {
            LazyVStack(alignment: .leading, spacing: 6) {
                content()
            }
        } else {
            LazyVGrid(columns: sceneColumns, spacing: 12) {
                content()
            }
        }
    }

    private func staticSceneEditAction(for preset: FractalPreset) -> (() -> Void)? {
        guard presetManager != nil else { return nil }
        return {
            #if os(macOS)
            if !isHoldingSceneEditorAdjustment {
                isHoldingSceneEditorAdjustment = true
                appModel.beginMenuAdjustment()
            }
            #endif
            selectedStaticSceneForEdit = preset
        }
    }

    private func releaseSceneEditorAdjustment() {
        #if os(macOS)
        guard isHoldingSceneEditorAdjustment else { return }
        isHoldingSceneEditorAdjustment = false
        appModel.endMenuAdjustment()
        #endif
    }

    private func animatedScenes(in animationManager: AnimationManager) -> [AnimationScene] {
        animationManager.scenes.filter {
            $0.keyframes.count >= 2
                && matchesSelectedTag($0.tags)
                && matchesSelectedCategory($0)
        }
    }

    private var availableTags: [String] {
        let staticTags = allStaticPresets().flatMap(\.tags)
        let animationTags = (animationManager?.scenes ?? []).flatMap(\.tags)
        return Array(Set(SceneTagging.normalized(staticTags + animationTags)))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func matchesSelectedTag(_ tags: [String]) -> Bool {
        guard let selectedTag else { return true }
        return SceneTagging.contains(tags, tag: selectedTag)
    }

    // MARK: - Folder categories (see CONTENT_MODEL_PROPOSAL.md §2.4)

    /// Selected folder category as path components. nil = every category.
    private var selectedCategoryPath: [String]? {
        get {
            if let librarySelection {
                if case .category(_, let path) = librarySelection.wrappedValue {
                    return path
                }
                return nil
            }
            guard let raw = selectedCategoryPathRaw, !raw.isEmpty else { return nil }
            return raw.components(separatedBy: "/")
        }
        nonmutating set {
            if let librarySelection {
                let kind = currentKind
                librarySelection.wrappedValue = newValue.map { .category(kind, path: $0) } ?? .all(kind)
            } else {
                selectedCategoryPathRaw = newValue?.joined(separator: "/")
            }
        }
    }

    /// The content kind follows Explore's selected folder scope.
    private var currentKind: LibraryItemKind {
        switch effectiveLibrarySelection.wrappedValue {
        case .all(let kind), .category(let kind, _): return kind
        }
    }

    /// Folder-derived rows for the current kind (All + every category).
    private var sidebarSection: LibrarySidebarSection {
        LibrarySidebarCatalog.section(
            kind: currentKind,
            index: libraryStore?.index ?? .empty
        )
    }

    /// The selected *library* scope — not the smart view, which is always one.
    private var sidebarSelection: LibrarySidebarSelection {
        effectiveLibrarySelection.wrappedValue
    }

    /// Whether there is anything to choose besides "All".
    private var hasCategories: Bool { sidebarSection.rows.count > 1 }

    private func selectLibraryScope(_ row: LibrarySidebarRow) {
        effectiveLibrarySelection.wrappedValue = row.selection
    }

    /// A preset matches when its folder is the selected category or any folder
    /// beneath it, so picking "Caverns" also shows "Caverns/Ice Caves".
    private func matchesSelectedCategory(_ preset: FractalPreset) -> Bool {
        guard currentKind == .scene, let selected = selectedCategoryPath else { return true }
        guard let path = presetManager?.categoryPathsByPresetID[preset.id] else { return false }
        return path.starts(with: selected)
    }

    /// The animation twin of `matchesSelectedCategory(_ preset:)`.
    private func matchesSelectedCategory(_ scene: AnimationScene) -> Bool {
        guard currentKind == .animation, let selected = selectedCategoryPath else { return true }
        guard let path = animationManager?.categoryPathsBySceneID[scene.id] else { return false }
        return path.starts(with: selected)
    }

    private var libraryScopeLabel: String {
        if let path = selectedCategoryPath, !path.isEmpty {
            return path.joined(separator: " / ")
        }
        return sidebarSection.rows.first?.title ?? "All \(currentKind.displayName)"
    }

    @ViewBuilder
    private var tagFilterBar: some View {
        if currentKind == .scene || currentKind == .animation || !availableTags.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if currentKind == .scene {
                    Button {
                        embeddedFormulaOnly.toggle()
                    } label: {
                        Label("Embedded Formula", systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(embeddedFormulaOnly ? Color.white : Color.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(embeddedFormulaOnly ? Color.accentColor : Color.secondary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }

                if currentKind == .scene || currentKind == .animation {
                    libraryScopeMenuButton
                }

                if !availableTags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Label("Tags", systemImage: "tag.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Button {
                                selectedTag = nil
                            } label: {
                                Text("All")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(selectedTag == nil ? Color.white : Color.secondary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule().fill(selectedTag == nil ? Color.accentColor : Color.secondary.opacity(0.12))
                                    )
                            }
                            .buttonStyle(.plain)

                            ForEach(availableTags, id: \.self) { tag in
                                Button {
                                    selectedTag = tag
                                } label: {
                                    SceneTagPill(
                                        tag: tag,
                                        isSelected: selectedTag?.caseInsensitiveCompare(tag) == .orderedSame
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Filter the selected folder")
        }
    }

    private var libraryScopeMenuButton: some View {
        Menu {
            let index = libraryStore?.index ?? .empty
            ForEach([LibraryItemKind.scene, .animation], id: \.rawValue) { kind in
                Section(kind.displayName) {
                    ForEach(LibrarySidebarCatalog.section(kind: kind, index: index).rows) { row in
                        Button {
                            selectLibraryScope(row)
                        } label: {
                            Text(String(repeating: "    ", count: row.depth) + row.title)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.caption.weight(.semibold))
                Text(libraryScopePickerLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.blue.opacity(0.14)))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel("Choose a library folder")
    }

    private var libraryScopePickerLabel: String {
        switch effectiveLibrarySelection.wrappedValue {
        case .all(let kind): return "All \(kind.displayName)"
        case .category(_, let path): return path.joined(separator: " / ")
        }
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
        if let appModel = AppModel.shared, appModel.immersiveSpaceState != .open {
            appModel.requestOpenImmersiveSpace()
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
            return "Embedded formula"
        }
        if preset.hasMusicReactiveMappings {
            return "Music-reactive preset"
        }
        return "Static starting scene"
    }

    private func browserHeader(title: String, systemImage: String, description: String, current: String, accentColor: Color) -> some View {
        // The title block is centred in the full width, so overlaying the
        // "Current:" pill on top of it only reads correctly while the column is
        // wide enough that the two never meet. In the iPad inspector they do —
        // the pill printed straight through the section title. The list layout
        // therefore stacks them instead of overlaying.
        let titleBlock = VStack(spacing: 4) {
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

        let currentPill = Text("Current: \(current)")
            .font(.caption2.weight(.medium))
            .foregroundStyle(accentColor)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(accentColor.opacity(0.12))
            )

        return Group {
            if usesListLayout {
                VStack(spacing: 6) {
                    titleBlock
                    currentPill
                }
            } else {
                ZStack(alignment: .topTrailing) {
                    titleBlock
                    currentPill
                }
            }
        }
    }

    @ViewBuilder
    private func sceneCard(title: String, subtitle: String, detail: String, systemImage: String, thumbnailData: Data? = nil, tags: [String] = [], showsFlashingWarning: Bool = false, hasEmbeddedEffect: Bool = false, isSelected: Bool, onEdit: (() -> Void)? = nil, action: @escaping () -> Void) -> some View {
        let card = Button(action: action) {
            Group {
                if usesListLayout {
                    HStack(alignment: .top, spacing: 10) {
                        sceneCardIcon(systemImage: systemImage, thumbnailData: thumbnailData)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                if hasEmbeddedEffect { EmbeddedEffectBadge() }
                                if showsFlashingWarning { FlashingLightIndicator() }
                            }
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            SceneTagRow(tags: tags)
                            if isSelected {
                                Label("Selected", systemImage: AppIcons.checkmarkCircleFill)
                                    .font(.caption.weight(.semibold)).foregroundStyle(.blue)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    sceneCardIcon(systemImage: systemImage, thumbnailData: thumbnailData)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            if hasEmbeddedEffect { EmbeddedEffectBadge() }
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

                SceneTagRow(tags: tags)

                Spacer(minLength: 0)

                if isSelected {
                    Label("Selected", systemImage: AppIcons.checkmarkCircleFill)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: usesListLayout ? 88 : 116, alignment: .leading)
            .padding(usesListLayout ? 8 : 12)
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
                .contextMenu {
                    Button("Edit Scene…", systemImage: "slider.horizontal.3", action: onEdit)
                }
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

/// Scene editor reached from a scene card’s context menu or long press.
private struct StaticSceneSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State var preset: FractalPreset
    let presetManager: PresetManager
    var captureCurrentScene: ((FractalPreset) -> FractalPreset)?
    @State private var parameterJSON = ""
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Scene") {
                    TextField("Name", text: $preset.name)
                    if let captureCurrentScene {
                        Button("Use Current Tweaks", systemImage: "arrow.down.doc") {
                            do {
                                try applyParameterDraft()
                                preset = captureCurrentScene(preset)
                                try refreshParameterDraft()
                            } catch {
                                saveError = error.localizedDescription
                            }
                        }
                        Text("Copies the current live parameters into this draft. Save overwrites this scene; Cancel discards the draft.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Parameters (JSON)") {
                    TextEditor(text: $parameterJSON)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 260)
                        .padding(6)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.secondary.opacity(0.3))
                        }
                        .autocorrectionDisabled()
                    Text("Edit sceneState for scene parameters. Name, tags, and presentation options below are saved separately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Presentation") {
                    ScreenOnlySceneToggle(visibility: $preset.platformVisibility)

                    Text("Screen-only scenes are best viewed on a flat display and are hidden from the Vision Pro scene library.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Show in Jumping Off", isOn: Binding(
                        get: { preset.jumpingOff == true },
                        set: { preset.jumpingOff = $0 ? true : nil }
                    ))
                    .help("List this scene as a static starting point, even when it has music mappings.")

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

                    // Mixed-immersion scenes composite over room passthrough
                    // on Vision Pro, so flat-display hosts keep them out of
                    // the catalog until the Settings → Display opt-in.
#if !os(visionOS)
                    if preset.mixedModeScene == true {
                        Text("Mixed scenes are authored for Vision Pro and stay hidden from this library unless \"Vision Pro Mixed Scenes\" is enabled in Settings ▸ Display.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
#endif
                }

                Section("Tags") {
                    SceneTagEditor(tags: $preset.tags)
                }
            }
            .formStyle(.grouped)
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
        #if os(macOS)
        .frame(width: 680, height: 720)
        #endif
        .onAppear {
            do { try refreshParameterDraft() }
            catch { saveError = error.localizedDescription }
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

    private func refreshParameterDraft() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var document = try JSONSerialization.jsonObject(with: encoder.encode(preset)) as! [String: Any]
        // Keep image data out of the editor and make typed state authoritative,
        // so legacy compatibility fields cannot undo edits to sceneState.
        document.removeValue(forKey: "thumbnailData")
        if preset.sceneState != nil {
            document["canonicalStateOnly"] = true
        }
        parameterJSON = String(decoding: try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }

    private func applyParameterDraft() throws {
        var edited = try JSONDecoder().decode(FractalPreset.self, from: Data(parameterJSON.utf8))
        guard edited.id == preset.id else {
            throw NSError(domain: "SceneEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: "The scene ID cannot be changed."])
        }
        edited.name = preset.name
        edited.tags = preset.tags
        edited.platformVisibility = preset.platformVisibility
        edited.jumpingOff = preset.jumpingOff
        edited.mixedModeScene = preset.mixedModeScene
        if edited.mixedModeScene == true {
            edited.sceneState?.presentation.immersionStyle = nil
        }
        edited.categoryPath = preset.categoryPath
        edited.createdAt = preset.createdAt
        edited.thumbnailData = preset.thumbnailData
        preset = edited
    }

    private func save() {
        do { try applyParameterDraft() }
        catch {
            saveError = error.localizedDescription
            return
        }
        guard !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            saveError = "Enter a scene name."
            return
        }
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
/// always shown; reusable custom effects come from the **library**
/// (`Formulas/*.threshfx`), grouped by `EffectKind`.
///
/// Formulas embedded in a scene are deliberately *not* listed as reusable —
/// they are private to that document. When the active effect is embedded, a
/// provenance row explains that and offers "Extract to Effects…"
/// (see CONTENT_MODEL_PROPOSAL.md §2.7).
struct FractalFormulaGrid: View {
    var cache: ControlStateStore
    let presetManager: PresetManager?
    let formulaLibrary: FormulaLibraryStore?
    var activeEmbeddedFormula: EmbeddedFormula? = nil

    @State private var exportShareItem: ExportShareItem?
    @State private var extractError: String?

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 220), spacing: 8)]
    private let orderedTypes: [FractalModelType] = FractalFormulaOrder.orderedTypes

    /// Reusable effects: library files only.
    private var libraryEntries: [EffectPickerEntry] {
        EffectPickerCatalog.libraryEntries(formulaLibrary?.entries ?? [])
    }

    private var sections: [EffectPickerSection] {
        EffectPickerCatalog.sections(libraryEntries)
    }

    private var libraryHashes: Set<String> {
        Set(libraryEntries.map(\.id))
    }

    /// The active effect came from a scene, not a library file.
    private var isActiveEmbeddedOnly: Bool {
        EffectPickerCatalog.isEmbeddedOnly(
            hash: cache.activeCustomFormulaHash,
            libraryHashes: libraryHashes
        ) && activeEmbeddedFormula != nil
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

            if isActiveEmbeddedOnly, let formula = activeEmbeddedFormula {
                VStack(alignment: .leading, spacing: 8) {
                    formulaSectionLabel("Embedded")
                    HStack(spacing: 8) {
                        Image(systemName: "link")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(formula.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text("Embedded — not shared. Extract it to reuse across scenes.")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        Button("Extract to Effects…") { extractEmbedded(formula) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(formulaLibrary == nil)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                }
            }

            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    formulaSectionLabel(section.title)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(section.entries) { entry in
                            FractalCustomFormulaCell(
                                formula: entry.formula,
                                isSelected: cache.fractalType == .custom
                                    && cache.activeCustomFormulaHash == entry.formula.shortHash,
                                action: {
                                    cache.pushCustomFormula(entry.formula)
                                },
                                onReveal: {
                                    revealFormulaFile(entry.formula)
                                }
                            )
                        }
                    }
                }
            }

            if sections.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    formulaSectionLabel("Effects")
                    Text("No library effects yet. Save a formula in Metal DE Studio, or extract an embedded one, to reuse it across scenes.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .sheet(item: $exportShareItem) { item in
            ShareSheet(activityItems: [item.url])
        }
        .alert("Could Not Extract Effect", isPresented: Binding(
            get: { extractError != nil },
            set: { if !$0 { extractError = nil } }
        )) {
            Button("OK", role: .cancel) { extractError = nil }
        } message: {
            Text(extractError ?? "")
        }
    }

    private func formulaSectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
    }

    /// Promote the active scene-embedded effect into a real library file, so it
    /// becomes reusable by every scene.
    private func extractEmbedded(_ formula: EmbeddedFormula) {
        guard let formulaLibrary else { return }
        do {
            _ = try formulaLibrary.save(formula)
        } catch {
            extractError = error.localizedDescription
        }
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
                Text(formula.category.map { "Library · \($0)" } ?? "Library")
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
