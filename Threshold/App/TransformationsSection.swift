//
//  TransformationsSection.swift
//  Threshold
//
//  Editor for the composable domain-transform STACK (`RenderSettings.spaceWarpStack`).
//  Add any number of transforms (Twist / Bend / folds / inversion / kaleidoscope /
//  ripple), reorder them (order = order of application), enable/disable, and tune
//  each instance's own parameters. Multiple of the SAME kind can be stacked
//  (e.g. two box folds, three sphere folds). EVERY edit — structural or slider —
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

    private var ops: [SpaceWarpOpValue] { renderSettings.spaceWarpStack }

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
                addMenu
            }

            Text("Choose an embedded primitive, then stack domain transforms top → bottom to build a form. Reorder to change the result; add multiples to compound them. The Mandelbox construction stages expose its folds and recurrence one technique at a time.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            // Active space systems first (they aren't part of the reorderable stack).
            if sphericalInversionActive { sphericalInversionCard }
            if sphereProjectionActive { sphereProjectionCard }

            if ops.isEmpty && !sphericalInversionActive && !sphereProjectionActive {
                Text("No transformations yet. Use ✚ to add one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(ops.enumerated()), id: \.element.id) { index, op in
                    opCard(op, index: index, isFirst: index == 0, isLast: index == ops.count - 1)
                }
            }
        }
        .id(refresh)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.mint.opacity(0.07)))
    }

    // MARK: - Add menu

    private var addMenu: some View {
        Menu {
            Section("Primitives") {
                ForEach(FractalPrimitiveKind.allCases) { primitive in
                    Button { select(primitive) } label: {
                        Label(primitive.name, systemImage: primitive.icon)
                    }
                }
            }
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
    private func opCard(_ op: SpaceWarpOpValue, index: Int, isFirst: Bool, isLast: Bool) -> some View {
        let kind = op.kind
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
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
                Button { move(op.id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(isFirst)
                Button { move(op.id, by: 1) } label: { Image(systemName: "chevron.down") }
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
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

    /// Start a new construction from a portable embedded primitive. Clearing the
    /// stack is intentional: a primitive selection is the base of a new form,
    /// while subsequent Add actions layer techniques onto it.
    private func select(_ primitive: FractalPrimitiveKind) {
        renderSettings.spaceWarpStack = []
        cache.pushConstructionPrimitive(primitive, gestureController: gestureController)
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
        refresh &+= 1
    }

    private func move(_ id: UUID, by delta: Int) {
        var arr = renderSettings.spaceWarpStack
        guard let i = arr.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard j >= 0, j < arr.count else { return }
        arr.swapAt(i, j)
        renderSettings.spaceWarpStack = arr
        refresh &+= 1
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
