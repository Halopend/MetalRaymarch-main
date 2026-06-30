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

    // RenderSettings is not Observable; bump to force a re-read of the op LIST after
    // structural edits (add / delete / reorder / enable). Slider drags mutate in
    // place and don't need it (mirrors TwistShapingSection). No edit recompiles a
    // shader — the runtime loop reads the per-frame-repacked uniforms (count + ops).
    @State private var refresh: Int = 0

    private var ops: [SpaceWarpOpValue] { renderSettings.spaceWarpStack }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Transformations", systemImage: "circle.hexagongrid")
                    .font(.headline)
                Spacer()
                addMenu
            }

            Text("Stack domain transforms applied (top → bottom) before the fractal is drawn. Reorder to change the result; add multiples of the same kind to compound them.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if ops.isEmpty {
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
            ForEach(SpaceWarpKind.allCases) { kind in
                Button { add(kind) } label: { Label(kind.displayName, systemImage: kind.icon) }
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
                Label(kind.displayName, systemImage: kind.icon)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { op.isEnabled },
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
                    value: Binding(get: { op.strength }, set: { v in update(op.id) { $0.strength = v } }),
                    range: kind.strengthRange,
                    enabled: .constant(true), onChanged: {}, showToggle: false)

                // Per-operator scalars.
                ForEach(kind.params) { spec in
                    EffectSliderRow(
                        icon: spec.icon, label: spec.label,
                        value: Binding(
                            get: { spec.slot == 1 ? op.p1 : op.p2 },
                            set: { v in update(op.id) { if spec.slot == 1 { $0.p1 = v } else { $0.p2 = v } } }),
                        range: spec.range,
                        enabled: .constant(true), onChanged: {}, showToggle: false)
                }

                // Per-transform boolean option (e.g. Box Fold "Hall of Mirrors"),
                // stored in op.p2 — a live uniform value, no recompile.
                if let toggle = kind.toggle {
                    HStack(spacing: 8) {
                        Label(toggle.label, systemImage: toggle.icon)
                            .font(.caption)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { op.p2 > 0.5 },
                            set: { v in update(op.id) { $0.p2 = v ? 1 : 0 }; refresh &+= 1 }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                }

                // Direction axis (Twist / Bend / Ripple).
                if kind.usesAxis {
                    axisRow(op, "Axis X", "arrow.left.and.right", \.x)
                    axisRow(op, "Axis Y", "arrow.up.and.down", \.y)
                    axisRow(op, "Axis Z", "arrow.up.left.and.arrow.down.right", \.z)
                }
                }
            }
            .opacity(op.isEnabled ? 1.0 : 0.4)
            .disabled(!op.isEnabled)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func axisRow(_ op: SpaceWarpOpValue, _ label: String, _ icon: String,
                         _ comp: WritableKeyPath<SIMD3<Float>, Float>) -> some View {
        EffectSliderRow(
            icon: icon, label: label,
            value: Binding(
                get: { op.axis[keyPath: comp] },
                set: { v in update(op.id) { $0.axis[keyPath: comp] = v } }),
            range: -1.0...1.0,
            enabled: .constant(true), onChanged: {}, showToggle: false)
    }

    /// Dedicated editor for the Coxeter [p,q] reflection group: traditional Schläfli
    /// notation + Coxeter diagram + integer p/q steppers. No blend "amount" — a
    /// reflection group is discrete (enable/disable is the on/off), and p, q are
    /// integers (mirror angles π/p, π/q), not continuous sliders.
    @ViewBuilder
    private func coxeterEditor(_ op: SpaceWarpOpValue) -> some View {
        let p = max(Int(op.p1.rounded()), 2)
        let q = max(Int(op.p2.rounded()), 2)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("{\(p),\(q)}")
                    .font(.title3.monospacedDigit().weight(.semibold))
                Text("○—\(p)—○—\(q)—○")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(coxeterSymmetryName(p: p, q: q))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tint)
            }
            Stepper(value: Binding(
                get: { max(Int(op.p1.rounded()), 2) },
                set: { v in update(op.id) { $0.p1 = Float(v) }; refresh &+= 1 }), in: 2...8) {
                HStack { Text("p"); Spacer(); Text("\(p)").foregroundStyle(.secondary).monospacedDigit() }
                    .font(.caption)
            }
            Stepper(value: Binding(
                get: { max(Int(op.p2.rounded()), 2) },
                set: { v in update(op.id) { $0.p2 = Float(v) }; refresh &+= 1 }), in: 2...8) {
                HStack { Text("q"); Spacer(); Text("\(q)").foregroundStyle(.secondary).monospacedDigit() }
                    .font(.caption)
            }
        }
    }

    // MARK: - Mutations

    private func add(_ kind: SpaceWarpKind) {
        var arr = renderSettings.spaceWarpStack
        guard arr.count < Int(kMaxSpaceWarpOps) else { return }
        arr.append(SpaceWarpOpValue(kind: kind))
        renderSettings.spaceWarpStack = arr
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
}
