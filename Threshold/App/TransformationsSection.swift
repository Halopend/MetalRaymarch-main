//
//  TransformationsSection.swift
//  Threshold
//
//  Editor for the composable domain-transform STACK (`RenderSettings.spaceWarpStack`).
//  Open the direct-use catalog, then group a contiguous series into an iterated
//  loop, reorder them (order =
//  order of application), enable/disable,
//  and tune each instance's own parameters. Multiple of the SAME kind can be stacked. EVERY edit — structural
//  or slider —
//  is a live uniform write: the GPU renders the stack via a count-driven runtime
//  loop (`spaceWarpStackTransform` in Shaders.metal) repacked each frame by
//  `cSpaceWarpStack`, so nothing ever recompiles a shader. The GPU early-outs to
//  zero cost when the stack is empty. Catalog + model live in SpaceWarpStackModel.swift.
//

import SwiftUI
import Foundation
import simd

struct TransformationsSection: View {
    private enum EquationAccessibilityTarget: Hashable {
        case vocabulary(TransformationLessonID)
        case hint(TransformationLessonID)
        case answer(TransformationLessonID)
        case result(TransformationLessonID)
    }

    let renderSettings: RenderSettings
    /// Live UI store. `ControlStateStore` is `@Observable`, so reading its sphere-system
    /// flags in `body` auto-subscribes this view — the system cards below track the
    /// same state the Space tab / quick toggles drive (DisplayConfig, scene-persisted).
    let cache: ControlStateStore

    // Local redraw token for presentation-only changes such as enable switches and
    // discrete steppers. Stack structure has its own revision in ControlStateStore;
    // continuous slider writes deliberately invalidate neither one.
    @State private var refresh: Int = 0
    @State private var isCreatingGroup = false
    @State private var groupSelection: Set<UUID> = []
    @State private var expandedGroups: Set<UUID> = []
    @State private var expandedOperationIDs: Set<UUID> = []
    @State private var expandedTechnicalDetailIDs: Set<UUID> = []
    @SceneStorage("Transformations.educationEquationDraft.v1")
    private var legacyEquationDraft = ""
    @SceneStorage("Transformations.focusedEquationRawID.v1")
    private var legacyFocusedEquationRawID = -1
    @SceneStorage("Transformations.educationEquationDrafts.v2")
    private var equationDraftsRaw = ""
    @SceneStorage("Transformations.focusedEquationLessonID.v2")
    private var focusedEquationLessonIDRaw = ""
    @State private var mappedKind: SpaceWarpKind?
    @State private var pendingNextEquationID: TransformationLessonID?
    @State private var mappingResultMessage = ""
    @State private var equationError: String?
    @State private var isEquationCheckHistoryExpanded = false
    @State private var isEquationGuideExpanded = false
    @State private var expandedEducationLevelIDs: Set<Int> = []
    @State private var didInitializeEducationExpansion = false
    @State private var assistanceStages: [TransformationLessonID: TransformationAssistanceStage] = [:]
    @FocusState private var isEquationEditorFocused: Bool
    @AccessibilityFocusState private var equationAccessibilityTarget: EquationAccessibilityTarget?
    @AppStorage(TransformationExperienceMode.defaultsKey)
    private var experienceModeRaw = TransformationExperienceMode.justUse.rawValue
    @AppStorage(TransformationUnlockProgress.defaultsKey)
    private var mappedLessonIDsRaw = ""
    @AppStorage(TransformationUnlockProgress.legacyDefaultsKey)
    private var legacyMappedTransformationIDsRaw = ""
    @AppStorage(TransformationEquationCheckHistoryStore.defaultsKey)
    private var equationCheckHistoryRaw = ""

    private var ops: [SpaceWarpOpValue] {
        // Observe structure only. Slider samples mutate the ignored value mirror and
        // must not rebuild this entire education/editor hierarchy.
        _ = cache.spaceWarpStructureRevision
        return cache.spaceWarpStack
    }
    private var hasStackCapacity: Bool { ops.count < Int(kMaxSpaceWarpOps) }
    private var experienceMode: TransformationExperienceMode {
        // The Transformations screen is direct-edit only. Keep the persisted
        // lesson state below for compatibility with existing scenes/settings.
        .justUse
    }
    private var mappedLessonIDs: Set<TransformationLessonID> {
        TransformationUnlockProgress.decode(
            mappedLessonIDsRaw,
            legacyEncoded: legacyMappedTransformationIDsRaw
        )
    }
    private var mappedTransformationIDs: Set<Int32> {
        TransformationUnlockProgress.runtimeKindIDs(from: mappedLessonIDs)
    }
    private var mappedLessons: [TransformationEquationLesson] {
        TransformationEquationCatalog.lessons.filter {
            mappedLessonIDs.contains($0.id)
        }
    }
    private var addableLessons: [TransformationEquationLesson] {
        TransformationAccessPolicy.addMenuLessons(
            mode: experienceMode,
            mappedIDs: mappedTransformationIDs
        )
    }
    private var educationGuideLessons: [TransformationEquationLesson] {
        TransformationEducationPath.guideLessons(mappedIDs: mappedLessonIDs)
    }
    private var focusedEquationID: TransformationLessonID? {
        guard !focusedEquationLessonIDRaw.isEmpty else { return nil }
        return TransformationLessonID(rawValue: focusedEquationLessonIDRaw)
    }
    private var focusedEquationLesson: TransformationEquationLesson? {
        if let focusedEquationID,
           let focused = educationGuideLessons.first(where: { $0.id == focusedEquationID }) {
            return focused
        }
        return TransformationEducationPath.preferredLesson(
            mappedIDs: mappedLessonIDs
        )
    }
    private var equationInput: String {
        guard let lessonID = focusedEquationLesson?.id else { return "" }
        return TransformationEquationDraftStore.draft(
            for: lessonID,
            in: equationDraftsRaw
        )
    }
    private var equationInputBinding: Binding<String> {
        Binding(
            get: { equationInput },
            set: { draft in
                guard let lessonID = focusedEquationLesson?.id else { return }
                equationDraftsRaw = TransformationEquationDraftStore.update(
                    draft,
                    for: lessonID,
                    in: equationDraftsRaw
                )
                mappedKind = nil
                mappingResultMessage = ""
                equationError = nil
                pendingNextEquationID = nil
                equationAccessibilityTarget = nil
            }
        )
    }
    private var focusedEquationChecks: [TransformationEquationCheckRecord] {
        guard let lessonID = focusedEquationLesson?.id else { return [] }
        return TransformationEquationCheckHistoryStore.checks(
            for: lessonID,
            in: equationCheckHistoryRaw
        )
    }
    private var currentEducationLevel: TransformationEducationLevel {
        TransformationEducationPath.deepestUnlockedLevel(mappedIDs: mappedLessonIDs)
    }
    private var focusedEducationLevel: TransformationEducationLevel {
        if let kind = focusedEquationLesson?.kind,
           let level = TransformationEducationPath.level(containing: kind) {
            return level
        }
        return currentEducationLevel
    }
    private var focusedEducationMappedCount: Int {
        TransformationEducationPath.mappedCount(
            in: focusedEducationLevel,
            mappedIDs: mappedLessonIDs
        )
    }

    /// The persisted/GPU stack stays flat, but the editor presents each contiguous
    /// repeat group as a single parent unit containing its child transformations.
    private struct StackUnit: Identifiable {
        /// ForEach identity. Decoded stacks are healed so a groupID names exactly one
        /// contiguous run (`normalizingGroupContiguity`), but the live stack can also
        /// be replaced wholesale by paths that skip that healing (legacy animation
        /// scenes apply their flat `spaceWarpOps` directly), and duplicate ForEach
        /// identifiers are undefined behavior in SwiftUI. Folding in the run's start
        /// index keeps twin fragments of a split group distinct regardless. Position
        /// churn is harmless: `.id(refresh)` already re-identifies the whole stack
        /// listing on every structural edit.
        struct ID: Hashable {
            let base: UUID
            let start: Int
        }
        let id: ID
        let range: Range<Int>
        let groupID: UUID?
    }

    private var stackUnits: [StackUnit] {
        var result: [StackUnit] = []
        var index = 0
        while index < ops.count {
            let range = unitRange(containing: index, in: ops)
            let groupID = ops[index].groupID
            result.append(StackUnit(id: StackUnit.ID(base: groupID ?? ops[index].id,
                                                     start: range.lowerBound),
                                    range: range, groupID: groupID))
            index = range.upperBound
        }
        return result
    }

    // ── Space "systems": Spherical Inversion + Sphere Projection ─────────────
    //
    // These are NOT reorderable warp-stack ops — they're two standalone,
    // scene-persisted space transforms (a global pre-raymarch RAY inversion and a
    // radial domain projection) that used to live only in the Space tab. They're
    // surfaced here so the Transformations section is the one place that shows every
    // space transform currently active. Adding one flips its DisplayConfig flag;
    // removing one turns it off. Their state lives in `cache.display`, not the stack.
    private enum SpaceSystem { case sphericalInversion, sphereProjection }

    private var sphericalInversionActive: Bool { cache.display.sphericalInversionMode != .off }
    private var sphereProjectionActive: Bool { cache.display.sphereProjectionEnabled }

    var body: some View {
        // LazyVStack, NOT VStack: users can stack many transforms, and a plain VStack
        // builds/hosts every op card (DisclosureGroup + sliders + toggles) synchronously
        // when the tab opens — which HANGS on a long stack. Lazy hosts only visible cards.
        // Per-card cost is kept low by the WarpSource.metalFunction cache: the 247 KB
        // shader-source scan that used to run per card, per scroll, is now memoized.
        LazyVStack(alignment: .leading, spacing: 10) {
            transformationsHeader

            Text("Direct editing. Transformations run from top to bottom; open a card only when you want to tune it.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            justUseSummary

            if isCreatingGroup {
                Label("Select two or more adjacent transformations, then choose Create Group.",
                      systemImage: "cursorarrow.click.2")
                    .font(.caption2)
                    .foregroundStyle(canCreateSelectedGroup ? .indigo : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Active space systems first (they aren't part of the reorderable stack).
            if sphericalInversionActive { sphericalInversionCard }
            if sphereProjectionActive { sphereProjectionCard }

            HStack {
                Label("Transformation Stack", systemImage: "square.stack.3d.up")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("TOP → BOTTOM")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }

            if ops.isEmpty {
                Text(emptyStackMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            } else {
                ForEach(stackUnits) { unit in
                    if let groupID = unit.groupID {
                        transformationGroupCard(groupID: groupID, range: unit.range)
                    } else if let index = unit.range.first, ops.indices.contains(index) {
                        opCard(ops[index], index: index,
                               isFirst: unit.range.lowerBound == 0,
                               isLast: unit.range.upperBound == ops.count,
                               insideGroup: false)
                    }
                }
                // Keep explicit row re-identification confined to the stack. Rebuilding
                // the whole section would discard the equation editor's keyboard cursor
                // and VoiceOver focus after a successful map.
                .id(refresh)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.mint.opacity(0.07)))
        .onAppear {
            migrateLegacyLessonProgressIfNeeded()
            initializeFocusedEquationIfNeeded()
            migrateLegacyEquationDraftIfNeeded()
            synchronizeRuntimeInteractionAccess(
                mode: experienceMode,
                mappedIDs: mappedTransformationIDs
            )
            if ops.count == 1, let onlyOperation = ops.first {
                expandedOperationIDs.insert(onlyOperation.id)
            }
            guard !didInitializeEducationExpansion else { return }
            expandedEducationLevelIDs = [focusedEducationLevel.id]
            didInitializeEducationExpansion = true
        }
        .onChange(of: mappedLessonIDsRaw) { previousRaw, currentRaw in
            synchronizeRuntimeInteractionAccess(
                mode: experienceMode,
                mappedIDs: TransformationUnlockProgress.runtimeKindIDs(
                    from: TransformationUnlockProgress.decode(
                        currentRaw,
                        legacyEncoded: legacyMappedTransformationIDsRaw
                    )
                )
            )
            reconcileEducationPresentation(
                previousRaw: previousRaw,
                currentRaw: currentRaw
            )
        }
        .onChange(of: legacyMappedTransformationIDsRaw) { _, _ in
            migrateLegacyLessonProgressIfNeeded()
            synchronizeRuntimeInteractionAccess(
                mode: experienceMode,
                mappedIDs: mappedTransformationIDs
            )
        }
        .onChange(of: experienceModeRaw) { _, currentRaw in
            let mode = TransformationExperienceMode.decode(currentRaw)
            synchronizeRuntimeInteractionAccess(
                mode: mode,
                mappedIDs: mappedTransformationIDs
            )
            let progress = mappedLessons.count
            switch mode {
            case .education:
                postAccessibilityAnnouncement(
                    "Learn mode. \(progress) \(progress == 1 ? "lesson" : "lessons") mapped."
                )
            case .justUse:
                postAccessibilityAnnouncement(
                    "Edit mode. The full catalog is available and \(progress) Learn \(progress == 1 ? "mapping is" : "mappings are") preserved."
                )
            }
        }
    }

    private var transformationsHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                transformationsTitle
                Spacer()
                transformationsHeaderActions
            }
            VStack(alignment: .leading, spacing: 7) {
                transformationsTitle
                HStack(spacing: 8) {
                    Spacer()
                    transformationsHeaderActions
                }
            }
        }
    }

    private var transformationsTitle: some View {
        Label("Transformations", systemImage: "circle.hexagongrid")
            .font(.headline)
    }

    private var transformationsHeaderActions: some View {
        HStack(spacing: 8) {
            groupCreationControls
            addMenu
        }
    }

    private var justUseSummary: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(.mint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Full Catalog")
                    .font(.caption.weight(.semibold))
                Text("Add a transformation, then open only the card you want to tune.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.mint.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }

    private var emptyStackMessage: String {
        switch experienceMode {
        case .justUse:
            return "No transformations yet. Choose Add to browse the full catalog."
        case .education where mappedLessons.isEmpty:
            return "No transformations yet. Map an equation to discover the first one."
        case .education:
            return "No transformations yet. Use Add to reuse a mapped transformation."
        }
    }

    @ViewBuilder
    private var groupCreationControls: some View {
        if isCreatingGroup {
            Button("Cancel") { cancelGroupCreation() }
                .font(.caption)
                .transformationActionHitTarget()
            Button("Create Group") { createSelectedGroup() }
                .font(.caption.weight(.semibold))
                .transformationActionHitTarget()
                .disabled(!canCreateSelectedGroup)
        } else {
            Button { beginGroupCreation() } label: {
                Label("Group", systemImage: "rectangle.inset.filled.and.person.filled")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .transformationActionHitTarget()
            .disabled(ops.filter {
                $0.groupID == nil && isOpRevealed($0)
            }.count < 2)
            .help("Select adjacent transformations and place them in an iterated group")
        }
    }

    // MARK: - Add menu

    private var addMenu: some View {
        Menu {
            if experienceMode == .education && mappedLessons.isEmpty {
                Section("Transformations") {
                    Text("Map an equation below to complete a lesson")
                }
            }
            if !hasStackCapacity {
                Section("Stack Capacity") {
                    Text("Remove a transformation before adding another")
                }
            }
            // Standalone space systems (Spherical Inversion + Sphere Projection) —
            // not stack ops; adding one flips its DisplayConfig flag on.
            Section("Global Space Systems") {
                Button { addSpaceSystem(.sphericalInversion) } label: {
                    Label("Spherical Inversion", systemImage: AppIcons.circleDashedInsetFilled)
                }
                .disabled(sphericalInversionActive)
                Button { addSpaceSystem(.sphereProjection) } label: {
                    Label("Sphere Projection", systemImage: AppIcons.globeAsiaAustralia)
                }
                .disabled(sphereProjectionActive || !cache.fractalType.supports(.sphereProjection))
            }
            // Education lists mapped lessons; Just Use lists the whole catalog.
            ForEach(WarpFamily.allCases, id: \.self) { family in
                let familyLessons = addableLessons.filter { $0.kind.family == family }
                if !familyLessons.isEmpty {
                    Section(family.rawValue) {
                        ForEach(familyLessons) { lesson in
                            Button { add(lesson.kind) } label: {
                                Label(lesson.kind.displayName, systemImage: lesson.kind.icon)
                            }
                            .disabled(!hasStackCapacity)
                        }
                    }
                }
            }
        } label: {
            Label("Add", systemImage: "plus.circle.fill")
                .font(.caption.weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .transformationActionHitTarget()
    }

    // MARK: - Equation mapping

    /// The first-release catalog is deliberately learned, not browsed. The guide
    /// exposes the mathematical map and a small Metal vocabulary; entering a known
    /// expression unlocks the production GPU operator. User input is only matched
    /// against the local lesson catalog — it is never compiled or executed.
    private var equationWorkbench: some View {
        VStack(alignment: .leading, spacing: 9) {
            educationWorkbenchHeader

            Text("Study the named transformation as mathematics first, then translate the same point map into Metal. A correct translation completes the lesson and adds its first instance.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("The mapper recognizes authored patterns; it never runs entered text as shader code.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if let focusedEquationLesson {
                transformationLessonCard(focusedEquationLesson)
            }

            VStack(alignment: .trailing, spacing: 7) {
                TextField("Write the Metal translation, leaving the result in p…", text: equationInputBinding, axis: .vertical)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(4...16)
                    .textFieldStyle(.roundedBorder)
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .focused($isEquationEditorFocused)
                    .accessibilityLabel("Metal equation")
                    .accessibilityHint("Enter the complete Metal translation for the named transformation lesson.")

                Button(action: mapEquation) {
                    Label("Check Translation", systemImage: "checkmark.circle")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .transformationActionHitTarget()
                .disabled(equationInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let mappedKind {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        mappingResult(mappedKind)
                        Spacer(minLength: 4)
                        nextEquationButton
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        mappingResult(mappedKind)
                        nextEquationButton
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let equationError {
                Label(equationError, systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }

            if !focusedEquationChecks.isEmpty {
                equationCheckHistory
            }

            DisclosureGroup(isExpanded: $isEquationGuideExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    if isEquationGuideExpanded {
                        Text("Each point-map receives mutable `float3 p`, original `float3 p0`, and a GPU-ready `SpaceWarpOp op`. Leave the result in `p`; each clue explains the fields it uses. Distance correction stays in the proven renderer.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(TransformationEducationPath.levels) { level in
                            educationLevelSection(level)
                        }
                    }
                }
                .padding(.top, 7)
            } label: {
                Label("Equation Guide", systemImage: "book.closed")
                    .font(.caption.weight(.semibold))
                    .transformationActionHitTarget()
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.indigo.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(Color.indigo.opacity(0.28), lineWidth: 1))
    }

    private var equationCheckHistory: some View {
        DisclosureGroup(isExpanded: $isEquationCheckHistoryExpanded) {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(focusedEquationChecks) { check in
                    equationCheckHistoryRow(check)
                }
            }
            .padding(.top, 7)
        } label: {
            Label(
                "Previous Checks (\(focusedEquationChecks.count))",
                systemImage: "clock.arrow.circlepath"
            )
            .font(.caption.weight(.semibold))
            .transformationActionHitTarget()
        }
        .accessibilityHint("Shows earlier translations checked for this lesson.")
    }

    private func equationCheckHistoryRow(
        _ check: TransformationEquationCheckRecord
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Label(
                    check.wasAccepted ? "Accepted" : "Needs work",
                    systemImage: check.wasAccepted
                        ? "checkmark.circle.fill"
                        : "exclamationmark.circle"
                )
                .font(.caption2.weight(.bold))
                .foregroundStyle(check.wasAccepted ? Color.mint : Color.orange)
                Spacer(minLength: 4)
                Text(
                    check.checkedAt,
                    format: .dateTime
                        .month(.abbreviated)
                        .day()
                        .hour()
                        .minute()
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Text(check.submittedText)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Text(check.feedback)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(check.wasAccepted
                    ? Color.mint.opacity(0.07)
                    : Color.orange.opacity(0.07))
        )
        .accessibilityElement(children: .combine)
    }

    private var educationWorkbenchHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                educationWorkbenchTitle
                Spacer()
                educationWorkbenchProgress
            }
            VStack(alignment: .leading, spacing: 3) {
                educationWorkbenchTitle
                educationWorkbenchProgress
            }
        }
    }

    private var educationWorkbenchTitle: some View {
        Label("Theory → Metal", systemImage: "function")
            .font(.subheadline.weight(.semibold))
    }

    private var educationWorkbenchProgress: some View {
        Text("LEVEL \(focusedEducationLevel.numeral) · \(focusedEducationMappedCount)/\(focusedEducationLevel.kinds.count) MAPPED")
            .font(.caption2.monospacedDigit().weight(.bold))
            .foregroundStyle(mappedLessons.isEmpty ? Color.secondary : Color.mint)
            .accessibilityLabel(
                "Level \(focusedEducationLevel.id), \(focusedEducationLevel.title), "
                + "\(focusedEducationMappedCount) of \(focusedEducationLevel.kinds.count) mapped"
            )
    }

    private func mappingResult(_ kind: SpaceWarpKind) -> some View {
        Label(mappingResultMessage, systemImage: kind.icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.mint)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityFocused(
                $equationAccessibilityTarget,
                equals: .result(.core(kind))
            )
    }

    @ViewBuilder
    private var nextEquationButton: some View {
        if pendingNextEquationID != nil {
            Button("Next map") {
                moveToNextEquation()
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .transformationActionHitTarget()
            .accessibilityHint("Moves the workbench to the next unfinished lesson.")
        }
    }

    @ViewBuilder
    private func educationLevelSection(_ level: TransformationEducationLevel) -> some View {
        let isOpen = TransformationEducationPath.isUnlocked(
            level,
            mappedIDs: mappedLessonIDs
        )
        let mappedCount = TransformationEducationPath.mappedCount(
            in: level,
            mappedIDs: mappedLessonIDs
        )
        let isComplete = TransformationEducationPath.isComplete(
            level,
            mappedIDs: mappedLessonIDs
        )
        let mappedPriorKnowledge = level.lessons.filter {
            mappedLessonIDs.contains($0.id)
        }

        if isOpen {
            DisclosureGroup(isExpanded: educationLevelExpansionBinding(level.id)) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(level.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let advancement = educationAdvancementMessage(
                        for: level,
                        mappedCount: mappedCount
                    ) {
                        Text(advancement)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.indigo)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(level.lessons) { lesson in
                        equationLessonRow(lesson)
                    }
                }
                .padding(.top, 6)
            } label: {
                educationLevelHeader(
                    level,
                    mappedCount: mappedCount,
                    isComplete: isComplete,
                    isLocked: false
                )
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                educationLevelHeader(
                    level,
                    mappedCount: mappedCount,
                    isComplete: isComplete,
                    isLocked: true
                )

                Text(educationGateMessage(for: level))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !mappedPriorKnowledge.isEmpty {
                    Text("MAPPED FROM PRIOR KNOWLEDGE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.mint)
                    ForEach(mappedPriorKnowledge) { lesson in
                        equationLessonRow(lesson)
                    }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.035)))
        }
    }

    private func educationLevelHeader(_ level: TransformationEducationLevel,
                                      mappedCount: Int,
                                      isComplete: Bool,
                                      isLocked: Bool) -> some View {
        let status = isLocked
            ? "LOCKED"
            : (isComplete ? "COMPLETE" : "\(mappedCount) OF \(level.kinds.count)")
        let icon = isLocked ? "lock.fill" : (isComplete ? "checkmark.seal.fill" : "seal")

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Label("LEVEL \(level.numeral) · \(level.title.uppercased())", systemImage: icon)
                Spacer()
                Text(status)
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(isComplete ? Color.mint : Color.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Label("LEVEL \(level.numeral) · \(level.title.uppercased())", systemImage: icon)
                Text(status)
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(isComplete ? Color.mint : Color.secondary)
            }
        }
        .font(.caption.weight(.semibold))
        .transformationActionHitTarget()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Level \(level.id), \(level.title)")
        .accessibilityValue(
            isLocked ? "Locked" : (isComplete
                ? "Complete"
                : "\(mappedCount) of \(level.kinds.count) mapped")
        )
    }

    private func educationLevelExpansionBinding(_ levelID: Int) -> Binding<Bool> {
        Binding(
            get: { expandedEducationLevelIDs.contains(levelID) },
            set: { isExpanded in
                if isExpanded { expandedEducationLevelIDs.insert(levelID) }
                else { expandedEducationLevelIDs.remove(levelID) }
            }
        )
    }

    private func focusEquation(_ id: TransformationLessonID?) {
        focusedEquationLessonIDRaw = id?.rawValue ?? ""
    }

    private func migrateLegacyLessonProgressIfNeeded() {
        let migrated = TransformationUnlockProgress.migratedEncoding(
            mappedLessonIDsRaw,
            legacyEncoded: legacyMappedTransformationIDsRaw
        )
        guard migrated != mappedLessonIDsRaw else { return }
        mappedLessonIDsRaw = migrated
    }

    private func initializeFocusedEquationIfNeeded() {
        guard focusedEquationID == nil else { return }
        if !legacyEquationDraft.isEmpty,
           let legacyLessonID = legacyDraftLessonID,
           educationGuideLessons.contains(where: { $0.id == legacyLessonID }) {
            focusEquation(legacyLessonID)
            return
        }
        guard let initial = TransformationEducationPath.preferredLesson(
            mappedIDs: mappedLessonIDs
        ) else { return }
        focusEquation(initial.id)
    }

    private func migrateLegacyEquationDraftIfNeeded() {
        guard !legacyEquationDraft.isEmpty,
              let lessonID = legacyDraftLessonID else { return }
        if TransformationEquationDraftStore.draft(
            for: lessonID,
            in: equationDraftsRaw
        ).isEmpty {
            equationDraftsRaw = TransformationEquationDraftStore.update(
                legacyEquationDraft,
                for: lessonID,
                in: equationDraftsRaw
            )
        }
        legacyEquationDraft = ""
        legacyFocusedEquationRawID = -1
    }

    /// V1 stored one draft plus a renderer raw ID. `-1` meant the original
    /// default lesson (Mirror); preserve that historical meaning even though V2
    /// intentionally starts new learners with the simpler Scale lesson.
    private var legacyDraftLessonID: TransformationLessonID? {
        TransformationEquationDraftStore.legacyLessonID(
            focusedRawID: legacyFocusedEquationRawID
        )
    }

    private func reconcileEducationPresentation(previousRaw: String,
                                                currentRaw: String) {
        let previous = TransformationUnlockProgress.decode(
            previousRaw,
            legacyEncoded: legacyMappedTransformationIDsRaw
        )
        let current = TransformationUnlockProgress.decode(
            currentRaw,
            legacyEncoded: legacyMappedTransformationIDsRaw
        )
        guard previous != current else { return }

        if pendingNextEquationID != nil {
            pendingNextEquationID = resolvedNextEquationID(
                preferredID: pendingNextEquationID,
                mappedIDs: current
            )
        }

        let guideIDs = Set(TransformationEducationPath.guideLessons(
            mappedIDs: current
        ).map(\.id))
        let focusIsInvalid = focusedEquationID.map { !guideIDs.contains($0) } ?? true

        if focusIsInvalid,
           let preferred = TransformationEducationPath.preferredLesson(mappedIDs: current) {
            focusEquation(preferred.id)
            if let level = TransformationEducationPath.level(containing: preferred.kind) {
                expandedEducationLevelIDs = [level.id]
            }
            return
        }

        let previousDeepest = TransformationEducationPath.deepestUnlockedLevel(
            mappedIDs: previous
        )
        let currentDeepest = TransformationEducationPath.deepestUnlockedLevel(
            mappedIDs: current
        )
        if previousDeepest.id != currentDeepest.id {
            expandedEducationLevelIDs.insert(currentDeepest.id)
        }
    }

    private func assistanceStage(for lesson: TransformationEquationLesson) -> TransformationAssistanceStage {
        assistanceStages[lesson.id] ?? .theory
    }

    private func advanceAssistance(for lesson: TransformationEquationLesson,
                                   event: TransformationAssistanceEvent) {
        let current = assistanceStage(for: lesson)
        let isMapped = mappedLessonIDs.contains(lesson.id)
        let next = TransformationAssistancePolicy.advance(
            from: current,
            event: event,
            isMapped: isMapped,
            isFocused: focusedEquationLesson?.id == lesson.id
        )
        guard next != current else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            assistanceStages[lesson.id] = next
        }
        switch next {
        case .vocabulary:
            moveAccessibilityFocus(to: .vocabulary(lesson.id))
            postAccessibilityAnnouncement(
                "Metal vocabulary revealed for \(lesson.kind.displayName)."
            )
        case .hint:
            moveAccessibilityFocus(to: .hint(lesson.id))
            postAccessibilityAnnouncement(
                "Implementation hint for \(lesson.kind.displayName). \(lesson.hint)"
            )
        case .fullAnswer:
            moveAccessibilityFocus(to: .answer(lesson.id))
            postAccessibilityAnnouncement(
                "Full Metal answer revealed for \(lesson.kind.displayName)."
            )
        case .theory:
            break
        }
    }

    private func postAccessibilityAnnouncement(_ message: String, urgent: Bool = false) {
        PlatformAccessibilityAdapter.announce(message, urgent: urgent)
    }

    private func educationAdvancementMessage(for level: TransformationEducationLevel,
                                             mappedCount: Int) -> String? {
        guard let threshold = level.requiredToAdvance,
              let index = TransformationEducationPath.levels.firstIndex(where: { $0.id == level.id }),
              TransformationEducationPath.levels.indices.contains(index + 1) else {
            let remainingLessons = TransformationEducationPath.unmappedLessonCount(
                mappedIDs: mappedLessonIDs
            )
            if remainingLessons == 0 {
                return "Learning path complete. Every built-in transformation has been mapped."
            }
            if mappedCount == level.kinds.count {
                return "Final level complete · \(remainingLessons) earlier \(remainingLessons == 1 ? "lesson remains" : "lessons remain")."
            }
            return "Final level — map these systems in any order."
        }

        let next = TransformationEducationPath.levels[index + 1]
        let remaining = max(0, threshold - mappedCount)
        if remaining == 0 {
            return "Level \(next.numeral) — \(next.title) is open."
        }
        return "Map \(remaining) more \(remaining == 1 ? "equation" : "equations") here to open Level \(next.numeral)."
    }

    private func educationGateMessage(for level: TransformationEducationLevel) -> String {
        guard let blocker = TransformationEducationPath.blockingLevel(
            for: level,
            mappedIDs: mappedLessonIDs
        ) else { return "This level is ready." }
        let remaining = TransformationEducationPath.mappingsRemainingToAdvance(
            from: blocker,
            mappedIDs: mappedLessonIDs
        )
        return "Map \(remaining) more \(remaining == 1 ? "equation" : "equations") in Level \(blocker.numeral) to continue toward Level \(level.numeral)."
    }

    @ViewBuilder
    private func transformationLessonCard(_ lesson: TransformationEquationLesson) -> some View {
        let isMapped = mappedLessonIDs.contains(lesson.id)
        let stage = assistanceStage(for: lesson)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(lesson.kind.displayName, systemImage: lesson.kind.icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.indigo)
                Spacer()
                Text(isMapped ? "COMPLETED" : "CURRENT LESSON")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isMapped ? Color.mint : Color.secondary)
            }

            Text(lesson.kind.tagline)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                Text("MATHEMATICAL MODEL")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                TransformationMathEquationView(
                    notation: lesson.mathematicalNotation,
                    spokenNotation: lesson.spokenMathematicalNotation
                )
                Text("Read it as: \(lesson.spokenMathematicalNotation)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.indigo.opacity(0.08)))
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 3) {
                Text("YOUR TRANSLATION TASK")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("Express this exact point transformation in Metal using the supplied `p` and `op`, then leave the transformed point back in `p`.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if stage >= .vocabulary {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Label("Metal Vocabulary", systemImage: "curlybraces")
                        .font(.caption.weight(.semibold))
                    Text("These are the language pieces used by this lesson—not their final order or complete implementation.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(TransformationEquationCatalog.metalVocabulary(for: lesson)) { entry in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.notation)
                                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                                .foregroundStyle(.indigo)
                                .textSelection(.enabled)
                            Text(entry.meaning)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(entry.notation). \(entry.meaning)")
                    }
                }
                .accessibilityFocused(
                    $equationAccessibilityTarget,
                    equals: .vocabulary(lesson.id)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    assistanceControls(for: lesson, isMapped: isMapped, stage: stage)
                }
                VStack(alignment: .leading, spacing: 6) {
                    assistanceControls(for: lesson, isMapped: isMapped, stage: stage)
                }
            }

            if stage >= .hint {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Implementation Hint", systemImage: "lightbulb")
                        .font(.caption.weight(.semibold))
                    Text(lesson.hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                    .accessibilityFocused(
                        $equationAccessibilityTarget,
                        equals: .hint(lesson.id)
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if stage >= .fullAnswer {
                VStack(alignment: .leading, spacing: 5) {
                    Text("FULL METAL ANSWER")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.indigo)
                    codeBlock(lesson.metalNotation)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Full Metal answer. \(lesson.metalNotation)")
                .accessibilityFocused(
                    $equationAccessibilityTarget,
                    equals: .answer(lesson.id)
                )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Text("Choose a different named lesson in the guide below.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.indigo.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(Color.indigo.opacity(0.2), lineWidth: 1))
    }

    @ViewBuilder
    private func assistanceControls(for lesson: TransformationEquationLesson,
                                    isMapped: Bool,
                                    stage: TransformationAssistanceStage) -> some View {
        if stage < .hint {
            Button(stage < .vocabulary ? "Show Metal vocabulary" : "Get implementation hint") {
                let event: TransformationAssistanceEvent = stage < .vocabulary
                    ? .showVocabulary
                    : .requestHint
                advanceAssistance(for: lesson, event: event)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            #if !os(macOS)
            .frame(minHeight: 44)
            #endif
        }

        if stage < .fullAnswer,
           TransformationAssistancePolicy.canRevealAnswer(
               from: stage,
               isMapped: isMapped,
               isFocused: focusedEquationLesson?.id == lesson.id
           ) {
            Button(isMapped ? "Review Metal answer" : "Reveal full Metal answer") {
                advanceAssistance(for: lesson, event: .revealAnswer)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            #if !os(macOS)
            .frame(minHeight: 44)
            #endif
        }
    }

    @ViewBuilder
    private func equationLessonRow(_ lesson: TransformationEquationLesson) -> some View {
        let isMapped = mappedLessonIDs.contains(lesson.id)
        let isFocused = focusedEquationLesson?.id == lesson.id

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Label(lesson.kind.displayName, systemImage: lesson.kind.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isMapped ? Color.mint : Color.primary)
                Spacer()
                if isMapped {
                    Text("MAPPED")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.mint)
                }
            }

            Text(lesson.mathematicalNotation)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(lesson.spokenMathematicalNotation)

            if isFocused {
                Label("Current lesson", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.indigo)
                    .accessibilityAddTraits(.isSelected)
            } else {
                Button("Study this lesson") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        focusEquation(lesson.id)
                        mappedKind = nil
                        mappingResultMessage = ""
                        equationError = nil
                        pendingNextEquationID = nil
                        equationAccessibilityTarget = nil
                    }
                    isEquationEditorFocused = true
                    postAccessibilityAnnouncement(
                        "\(lesson.kind.displayName) is now the current lesson."
                    )
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                #if !os(macOS)
                .frame(minHeight: 44)
                #endif
            }

            Text(isFocused
                 ? (isMapped
                    ? "Use the lesson above to review its theory or Metal answer."
                    : "Use the lesson above to translate its mathematical model into Metal.")
                 : "Select this named transformation to study its mathematical model.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(
            isMapped ? Color.mint.opacity(0.08) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(isFocused ? Color.indigo.opacity(0.45) : Color.clear, lineWidth: 1))
    }

    private func mapEquation() {
        guard experienceMode == .education else { return }
        guard let lesson = focusedEquationLesson else { return }
        let attempt = TransformationEquationCatalog.assess(
            equationInput,
            for: lesson
        )
        let freshlyPersistedCheckHistory = UserDefaults.standard.string(
            forKey: TransformationEquationCheckHistoryStore.defaultsKey
        ) ?? ""
        equationCheckHistoryRaw = TransformationEquationCheckHistoryStore.record(
            equationInput,
            assessment: attempt,
            for: lesson.id,
            merging: [
                equationCheckHistoryRaw,
                freshlyPersistedCheckHistory,
            ]
        )
        guard attempt == .matched else {
            let message = attempt.guidance
            withAnimation(.easeInOut(duration: 0.15)) {
                mappedKind = nil
                mappingResultMessage = ""
                equationError = message
                pendingNextEquationID = nil
            }
            postAccessibilityAnnouncement(message, urgent: true)
            return
        }
        let kind = lesson.kind

        let freshlyPersistedProgress = UserDefaults.standard.string(
            forKey: TransformationUnlockProgress.defaultsKey
        ) ?? ""
        let freshlyPersistedLegacyProgress = UserDefaults.standard.string(
            forKey: TransformationUnlockProgress.legacyDefaultsKey
        ) ?? ""
        let mappedIDsBefore = mappedLessonIDs.union(
            TransformationUnlockProgress.decode(
                freshlyPersistedProgress,
                legacyEncoded: freshlyPersistedLegacyProgress
            )
        )
        let wasMapped = mappedIDsBefore.contains(.core(kind))
        let updatedProgress = TransformationUnlockProgress.unlock(
            kind,
            merging: [mappedLessonIDsRaw, freshlyPersistedProgress],
            legacyEncodedValues: [
                legacyMappedTransformationIDsRaw,
                freshlyPersistedLegacyProgress,
            ]
        )
        mappedLessonIDsRaw = updatedProgress
        let mappedIDsAfter = TransformationUnlockProgress.decode(
            updatedProgress,
            legacyEncoded: freshlyPersistedLegacyProgress
        )
        let runtimeKindIDsAfter = TransformationUnlockProgress.runtimeKindIDs(
            from: mappedIDsAfter
        )
        synchronizeRuntimeInteractionAccess(
            mode: experienceMode,
            mappedIDs: runtimeKindIDsAfter
        )
        let newlyOpenedLevels = TransformationEducationPath.newlyUnlockedLevels(
            before: mappedIDsBefore,
            after: mappedIDsAfter
        )
        assistanceStages[.core(kind)] = .fullAnswer
        let preferredLesson = TransformationEducationPath.preferredLesson(
            mappedIDs: mappedIDsAfter
        )
        let nextLesson = preferredLesson.flatMap {
            $0.id != lesson.id && !mappedIDsAfter.contains($0.id) ? $0 : nil
        }

        let canAdd = ops.count < Int(kMaxSpaceWarpOps)
        let alreadyInStack = TransformationAccessPolicy.hasExactInstance(
            of: kind,
            in: ops
        )
        if !wasMapped && canAdd && !alreadyInStack {
            add(kind, mappedIDs: runtimeKindIDsAfter)
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            mappedKind = kind
            equationError = nil
            if wasMapped {
                mappingResultMessage = "\(kind.displayName) is already mapped and available in Add."
            } else if alreadyInStack {
                mappingResultMessage = "\(kind.displayName) mapped. Its existing scene instance is now fully revealed."
            } else if canAdd {
                mappingResultMessage = "\(kind.displayName) mapped and added to the stack."
            } else {
                mappingResultMessage = "\(kind.displayName) mapped. The stack is full, so use it later from Add."
            }
            if newlyOpenedLevels.count == 1, let openedLevel = newlyOpenedLevels.first {
                mappingResultMessage += " Level \(openedLevel.numeral) — \(openedLevel.title) is now open."
            } else if let firstOpened = newlyOpenedLevels.first,
                      let deepestOpened = newlyOpenedLevels.last {
                mappingResultMessage += " Levels \(firstOpened.numeral)–\(deepestOpened.numeral) are now open; continue with Level \(deepestOpened.numeral) — \(deepestOpened.title)."
            }
            pendingNextEquationID = nextLesson?.id
            equationDraftsRaw = TransformationEquationDraftStore.update(
                "",
                for: lesson.id,
                in: equationDraftsRaw
            )
        }
        moveAccessibilityFocus(to: .result(lesson.id))
        let nextAnnouncement = nextLesson == nil ? "" : " Next map is ready."
        postAccessibilityAnnouncement(mappingResultMessage + nextAnnouncement)
    }

    private func moveToNextEquation() {
        guard pendingNextEquationID != nil,
              let nextID = resolvedNextEquationID(
                preferredID: pendingNextEquationID,
                mappedIDs: mappedLessonIDs
              ),
              let lesson = educationGuideLessons.first(where: { $0.id == nextID }) else {
            pendingNextEquationID = nil
            return
        }
        withAnimation(.easeInOut(duration: 0.15)) {
            focusEquation(nextID)
            pendingNextEquationID = nil
            mappedKind = nil
            mappingResultMessage = ""
            equationError = nil
            equationAccessibilityTarget = nil
            if let level = TransformationEducationPath.level(containing: lesson.kind) {
                expandedEducationLevelIDs = [level.id]
            }
        }
        isEquationEditorFocused = true
        let subject = mappedLessonIDs.contains(lesson.id)
            ? lesson.kind.displayName
            : "The next equation"
        postAccessibilityAnnouncement("\(subject) is ready to assemble.")
    }

    private func resolvedNextEquationID(
        preferredID: TransformationLessonID?,
        mappedIDs: Set<TransformationLessonID>
    ) -> TransformationLessonID? {
        let guideIDs = Set(TransformationEducationPath.guideLessons(
            mappedIDs: mappedIDs
        ).map(\.id))
        if let preferredID,
           preferredID != focusedEquationID,
           !mappedIDs.contains(preferredID),
           guideIDs.contains(preferredID) {
            return preferredID
        }
        guard let preferred = TransformationEducationPath.preferredLesson(
            mappedIDs: mappedIDs
        ), preferred.id != focusedEquationID,
           !mappedIDs.contains(preferred.id),
           guideIDs.contains(preferred.id) else { return nil }
        return preferred.id
    }

    private func moveAccessibilityFocus(to target: EquationAccessibilityTarget) {
        equationAccessibilityTarget = nil
        Task { @MainActor in
            await Task.yield()
            equationAccessibilityTarget = target
        }
    }

    // MARK: - One op card

    @ViewBuilder
    private func opCard(_ op: SpaceWarpOpValue, index: Int, isFirst: Bool, isLast: Bool,
                        insideGroup: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    opHeaderIdentity(op, index: index, insideGroup: insideGroup)
                    Spacer(minLength: 4)
                    opHeaderActions(op, index: index, isFirst: isFirst, isLast: isLast,
                                    insideGroup: insideGroup)
                }
                VStack(alignment: .leading, spacing: 5) {
                    opHeaderIdentity(op, index: index, insideGroup: insideGroup)
                    HStack(spacing: 8) {
                        Spacer()
                        opHeaderActions(op, index: index, isFirst: isFirst, isLast: isLast,
                                        insideGroup: insideGroup)
                    }
                }
            }
            .font(.caption)

            if isOpRevealed(op) {
                if insideGroup {
                    operationEditor(op)
                } else {
                    DisclosureGroup(isExpanded: operationExpandedBinding(op.id)) {
                        // DisclosureGroup may evaluate its content builder while
                        // closed. Keep slider rows and technical source genuinely lazy.
                        if expandedOperationIDs.contains(op.id) {
                            operationEditor(op)
                                .padding(.top, 6)
                        }
                    } label: {
                        Label("Edit parameters", systemImage: "slider.horizontal.3")
                            .font(.caption.weight(.semibold))
                            .transformationActionHitTarget()
                    }
                }
            } else {
                Label("Complete the \(op.kind.displayName) lesson to edit its controls and add another",
                      systemImage: "lock")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            groupSelection.contains(op.id) && !insideGroup
                ? Color.indigo.opacity(0.15) : Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(
            groupSelection.contains(op.id) && !insideGroup
                ? Color.indigo.opacity(0.65) : Color.clear, lineWidth: 1))
    }

    @ViewBuilder
    private func operationEditor(_ op: SpaceWarpOpValue) -> some View {
        let kind = op.kind
        let enabled = liveOp(op.id)?.isEnabled ?? op.isEnabled
        Group {
            EffectSliderRow(
                icon: kind.icon, label: kind.amountLabel,
                value: Binding(get: { liveOp(op.id)?.strength ?? op.strength },
                               set: { v in update(op.id) { $0.strength = v } }),
                range: kind.strengthRange,
                enabled: .constant(true), onChanged: {}, showToggle: false,
                valueFormat: { String(format: "%.2f", $0) })

            if kind == .coxeter {
                coxeterEditor(op)
            } else {
                ForEach(kind.params) { spec in
                    EffectSliderRow(
                        icon: spec.icon, label: spec.label,
                        value: Binding(
                            get: {
                                let live = liveOp(op.id) ?? op
                                return spec.slot == 1 ? live.p1 : live.p2
                            },
                            set: { value in
                                update(op.id) {
                                    if spec.slot == 1 { $0.p1 = value }
                                    else { $0.p2 = value }
                                }
                            }),
                        range: spec.range,
                        enabled: .constant(true), onChanged: {}, showToggle: false,
                        valueFormat: { String(format: "%.2f", $0) })
                }
            }

            if let toggle = kind.toggle {
                HStack(spacing: 8) {
                    Label(toggle.label, systemImage: toggle.icon)
                        .font(.caption)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { (liveOp(op.id) ?? op).p2 > 0.5 },
                        set: { value in
                            update(op.id) { $0.p2 = value ? 1 : 0 }
                            refresh &+= 1
                        }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .accessibilityLabel("\(kind.displayName), \(toggle.label)")
                }
            }

            if let sourceAngle = kind.sourceAngle {
                EffectSliderRow(
                    icon: sourceAngle.icon, label: sourceAngle.label,
                    value: Binding(
                        get: { (liveOp(op.id) ?? op).axis.z },
                        set: { value in update(op.id) { $0.axis.z = value } }
                    ),
                    range: sourceAngle.range,
                    enabled: .constant(true), onChanged: {}, showToggle: false,
                    valueFormat: {
                        String(format: "%.0f°", $0 * 180 / Float.pi)
                    }
                )
            }

            if kind.usesAxis {
                axisRow(op, "\(kind.axisLabel) X", "arrow.left.and.right", \.x)
                axisRow(op, "\(kind.axisLabel) Y", "arrow.up.and.down", \.y)
                axisRow(op, "\(kind.axisLabel) Z", "arrow.up.left.and.arrow.down.right", \.z)
            }
        }
        .opacity(enabled ? 1.0 : 0.4)
        .disabled(!enabled)

        underTheHood(op)
    }

    private func operationExpandedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedOperationIDs.contains(id) },
            set: { isExpanded in
                if isExpanded { expandedOperationIDs.insert(id) }
                else { expandedOperationIDs.remove(id) }
            }
        )
    }

    @ViewBuilder
    private func opHeaderIdentity(_ op: SpaceWarpOpValue, index: Int,
                                  insideGroup: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                opHeaderPrimary(op, index: index, insideGroup: insideGroup)
                opMusicBadge(op, index: index)
            }
            VStack(alignment: .leading, spacing: 4) {
                opHeaderPrimary(op, index: index, insideGroup: insideGroup)
                HStack(spacing: 6) {
                    Spacer()
                    opMusicBadge(op, index: index)
                }
            }
        }
    }

    @ViewBuilder
    private func opHeaderPrimary(_ op: SpaceWarpOpValue, index: Int,
                                 insideGroup: Bool) -> some View {
        let kind = op.kind
        let revealed = isOpRevealed(op)
        let subject = stackOpSubject(op, index: index)
        HStack(spacing: 8) {
            if isCreatingGroup && !insideGroup && revealed {
                Button { toggleGroupSelection(op.id) } label: {
                    Image(systemName: groupSelection.contains(op.id)
                          ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(groupSelection.contains(op.id) ? .indigo : .secondary)
                }
                .buttonStyle(.borderless)
                .transformationActionHitTarget()
                .help("Include \(subject) in the new group")
                .accessibilityLabel(
                    groupSelection.contains(op.id)
                        ? "Remove \(subject) from the new group"
                        : "Include \(subject) in the new group"
                )
            }
            Text("\(index + 1)")
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Label(kind.displayName, systemImage: kind.icon)
                    .font(.subheadline.weight(.medium))
                Text(revealed ? kind.tagline : "Complete its Learn lesson to edit this scene operation")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
        }
    }

    @ViewBuilder
    private func opMusicBadge(_ op: SpaceWarpOpValue, index: Int) -> some View {
        let kind = op.kind
        if isOpRevealed(op), let mapping = musicMappings(forSlot: index).first {
            let all = musicMappings(forSlot: index)
            let extra = all.count > 1 ? " +\(all.count - 1)" : ""
            Label(kind.musicFieldLabel(mapping.spaceWarpField) + extra,
                  systemImage: "music.note")
                .font(.caption2.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(.tint.opacity(0.18)))
                .foregroundStyle(.tint)
                .help(all.map {
                    "\(kind.musicFieldLabel($0.spaceWarpField)) ← \($0.source.displayName) (\($0.responseCurve.displayName))"
                }.joined(separator: "\n") + "\nEdit in the Music tab.")
        }
    }

    @ViewBuilder
    private func opHeaderActions(_ op: SpaceWarpOpValue, index: Int, isFirst: Bool,
                                 isLast: Bool, insideGroup: Bool) -> some View {
        let subject = stackOpSubject(op, index: index)
        if isOpRevealed(op) {
            Toggle("", isOn: Binding(
                get: { liveOp(op.id)?.isEnabled ?? op.isEnabled },
                set: { value in
                    update(op.id) { $0.isEnabled = value }
                    refresh &+= 1
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .transformationActionHitTarget()
                .accessibilityLabel("\(subject) enabled")
            Button { moveTransform(op.id, by: -1, insideGroup: insideGroup) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .transformationActionHitTarget()
            .disabled(isFirst || !canMoveTransform(op.id, by: -1, insideGroup: insideGroup))
            .accessibilityLabel("Move \(subject) up")
            Button { moveTransform(op.id, by: 1, insideGroup: insideGroup) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .transformationActionHitTarget()
            .disabled(isLast || !canMoveTransform(op.id, by: 1, insideGroup: insideGroup))
            .accessibilityLabel("Move \(subject) down")
        }
        Button(role: .destructive) { delete(op.id) } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .transformationActionHitTarget()
        .accessibilityLabel("Remove \(subject)")
    }

    private func isOpRevealed(_ op: SpaceWarpOpValue) -> Bool {
        TransformationAccessPolicy.canInteract(
            withRawKindID: op.type,
            mode: experienceMode,
            mappedIDs: mappedTransformationIDs
        )
    }

    private func synchronizeRuntimeInteractionAccess(
        mode: TransformationExperienceMode,
        mappedIDs: Set<Int32>
    ) {
        renderSettings.setSpaceWarpInteractionAccess(
            allowsUnmapped: mode == .justUse,
            mappedKindIDs: mappedIDs
        )
    }

    private func stackOpSubject(_ op: SpaceWarpOpValue, index: Int) -> String {
        "\(op.kind.displayName) transformation \(index + 1)"
    }

    /// An explicit super-group in the editor. Its children remain ordinary
    /// transformations, but move together and repeat as a single ordered unit.
    ///
    /// `range` was captured when the ForEach data was built, but `ops` re-reads the
    /// LIVE stack — and the stack can be replaced underneath this view with NO
    /// invalidation it observes: RenderSettings is deliberately not Observable, and
    /// animation playback (`AnimationManager.play()` via hand gesture / App Intent),
    /// scene cycling, and the fractal browser window all swap the stack without a
    /// notification this body watches. A LazyVStack row can therefore (re)instantiate
    /// against a shorter stack than the one its range indexed. Bounds-check against a
    /// single snapshot — mirroring the `ops.indices.contains` guards on the ungrouped
    /// and child rows — and render nothing when stale; the next structural edit or
    /// tab open rebuilds fresh units.
    @ViewBuilder
    private func transformationGroupCard(groupID: UUID, range: Range<Int>) -> some View {
        let snapshot = ops
        if snapshot.indices.contains(range.lowerBound),
           range.upperBound <= snapshot.count,
           snapshot[range.lowerBound].groupID == groupID {
            groupCardBody(groupID: groupID, range: range, snapshot: snapshot)
        }
    }

    /// The card content proper. Reads ONLY `snapshot` (bounds-checked by the caller)
    /// so every subscript in one card describes the same instant of the stack.
    private func groupCardBody(groupID: UUID, range: Range<Int>,
                               snapshot: [SpaceWarpOpValue]) -> some View {
        let first = snapshot[range.lowerBound]
        let fallbackIterations = first.effectiveGroupIterations
        let passes = first.effectiveGroupIterations
        let mode = first.effectiveGroupMode
        let children = range.map { snapshot[$0] }
        let childKinds = children.map(\.kind)
        let isMandelboxSequence = childKinds == [.boxFold, .sphereFold, .scale]
        let allChildrenRevealed = children.allSatisfy(isOpRevealed)
        let title = mode == .mandelboxRecurrence && isMandelboxSequence && allChildrenRevealed
            ? "Mandelbox Recurrence" : "Transformation Group"
        let sequence = children.map(\.kind.displayName).joined(separator: "  →  ")
        let transformWork = range.count * passes
        return VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    groupHeaderIdentity(title: title, stepCount: range.count, mode: mode)
                    Spacer(minLength: 4)
                    if allChildrenRevealed {
                        groupHeaderActions(
                            firstID: first.id,
                            groupID: groupID,
                            title: title,
                            canMoveUp: canMoveTransform(first.id, by: -1, insideGroup: false),
                            canMoveDown: canMoveTransform(first.id, by: 1, insideGroup: false)
                        )
                    } else {
                        lockedGroupRemovalAction(groupID: groupID)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    groupHeaderIdentity(title: title, stepCount: range.count, mode: mode)
                    HStack(spacing: 8) {
                        Spacer()
                        if allChildrenRevealed {
                            groupHeaderActions(
                                firstID: first.id,
                                groupID: groupID,
                                title: title,
                                canMoveUp: canMoveTransform(first.id, by: -1, insideGroup: false),
                                canMoveDown: canMoveTransform(first.id, by: 1, insideGroup: false)
                            )
                        } else {
                            lockedGroupRemovalAction(groupID: groupID)
                        }
                    }
                }
            }

            Text(sequence)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if allChildrenRevealed {
                HStack(spacing: 8) {
                    Text("Passes")
                        .font(.caption.weight(.semibold))
                    Stepper(value: Binding(
                        get: {
                            cache.spaceWarpStack.first(where: { $0.groupID == groupID })?
                                .effectiveGroupIterations ?? fallbackIterations
                        },
                        set: { updateGroupIterations(groupID, iterations: $0) }),
                        in: 1...Int(kMaxSpaceWarpGroupIterations)) {
                        Text("\(cache.spaceWarpStack.first(where: { $0.groupID == groupID })?.effectiveGroupIterations ?? fallbackIterations)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                    }
                    .fixedSize()
                    .help("Repeat the complete child pipeline this many times")
                    Spacer()
                    Text("\(transformWork) transform steps / distance sample")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(transformWork > 32 ? .orange : .secondary)
                }
            } else {
                Label("Map every unknown step to edit this group", systemImage: "lock")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if mode == .mandelboxRecurrence {
                Text(allChildrenRevealed && isMandelboxSequence
                     ? "After each complete pass, the point that entered the group is added back (+p₀). That feedback is what makes this the Mandelbox recurrence."
                     : "After each complete pass, the point that entered the group is added back as recurrence feedback (+p₀).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("One pass runs every child top → bottom. The next pass receives the previous pass’s output.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if cache.fractalType == .constructionPrimitive {
                Text("The analytic base shape is evaluated once after this loop; Formula Iterations do not apply.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("This transform loop runs before the base formula. Formula Iterations are a separate loop, not another pass setting for this group.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup(isExpanded: groupExpandedBinding(groupID)) {
                // DisclosureGroup still evaluates its content builder while closed.
                // Gate the heavy slider cards explicitly so a collapsed group is
                // genuinely cheap to open/scroll on a cold launch.
                if expandedGroups.contains(groupID) {
                    ForEach(Array(range), id: \.self) { index in
                        if ops.indices.contains(index) {
                            opCard(ops[index], index: index,
                                   isFirst: index == range.lowerBound,
                                   isLast: index == range.upperBound - 1,
                                   insideGroup: true)
                                .padding(.leading, 8)
                        }
                    }
                }
            } label: {
                Label("Edit child transformations", systemImage: "slider.horizontal.3")
                    .font(.caption.weight(.semibold))
                    .transformationActionHitTarget()
            }
            .tint(.indigo)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.indigo.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.indigo.opacity(0.45), lineWidth: 1))
    }

    @ViewBuilder
    private func groupHeaderIdentity(title: String, stepCount: Int,
                                     mode: SpaceWarpGroupMode) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Label(title, systemImage: "repeat")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.indigo)
                groupHeaderBadges(stepCount: stepCount, mode: mode)
            }
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: "repeat")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.indigo)
                HStack(spacing: 6) {
                    groupHeaderBadges(stepCount: stepCount, mode: mode)
                }
            }
        }
    }

    @ViewBuilder
    private func groupHeaderBadges(stepCount: Int, mode: SpaceWarpGroupMode) -> some View {
        Text("\(stepCount) STEPS")
            .font(.caption2.weight(.heavy))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(.indigo.opacity(0.16)))
            .foregroundStyle(.indigo)
        if mode == .mandelboxRecurrence {
            Text("+ p₀ FEEDBACK")
                .font(.caption2.weight(.heavy))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(.orange.opacity(0.17)))
                .foregroundStyle(.orange)
                .accessibilityLabel("Adds the group input after every pass")
        }
    }

    @ViewBuilder
    private func groupHeaderActions(firstID: UUID, groupID: UUID, title: String,
                                    canMoveUp: Bool, canMoveDown: Bool) -> some View {
        // Resolve by stable UUIDs captured at render time. The live stack can be
        // replaced before a click arrives, and every mutation safely no-ops then.
        Button { move(firstID, by: -1) } label: {
            Image(systemName: "chevron.up")
        }
        .buttonStyle(.borderless)
        .transformationActionHitTarget()
        .disabled(!canMoveUp)
        .accessibilityLabel("Move \(title) up")
        Button { move(firstID, by: 1) } label: {
            Image(systemName: "chevron.down")
        }
        .buttonStyle(.borderless)
        .transformationActionHitTarget()
        .disabled(!canMoveDown)
        .accessibilityLabel("Move \(title) down")
        Menu {
            Button { ungroup(groupID) } label: {
                Label("Dissolve Group", systemImage: "rectangle.split.3x1")
            }
            Button(role: .destructive) { deleteGroup(groupID) } label: {
                Label("Delete Group", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .transformationActionHitTarget()
        .fixedSize()
        .accessibilityLabel("\(title) actions")
    }

    private func lockedGroupRemovalAction(groupID: UUID) -> some View {
        Button(role: .destructive) { deleteGroup(groupID) } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .transformationActionHitTarget()
        .accessibilityLabel("Remove locked transformation group")
        .help("Remove this locked group from the scene")
    }

    private func groupExpandedBinding(_ groupID: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(groupID) },
            set: { isExpanded in
                if isExpanded { expandedGroups.insert(groupID) }
                else { expandedGroups.remove(groupID) }
            }
        )
    }

    /// Self-documenting panel: what this transform does, the math, and the EXACT
    /// Metal function it runs on the GPU (pulled live from the embedded shader).
    @ViewBuilder
    private func underTheHood(_ op: SpaceWarpOpValue) -> some View {
        let kind = op.kind
        let d = kind.descriptor
        DisclosureGroup(isExpanded: technicalDetailExpandedBinding(op.id)) {
            if expandedTechnicalDetailIDs.contains(op.id) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(d.blurb)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(kind.formula)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let src = WarpSource.metalFunction(named: d.gpuApplyFn) {
                        codeBlock(src)
                    }
                    if let de = d.gpuDEScaleFn, let src = WarpSource.metalFunction(named: de) {
                        Text("Distance-estimator correction")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        codeBlock(src)
                    }
                }
                .padding(.top, 6)
            }
        } label: {
            Label("Under the hood — ƒ \(d.gpuApplyFn)", systemImage: "function")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tint)
                .transformationActionHitTarget()
        }
    }

    private func technicalDetailExpandedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedTechnicalDetailIDs.contains(id) },
            set: { isExpanded in
                if isExpanded { expandedTechnicalDetailIDs.insert(id) }
                else { expandedTechnicalDetailIDs.remove(id) }
            }
        )
    }

    private func codeBlock(_ source: String) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(source)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.22)))
    }

    private func axisRow(_ op: SpaceWarpOpValue, _ label: String, _ icon: String,
                         _ comp: WritableKeyPath<SIMD3<Float>, Float>) -> some View {
        EffectSliderRow(
            icon: icon, label: label,
            value: Binding(
                get: { (liveOp(op.id) ?? op).axis[keyPath: comp] },
                set: { v in update(op.id) { $0.axis[keyPath: comp] = v } }),
            range: -1.0...1.0,
            enabled: .constant(true), onChanged: {}, showToggle: false,
            valueFormat: { String(format: "%.2f", $0) })
    }

    /// Dedicated editor for the discrete part of the Coxeter [p,q] reflection
    /// group: traditional Schläfli notation, diagram, and integer p/q steppers.
    /// The common editor supplies the continuous Mirror and Source Angle sliders.
    @ViewBuilder
    private func coxeterEditor(_ op: SpaceWarpOpValue) -> some View {
        let live = liveOp(op.id) ?? op
        let p = max(Int(live.p1.rounded()), 2)
        let q = max(Int(live.p2.rounded()), 2)
        VStack(alignment: .leading, spacing: 10) {
            // Schläfli symbol + the symmetry it names.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("{\(p), \(q)}")
                    .font(.title2.monospacedDigit().weight(.semibold))
                Spacer()
                Text(coxeterSymmetryName(p: p, q: q))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.tint.opacity(0.16)))
                    .foregroundStyle(.tint)
            }
            // Coxeter–Dynkin diagram (rank-3 linear: three mirrors, two labelled edges).
            Text("○—\(p)—○—\(q)—○")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            // Integer mirror orders. Steppers read LIVE (so they actually move) and
            // bump `refresh` so the symbol/diagram above redraw on each tap.
            coxeterStepper(op, label: "p", slot1: true, value: p)
            coxeterStepper(op, label: "q", slot1: false, value: q)
        }
    }

    /// One p/q stepper for the Coxeter editor. Reads the live op so the control
    /// tracks; writes the chosen slot and refreshes the card's symbol + diagram.
    private func coxeterStepper(_ op: SpaceWarpOpValue, label: String, slot1: Bool, value: Int) -> some View {
        Stepper(value: Binding(
            get: { let o = liveOp(op.id) ?? op; return max(Int((slot1 ? o.p1 : o.p2).rounded()), 2) },
            set: { v in update(op.id) { if slot1 { $0.p1 = Float(v) } else { $0.p2 = Float(v) } }; refresh &+= 1 }),
            in: 2...8) {
            HStack {
                Text(label).font(.subheadline.weight(.medium))
                Spacer()
                Text("\(value)").font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
    }

    // MARK: - Space-system cards
    //
    // Rendered only while the system is active. Same card chrome as a stack op but
    // with no index / reorder chevrons (these apply globally, not in stack order) —
    // a "SPACE" badge marks them apart, and the trash button turns the system off.

    /// Global Spherical Inversion (pre-raymarch ray transform). Mode is on/off only
    /// (`.outwardIn`), so the card just exposes the Inversion Radius.
    @ViewBuilder
    private var sphericalInversionCard: some View {
        spaceSystemCard(
            title: "Spherical Inversion",
            icon: AppIcons.circleDashedInsetFilled,
            tagline: "Turn space inside-out through a sphere — global ray warp",
            remove: {
                cache.display.sphericalInversionMode = .off
                cache.commitSphericalInversion()
                refresh &+= 1
            }
        ) {
            EffectSliderRow(icon: "circle", label: "Inversion Radius",
                value: Binding(get: { cache.display.sphericalInversionRadius },
                               set: { cache.display.sphericalInversionRadius = $0 }),
                range: ControlCatalog.sphericalInversionRadius.range,
                enabled: .constant(true),
                onChanged: { cache.commitSphericalInversion() },
                showToggle: false)
        }
    }

    /// Sphere Projection (radial domain warp; capability-gated on `.sphereProjection`).
    /// Blend + radius are music-drivable (ghost markers via `musicTargetID`).
    @ViewBuilder
    private var sphereProjectionCard: some View {
        spaceSystemCard(
            title: "Sphere Projection",
            icon: AppIcons.globeAsiaAustralia,
            tagline: "Pull this shape's detail onto a spherical shell — domain warp",
            remove: {
                cache.display.sphereProjectionEnabled = false
                cache.commitSphereProjection()
                refresh &+= 1
            }
        ) {
            EffectSliderRow(icon: "circle.lefthalf.filled", label: "Projection",
                value: Binding(get: { cache.display.sphereProjectionBlend },
                               set: { cache.display.sphereProjectionBlend = $0 }),
                range: ControlCatalog.sphereProjectionBlend.range,
                enabled: .constant(true),
                onChanged: { cache.commitSphereProjection() },
                showToggle: false,
                musicTargetID: ParameterTargetID.Space.sphereProjectionBlend)
            EffectSliderRow(icon: "circle", label: "Projection Radius",
                value: Binding(get: { cache.display.sphereProjectionRadius },
                               set: { cache.display.sphereProjectionRadius = $0 }),
                range: ControlCatalog.sphereProjectionRadius.range,
                enabled: .constant(true),
                onChanged: { cache.commitSphereProjection() },
                showToggle: false,
                musicTargetID: ParameterTargetID.Space.sphereProjectionRadius)
        }
    }

    /// Shared chrome for a space-system card: header (name / tagline / "SPACE" badge /
    /// remove) over the system's own sliders.
    @ViewBuilder
    private func spaceSystemCard<Content: View>(
        title: String, icon: String, tagline: String,
        remove: @escaping () -> Void,
        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    spaceSystemHeaderIdentity(title: title, icon: icon, tagline: tagline)
                    Spacer(minLength: 4)
                    spaceSystemHeaderActions(title: title, remove: remove)
                }
                VStack(alignment: .leading, spacing: 5) {
                    spaceSystemHeaderIdentity(title: title, icon: icon, tagline: tagline)
                    HStack(spacing: 8) {
                        Spacer()
                        spaceSystemHeaderActions(title: title, remove: remove)
                    }
                }
            }
            .font(.caption)

            content()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.teal.opacity(0.08)))
    }

    @ViewBuilder
    private func spaceSystemHeaderIdentity(title: String, icon: String,
                                           tagline: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.medium))
            Text(tagline)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .layoutPriority(1)
    }

    @ViewBuilder
    private func spaceSystemHeaderActions(title: String,
                                          remove: @escaping () -> Void) -> some View {
        Text("SPACE")
            .font(.caption2.weight(.heavy))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(.teal.opacity(0.20)))
            .foregroundStyle(.teal)
            .accessibilityLabel("Global space system")
        Button(role: .destructive) { remove() } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .transformationActionHitTarget()
        .accessibilityLabel("Remove \(title)")
    }

    // MARK: - Mutations

    /// Turn a standalone space system on (its card then appears above the stack).
    /// Adding an already-active system is a no-op; Sphere Projection is gated by
    /// fractal capability.
    private func addSpaceSystem(_ system: SpaceSystem) {
        switch system {
        case .sphericalInversion:
            guard !sphericalInversionActive else { return }
            cache.display.sphericalInversionMode = .outwardIn
            cache.commitSphericalInversion()
        case .sphereProjection:
            guard !sphereProjectionActive,
                  cache.fractalType.supports(.sphereProjection) else { return }
            cache.display.sphereProjectionEnabled = true
            cache.commitSphereProjection()
        }
        refresh &+= 1
    }

    private func add(_ kind: SpaceWarpKind,
                     mappedIDs: Set<Int32>? = nil) {
        var arr = cache.spaceWarpStack
        let effectiveMappedIDs = mappedIDs ?? mappedTransformationIDs
        guard TransformationAccessPolicy.canAdd(
            kind,
            mode: experienceMode,
            mappedIDs: effectiveMappedIDs
        ), arr.count < Int(kMaxSpaceWarpOps) else { return }
        let operation = SpaceWarpOpValue(kind: kind)
        arr.append(operation)
        cache.replaceSpaceWarpStack(arr)
        expandedOperationIDs = [operation.id]
        refresh &+= 1
    }

    private func delete(_ id: UUID) {
        var arr = cache.spaceWarpStack
        arr.removeAll { $0.id == id }
        cache.replaceSpaceWarpStack(arr)
        groupSelection.remove(id)
        expandedOperationIDs.remove(id)
        expandedTechnicalDetailIDs.remove(id)
        refresh &+= 1
    }

    private func deleteGroup(_ groupID: UUID) {
        var arr = cache.spaceWarpStack
        let removedIDs = Set(arr.lazy.filter { $0.groupID == groupID }.map(\.id))
        arr.removeAll { $0.groupID == groupID }
        cache.replaceSpaceWarpStack(arr)
        expandedOperationIDs.subtract(removedIDs)
        expandedTechnicalDetailIDs.subtract(removedIDs)
        expandedGroups.remove(groupID)
        refresh &+= 1
    }

    private func move(_ id: UUID, by delta: Int) {
        var arr = cache.spaceWarpStack
        guard let i = arr.firstIndex(where: { $0.id == id }) else { return }
        let current = unitRange(containing: i, in: arr)
        guard current.allSatisfy({ isOpRevealed(arr[$0]) }) else { return }
        if delta < 0 {
            guard current.lowerBound > 0 else { return }
            let previous = unitRange(containing: current.lowerBound - 1, in: arr)
            guard previous.allSatisfy({ isOpRevealed(arr[$0]) }) else { return }
            arr = Array(arr[..<previous.lowerBound])
                + Array(arr[current])
                + Array(arr[previous])
                + Array(arr[current.upperBound...])
        } else {
            guard current.upperBound < arr.count else { return }
            let next = unitRange(containing: current.upperBound, in: arr)
            guard next.allSatisfy({ isOpRevealed(arr[$0]) }) else { return }
            arr = Array(arr[..<current.lowerBound])
                + Array(arr[next])
                + Array(arr[current])
                + Array(arr[next.upperBound...])
        }
        cache.replaceSpaceWarpStack(arr)
        refresh &+= 1
    }

    private func moveTransform(_ id: UUID, by delta: Int, insideGroup: Bool) {
        guard canMoveTransform(id, by: delta, insideGroup: insideGroup) else { return }
        if insideGroup {
            moveWithinGroup(id, by: delta)
        } else {
            move(id, by: delta)
        }
    }

    private func moveWithinGroup(_ id: UUID, by delta: Int) {
        var arr = cache.spaceWarpStack
        guard let index = arr.firstIndex(where: { $0.id == id }),
              let groupID = arr[index].groupID,
              isOpRevealed(arr[index]) else { return }
        let destination = index + delta
        guard arr.indices.contains(destination),
              arr[destination].groupID == groupID,
              isOpRevealed(arr[destination]) else { return }
        arr.swapAt(index, destination)
        cache.replaceSpaceWarpStack(arr)
        refresh &+= 1
    }

    private func canMoveTransform(_ id: UUID, by delta: Int,
                                  insideGroup: Bool) -> Bool {
        let arr = cache.spaceWarpStack
        guard let index = arr.firstIndex(where: { $0.id == id }),
              isOpRevealed(arr[index]) else { return false }

        if insideGroup {
            guard let groupID = arr[index].groupID else { return false }
            let destination = index + delta
            return arr.indices.contains(destination)
                && arr[destination].groupID == groupID
                && isOpRevealed(arr[destination])
        }

        let current = unitRange(containing: index, in: arr)
        let neighbor: Range<Int>
        if delta < 0 {
            guard current.lowerBound > 0 else { return false }
            neighbor = unitRange(containing: current.lowerBound - 1, in: arr)
        } else {
            guard current.upperBound < arr.count else { return false }
            neighbor = unitRange(containing: current.upperBound, in: arr)
        }
        return current.allSatisfy { isOpRevealed(arr[$0]) }
            && neighbor.allSatisfy { isOpRevealed(arr[$0]) }
    }

    private var selectedGroupIndices: [Int] {
        ops.indices.filter { groupSelection.contains(ops[$0].id) }
    }

    private var canCreateSelectedGroup: Bool {
        let indices = selectedGroupIndices
        guard indices.count >= 2,
              indices.allSatisfy({ ops[$0].groupID == nil }),
              indices.allSatisfy({ isOpRevealed(ops[$0]) }),
              let first = indices.first,
              let last = indices.last else { return false }
        return last - first + 1 == indices.count
    }

    private func beginGroupCreation() {
        guard ops.filter({
            $0.groupID == nil && isOpRevealed($0)
        }).count >= 2 else { return }
        groupSelection.removeAll()
        isCreatingGroup = true
    }

    private func cancelGroupCreation() {
        groupSelection.removeAll()
        isCreatingGroup = false
    }

    private func toggleGroupSelection(_ id: UUID) {
        guard let op = ops.first(where: { $0.id == id }),
              isOpRevealed(op) else { return }
        if groupSelection.contains(id) {
            groupSelection.remove(id)
        } else {
            groupSelection.insert(id)
        }
        refresh &+= 1
    }

    private func createSelectedGroup() {
        guard canCreateSelectedGroup else { return }
        var arr = cache.spaceWarpStack
        let groupID = UUID()
        for index in selectedGroupIndices {
            arr[index].groupID = groupID
            arr[index].groupIterations = 1
            arr[index].groupMode = .repeatOutput
        }
        cache.replaceSpaceWarpStack(arr)
        groupSelection.removeAll()
        isCreatingGroup = false
        refresh &+= 1
    }

    private func ungroup(_ groupID: UUID) {
        var arr = cache.spaceWarpStack
        let members = arr.filter { $0.groupID == groupID }
        guard !members.isEmpty,
              members.allSatisfy(isOpRevealed) else { return }
        for index in arr.indices where arr[index].groupID == groupID {
            arr[index].groupID = nil
            arr[index].groupIterations = nil
            arr[index].groupMode = nil
        }
        cache.replaceSpaceWarpStack(arr)
        refresh &+= 1
    }

    private func updateGroupIterations(_ groupID: UUID, iterations: Int) {
        var arr = cache.spaceWarpStack
        let members = arr.filter { $0.groupID == groupID }
        guard !members.isEmpty,
              members.allSatisfy(isOpRevealed) else { return }
        let clamped = min(max(iterations, 1), Int(kMaxSpaceWarpGroupIterations))
        for index in arr.indices where arr[index].groupID == groupID {
            arr[index].groupIterations = clamped
        }
        cache.replaceSpaceWarpStack(arr)
        refresh &+= 1
    }

    /// One reorderable unit is either an ungrouped op or a whole contiguous group.
    private func unitRange(containing index: Int, in stack: [SpaceWarpOpValue]) -> Range<Int> {
        guard stack.indices.contains(index), let groupID = stack[index].groupID else {
            return index..<(index + 1)
        }
        var lower = index
        var upper = index + 1
        while lower > 0 && stack[lower - 1].groupID == groupID { lower -= 1 }
        while upper < stack.count && stack[upper].groupID == groupID { upper += 1 }
        return lower..<upper
    }

    /// Read-modify-write one op by id (slider drags). No `refresh` bump so the
    /// drag stays smooth — the binding reads the stored value back directly.
    private func update(_ id: UUID, _ mutate: (inout SpaceWarpOpValue) -> Void) {
        guard let op = cache.spaceWarpStack.first(where: { $0.id == id }),
              isOpRevealed(op) else { return }
        cache.updateSpaceWarpOp(id: id, mutate)
    }

    /// LIVE lookup of an op by id. Every slider/stepper binding's `get` MUST read
    /// through this, not the captured ForEach snapshot — otherwise the control
    /// freezes at the snapshot value (RenderSettings isn't Observable, so a `set`
    /// never re-snapshots the closure). A captured `strength` default of 1.0 in a
    /// 0…2 range is exactly mid-track, which read as a thumb "stuck in the centre".
    private func liveOp(_ id: UUID) -> SpaceWarpOpValue? {
        cache.spaceWarpStack.first { $0.id == id }
    }

    /// Enabled music mappings driving any field of this stack slot — drives the ♪
    /// badge so a music link set in the Music tab is visible right here on the card.
    /// Slot index == the model stack index the audio offset folds into.
    private func musicMappings(forSlot index: Int) -> [MusicReactiveMapping] {
        renderSettings.musicReactiveMappings.filter {
            $0.isEnabled && $0.target.spaceWarpSlot == index
        }
    }
}

/// Native mathematical typography shared by macOS, iPadOS, and visionOS. The
/// lesson catalog is authored with Unicode math symbols, so this provides the
/// visual role people expect from rendered LaTeX without a WebView, JavaScript,
/// network dependency, or a platform-specific math renderer.
private struct TransformationMathEquationView: View {
    let notation: String
    let spokenNotation: String
    @ScaledMetric(relativeTo: .title3) private var equationSize: CGFloat = 22

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(notation)
                .font(.system(size: equationSize, weight: .medium, design: .serif))
                .kerning(0.2)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.vertical, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenNotation)
    }
}

private extension View {
    @ViewBuilder
    func transformationActionHitTarget() -> some View {
        #if os(macOS)
        self
        #else
        frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        #endif
    }
}

/// Pulls the EXACT Metal source of a `warp…` function out of the embedded shader,
/// so the panel can show users what a transform really runs on the GPU. Returns nil
/// if the function isn't found (the UI then shows just the readable formula).
enum WarpSource {
    // Scanning the ~247 KB embedded shader string char-by-char is expensive, and this
    // is called from the Transform op-card bodies — inside an `if let` in a
    // DisclosureGroup's ViewBuilder, so it runs for EVERY card each time that card is
    // laid out during scroll, even while the disclosure is collapsed. That per-card,
    // per-scroll scan was the Transform tab's scroll stall. Memoize by function name:
    // the embedded source is constant, so each function is scanned at most once.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String?] = [:]

    static func metalFunction(named fn: String) -> String? {
        cacheLock.lock()
        let cached = cache[fn]
        cacheLock.unlock()
        if let cached { return cached }   // present in the dict; the value itself may be nil

        let result = scan(named: fn)

        cacheLock.lock()
        cache[fn] = result
        cacheLock.unlock()
        return result
    }

    private static func scan(named fn: String) -> String? {
        let src = EmbeddedMetalSources.shadersMetal
        // Warp kernels have different arities (the Mandelbox step also receives
        // p0; its DE update receives derivative state), so locate the authored
        // definition by name rather than assuming the common two-argument shape.
        // Definitions precede every call site in the embedded shader source.
        guard let sig = src.range(of: "\(fn)(") else { return nil }
        // Back up to the start of the declaration line (the FORCE_INLINE return type).
        let lineStart = src[..<sig.lowerBound].lastIndex(of: "\n").map { src.index(after: $0) } ?? src.startIndex
        // First "{" after the signature, then balance braces to the matching "}".
        guard let open = src.range(of: "{", range: sig.upperBound..<src.endIndex) else { return nil }
        var depth = 0
        var i = open.lowerBound
        var end = src.endIndex
        while i < src.endIndex {
            let c = src[i]
            if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { end = src.index(after: i); break } }
            i = src.index(after: i)
        }
        return String(src[lineStart..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
