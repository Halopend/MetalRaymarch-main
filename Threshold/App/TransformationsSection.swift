//
//  TransformationsSection.swift
//  Threshold
//
//  Editor for the composable domain-transform STACK (`RenderSettings.spaceWarpStack`).
//  Add transforms, group a contiguous series into an iterated loop, reorder them
//  (order = order of application), enable/disable, and tune each instance's own
//  parameters. Multiple of the SAME kind can be stacked. EVERY edit — structural
//  or slider —
//  is a live uniform write: the GPU renders the stack via a count-driven runtime
//  loop (`spaceWarpStackTransform` in Shaders.metal) repacked each frame by
//  `cSpaceWarpStack`, so nothing ever recompiles a shader. The GPU early-outs to
//  zero cost when the stack is empty. Catalog + model live in SpaceWarpStackModel.swift.
//

import SwiftUI
import simd

struct TransformationsSection: View {
    let renderSettings: RenderSettings
    /// Live UI store. `UISettingsCache` is `@Observable`, so reading its sphere-system
    /// flags in `body` auto-subscribes this view — the system cards below track the
    /// same state the Space tab / quick toggles drive (DisplayConfig, scene-persisted).
    let cache: UISettingsCache
    let gestureController: GestureController?

    // RenderSettings is not Observable; bump to force a re-read of the op LIST after
    // structural edits (add / delete / reorder / enable). Slider drags mutate in
    // place and don't need it (mirrors TwistShapingSection). No edit recompiles a
    // shader — the runtime loop reads the per-frame-repacked uniforms (count + ops).
    @State private var refresh: Int = 0
    @State private var isCreatingGroup = false
    @State private var groupSelection: Set<UUID> = []
    @State private var expandedGroups: Set<UUID> = []

    private var ops: [SpaceWarpOpValue] { renderSettings.spaceWarpStack }

    /// The persisted/GPU stack stays flat, but the editor presents each contiguous
    /// repeat group as a single parent unit containing its child transformations.
    private struct StackUnit: Identifiable {
        let id: UUID
        let range: Range<Int>
        let groupID: UUID?
    }

    private var stackUnits: [StackUnit] {
        var result: [StackUnit] = []
        var index = 0
        while index < ops.count {
            let range = unitRange(containing: index, in: ops)
            let groupID = ops[index].groupID
            result.append(StackUnit(id: groupID ?? ops[index].id, range: range, groupID: groupID))
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
            HStack(spacing: 8) {
                Label("Transformations", systemImage: "circle.hexagongrid")
                    .font(.headline)
                Text("BETA")
                    .font(.caption2.weight(.heavy))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.orange.opacity(0.22)))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Beta feature")
                Spacer()
                groupCreationControls
                addMenu
            }

            Text("Stack domain transforms top → bottom. A group repeats its complete child pipeline for a chosen number of passes; choose and size the base shape in Primitives.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

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
                Text("No transformations yet. Use Add to add one.")
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
            }
        }
        .id(refresh)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.mint.opacity(0.07)))
    }

    @ViewBuilder
    private var groupCreationControls: some View {
        if isCreatingGroup {
            Button("Cancel") { cancelGroupCreation() }
                .font(.caption)
            Button("Create Group") { createSelectedGroup() }
                .font(.caption.weight(.semibold))
                .disabled(!canCreateSelectedGroup)
        } else {
            Button { beginGroupCreation() } label: {
                Label("Group", systemImage: "rectangle.inset.filled.and.person.filled")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .disabled(ops.filter { $0.groupID == nil }.count < 2)
            .help("Select adjacent transformations and place them in an iterated group")
        }
    }

    // MARK: - Add menu

    private var addMenu: some View {
        Menu {
            Section("Build a Mandelbox") {
                ForEach(MandelboxConstructionStage.allCases) { stage in
                    Button { apply(stage) } label: {
                        Label(stage.name, systemImage: stage.icon)
                    }
                }
            }
            // Curated starting stacks up top — each REPLACES the current stack.
            Section("Recipes") {
                Button { surprise() } label: { Label("Surprise Me", systemImage: "dice") }
                ForEach(WarpCatalog.recipes) { recipe in
                    Button { apply(recipe) } label: { Label(recipe.name, systemImage: recipe.icon) }
                }
            }
            // Standalone space systems (Spherical Inversion + Sphere Projection) —
            // not stack ops; adding one flips its DisplayConfig flag on.
            Section("Space Systems") {
                Button { addSpaceSystem(.sphericalInversion) } label: {
                    Label("Spherical Inversion", systemImage: AppIcons.circleDashedInsetFilled)
                }
                .disabled(sphericalInversionActive)
                Button { addSpaceSystem(.sphereProjection) } label: {
                    Label("Sphere Projection", systemImage: AppIcons.globeAsiaAustralia)
                }
                .disabled(sphereProjectionActive || !cache.fractalType.supports(.sphereProjection))
            }
            // Individual transforms, grouped by family so the look-alikes cluster.
            ForEach(WarpFamily.allCases, id: \.self) { family in
                Section(family.rawValue) {
                    ForEach(SpaceWarpKind.allCases.filter { $0.family == family }) { kind in
                        Button { add(kind) } label: { Label(kind.displayName, systemImage: kind.icon) }
                    }
                }
            }
        } label: {
            Label("Add", systemImage: "plus.circle.fill")
                .font(.caption.weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - One op card

    @ViewBuilder
    private func opCard(_ op: SpaceWarpOpValue, index: Int, isFirst: Bool, isLast: Bool,
                        insideGroup: Bool) -> some View {
        let kind = op.kind
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if isCreatingGroup && !insideGroup {
                    Button { toggleGroupSelection(op.id) } label: {
                        Image(systemName: groupSelection.contains(op.id)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(groupSelection.contains(op.id) ? .indigo : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Include \(kind.displayName) in the new group")
                }
                Text("\(index + 1)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Label(kind.displayName, systemImage: kind.icon)
                        .font(.subheadline.weight(.medium))
                    Text(kind.tagline)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // ♪ badge: which field(s) of this slot are music-linked (bind/edit in
                // the Music tab). Shows the first link's field + a count if there's more.
                if let m = musicMappings(forSlot: index).first {
                    let all = musicMappings(forSlot: index)
                    let extra = all.count > 1 ? " +\(all.count - 1)" : ""
                    Label(kind.musicFieldLabel(m.spaceWarpField) + extra, systemImage: "music.note")
                        .font(.caption2.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(.tint.opacity(0.18)))
                        .foregroundStyle(.tint)
                        .help(all.map { "\(kind.musicFieldLabel($0.spaceWarpField)) ← \($0.source.displayName) (\($0.responseCurve.displayName))" }
                            .joined(separator: "\n") + "\nEdit in the Music tab.")
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { liveOp(op.id)?.isEnabled ?? op.isEnabled },
                    set: { v in update(op.id) { $0.isEnabled = v }; refresh &+= 1 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                Button { moveTransform(op.id, by: -1, insideGroup: insideGroup) } label: {
                    Image(systemName: "chevron.up")
                }
                    .buttonStyle(.borderless).disabled(isFirst)
                Button { moveTransform(op.id, by: 1, insideGroup: insideGroup) } label: {
                    Image(systemName: "chevron.down")
                }
                    .buttonStyle(.borderless).disabled(isLast)
                Button(role: .destructive) { delete(op.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            .font(.caption)

            Group {
                if kind == .coxeter {
                    coxeterEditor(op)
                } else {
                // Master amount.
                EffectSliderRow(
                    icon: kind.icon, label: kind.amountLabel,
                    value: Binding(get: { liveOp(op.id)?.strength ?? op.strength },
                                   set: { v in update(op.id) { $0.strength = v } }),
                    range: kind.strengthRange,
                    enabled: .constant(true), onChanged: {}, showToggle: false,
                    valueFormat: { String(format: "%.2f", $0) })

                // Per-operator scalars.
                ForEach(kind.params) { spec in
                    EffectSliderRow(
                        icon: spec.icon, label: spec.label,
                        value: Binding(
                            get: { let o = liveOp(op.id) ?? op; return spec.slot == 1 ? o.p1 : o.p2 },
                            set: { v in update(op.id) { if spec.slot == 1 { $0.p1 = v } else { $0.p2 = v } } }),
                        range: spec.range,
                        enabled: .constant(true), onChanged: {}, showToggle: false,
                        valueFormat: { String(format: "%.2f", $0) })
                }

                // Per-transform boolean option (e.g. Box Fold "Hall of Mirrors"),
                // stored in op.p2 — a live uniform value, no recompile.
                if let toggle = kind.toggle {
                    HStack(spacing: 8) {
                        Label(toggle.label, systemImage: toggle.icon)
                            .font(.caption)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { (liveOp(op.id) ?? op).p2 > 0.5 },
                            set: { v in update(op.id) { $0.p2 = v ? 1 : 0 }; refresh &+= 1 }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                }

                // Direction axis / offset vector (Twist / Bend / Ripple / Plane Fold / Offset Fold).
                if kind.usesAxis {
                    axisRow(op, "\(kind.axisLabel) X", "arrow.left.and.right", \.x)
                    axisRow(op, "\(kind.axisLabel) Y", "arrow.up.and.down", \.y)
                    axisRow(op, "\(kind.axisLabel) Z", "arrow.up.left.and.arrow.down.right", \.z)
                }
                }
            }
            .opacity(op.isEnabled ? 1.0 : 0.4)
            .disabled(!op.isEnabled)

            underTheHood(kind)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            groupSelection.contains(op.id) && !insideGroup
                ? Color.indigo.opacity(0.15) : Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(
            groupSelection.contains(op.id) && !insideGroup
                ? Color.indigo.opacity(0.65) : Color.clear, lineWidth: 1))
    }

    /// An explicit super-group in the editor. Its children remain ordinary
    /// transformations, but move together and repeat as a single ordered unit.
    private func transformationGroupCard(groupID: UUID, range: Range<Int>) -> some View {
        let first = ops[range.lowerBound]
        let fallbackIterations = first.effectiveGroupIterations
        let passes = first.effectiveGroupIterations
        let mode = first.effectiveGroupMode
        let childKinds = range.map { ops[$0].kind }
        let isMandelboxSequence = childKinds == [.boxFold, .sphereFold, .scale]
        let title = mode == .mandelboxRecurrence && isMandelboxSequence
            ? "Mandelbox Recurrence" : "Transformation Group"
        let sequence = childKinds.map(\.displayName).joined(separator: "  →  ")
        let transformWork = range.count * passes
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(title, systemImage: "repeat")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.indigo)
                Text("\(range.count) STEPS")
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
                Spacer()
                Button { move(ops[range.lowerBound].id, by: -1) } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(range.lowerBound == 0)
                Button { move(ops[range.lowerBound].id, by: 1) } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(range.upperBound == ops.count)
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
                .fixedSize()
            }

            Text(sequence)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("Passes")
                    .font(.caption.weight(.semibold))
                Stepper(value: Binding(
                    get: {
                        renderSettings.spaceWarpStack.first(where: { $0.groupID == groupID })?
                            .effectiveGroupIterations ?? fallbackIterations
                    },
                    set: { updateGroupIterations(groupID, iterations: $0) }),
                    in: 1...Int(kMaxSpaceWarpGroupIterations)) {
                    Text("\(renderSettings.spaceWarpStack.first(where: { $0.groupID == groupID })?.effectiveGroupIterations ?? fallbackIterations)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
                .fixedSize()
                .help("Repeat the complete child pipeline this many times")
                Spacer()
                Text("\(transformWork) transform steps / distance sample")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(transformWork > 32 ? .orange : .secondary)
            }

            if mode == .mandelboxRecurrence {
                Text("After each complete pass, the point that entered the group is added back (+p₀). That feedback is what makes this the Mandelbox recurrence.")
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
            }
            .tint(.indigo)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.indigo.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.indigo.opacity(0.45), lineWidth: 1))
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
    private func underTheHood(_ kind: SpaceWarpKind) -> some View {
        let d = kind.descriptor
        DisclosureGroup {
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
        } label: {
            Label("Under the hood — ƒ \(d.gpuApplyFn)", systemImage: "function")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tint)
        }
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

    /// Dedicated editor for the Coxeter [p,q] reflection group: traditional Schläfli
    /// notation + Coxeter diagram + integer p/q steppers. No blend "amount" — a
    /// reflection group is discrete (enable/disable is the on/off), and p, q are
    /// integers (mirror angles π/p, π/q), not continuous sliders.
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
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Label(title, systemImage: icon)
                        .font(.subheadline.weight(.medium))
                    Text(tagline)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("SPACE")
                    .font(.caption2.weight(.heavy))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(.teal.opacity(0.20)))
                    .foregroundStyle(.teal)
                    .accessibilityLabel("Global space system")
                Button(role: .destructive) { remove() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            .font(.caption)

            content()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.teal.opacity(0.08)))
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

    private func add(_ kind: SpaceWarpKind) {
        var arr = renderSettings.spaceWarpStack
        guard arr.count < Int(kMaxSpaceWarpOps) else { return }
        arr.append(SpaceWarpOpValue(kind: kind))
        renderSettings.spaceWarpStack = arr
        refresh &+= 1
    }

    /// Load one pedagogical Mandelbox stage. All stages use the same embedded
    /// terminal-sphere primitive, so a saved `.threshscene` carries its base DE;
    /// only the editable transformation stack changes between stages.
    private func apply(_ stage: MandelboxConstructionStage) {
        renderSettings.spaceWarpStack = Array(stage.stack.prefix(Int(kMaxSpaceWarpOps)))
        cache.pushConstructionPrimitive(.mandelboxSeed, gestureController: gestureController)
        refresh &+= 1
    }

    /// Load a curated recipe — REPLACES the current stack with its ops (capped at
    /// the GPU limit). A starting point to tweak, not a locked preset.
    private func apply(_ recipe: WarpRecipe) {
        renderSettings.spaceWarpStack = Array(recipe.make().prefix(Int(kMaxSpaceWarpOps)))
        refresh &+= 1
    }

    /// Drop a random structure-forming stack.
    private func surprise() {
        renderSettings.spaceWarpStack = Array(WarpCatalog.randomStack().prefix(Int(kMaxSpaceWarpOps)))
        refresh &+= 1
    }

    private func delete(_ id: UUID) {
        var arr = renderSettings.spaceWarpStack
        arr.removeAll { $0.id == id }
        renderSettings.spaceWarpStack = arr
        groupSelection.remove(id)
        refresh &+= 1
    }

    private func deleteGroup(_ groupID: UUID) {
        var arr = renderSettings.spaceWarpStack
        arr.removeAll { $0.groupID == groupID }
        renderSettings.spaceWarpStack = arr
        refresh &+= 1
    }

    private func move(_ id: UUID, by delta: Int) {
        var arr = renderSettings.spaceWarpStack
        guard let i = arr.firstIndex(where: { $0.id == id }) else { return }
        let current = unitRange(containing: i, in: arr)
        if delta < 0 {
            guard current.lowerBound > 0 else { return }
            let previous = unitRange(containing: current.lowerBound - 1, in: arr)
            arr = Array(arr[..<previous.lowerBound])
                + Array(arr[current])
                + Array(arr[previous])
                + Array(arr[current.upperBound...])
        } else {
            guard current.upperBound < arr.count else { return }
            let next = unitRange(containing: current.upperBound, in: arr)
            arr = Array(arr[..<current.lowerBound])
                + Array(arr[next])
                + Array(arr[current])
                + Array(arr[next.upperBound...])
        }
        renderSettings.spaceWarpStack = arr
        refresh &+= 1
    }

    private func moveTransform(_ id: UUID, by delta: Int, insideGroup: Bool) {
        if insideGroup {
            moveWithinGroup(id, by: delta)
        } else {
            move(id, by: delta)
        }
    }

    private func moveWithinGroup(_ id: UUID, by delta: Int) {
        var arr = renderSettings.spaceWarpStack
        guard let index = arr.firstIndex(where: { $0.id == id }),
              let groupID = arr[index].groupID else { return }
        let destination = index + delta
        guard arr.indices.contains(destination), arr[destination].groupID == groupID else { return }
        arr.swapAt(index, destination)
        renderSettings.spaceWarpStack = arr
        refresh &+= 1
    }

    private var selectedGroupIndices: [Int] {
        ops.indices.filter { groupSelection.contains(ops[$0].id) }
    }

    private var canCreateSelectedGroup: Bool {
        let indices = selectedGroupIndices
        guard indices.count >= 2,
              indices.allSatisfy({ ops[$0].groupID == nil }),
              let first = indices.first,
              let last = indices.last else { return false }
        return last - first + 1 == indices.count
    }

    private func beginGroupCreation() {
        groupSelection.removeAll()
        isCreatingGroup = true
    }

    private func cancelGroupCreation() {
        groupSelection.removeAll()
        isCreatingGroup = false
    }

    private func toggleGroupSelection(_ id: UUID) {
        if groupSelection.contains(id) {
            groupSelection.remove(id)
        } else {
            groupSelection.insert(id)
        }
        refresh &+= 1
    }

    private func createSelectedGroup() {
        guard canCreateSelectedGroup else { return }
        var arr = renderSettings.spaceWarpStack
        let groupID = UUID()
        for index in selectedGroupIndices {
            arr[index].groupID = groupID
            arr[index].groupIterations = 1
            arr[index].groupMode = .repeatOutput
        }
        renderSettings.spaceWarpStack = arr
        groupSelection.removeAll()
        isCreatingGroup = false
        refresh &+= 1
    }

    private func ungroup(_ groupID: UUID) {
        var arr = renderSettings.spaceWarpStack
        for index in arr.indices where arr[index].groupID == groupID {
            arr[index].groupID = nil
            arr[index].groupIterations = nil
            arr[index].groupMode = nil
        }
        renderSettings.spaceWarpStack = arr
        refresh &+= 1
    }

    private func updateGroupIterations(_ groupID: UUID, iterations: Int) {
        var arr = renderSettings.spaceWarpStack
        let clamped = min(max(iterations, 1), Int(kMaxSpaceWarpGroupIterations))
        for index in arr.indices where arr[index].groupID == groupID {
            arr[index].groupIterations = clamped
        }
        renderSettings.spaceWarpStack = arr
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
        var arr = renderSettings.spaceWarpStack
        guard let i = arr.firstIndex(where: { $0.id == id }) else { return }
        mutate(&arr[i])
        renderSettings.spaceWarpStack = arr
    }

    /// LIVE lookup of an op by id. Every slider/stepper binding's `get` MUST read
    /// through this, not the captured ForEach snapshot — otherwise the control
    /// freezes at the snapshot value (RenderSettings isn't Observable, so a `set`
    /// never re-snapshots the closure). A captured `strength` default of 1.0 in a
    /// 0…2 range is exactly mid-track, which read as a thumb "stuck in the centre".
    private func liveOp(_ id: UUID) -> SpaceWarpOpValue? {
        renderSettings.spaceWarpStack.first { $0.id == id }
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
        // Locate the definition by its signature: "warpFoo(float3 p, SpaceWarpOp op)".
        guard let sig = src.range(of: "\(fn)(float3 p, SpaceWarpOp op)") else { return nil }
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
