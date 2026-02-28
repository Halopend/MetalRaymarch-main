import SwiftUI

struct FormulaParamsEditor: View {
    @Bindable var cache: UISettingsCache

    private var descriptor: FormulaDescriptor? {
        FormulaCatalog.shared.descriptor(for: cache.fractalType)
    }

    private var parameterBatch: ParameterNodeBatch {
        ParameterNodeRegistry.shared.formulaBatch(for: cache.fractalType)
    }

    var body: some View {
        if let desc = descriptor, !(desc.usesMandelboxParams ?? false), !parameterBatch.nodes.isEmpty {
            VStack(spacing: 4) {
                HStack {
                    Label("\(desc.name) Parameters", systemImage: cache.fractalType.icon)
                        .font(.headline)
                    Spacer()
                    Button { cache.resetFormulaParams() } label: {
                        Image(systemName: "arrow.counterclockwise").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to defaults")
                }
                .padding(.bottom, 4)

                Text(desc.description)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)

                ForEach(Array(parameterBatch.nodes.enumerated()), id: \.element.id) { idx, node in
                    if idx > 0 { Divider().padding(.leading, 159) }
                    ParameterNodeRow(cache: cache, node: node)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.06)))
        }
    }
}

private struct ParameterNodeRow: View {
    private var operationFrameIndex: UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
    @Bindable var cache: UISettingsCache
    let node: AnyParameterNodeBase

    var body: some View {
        if let boolNode = node as? BoolParameterNode {
            HStack(spacing: 8) {
                Image(systemName: boolNode.icon).font(.caption).frame(width: 16)
                Text(boolNode.name)
                    .font(.subheadline)
                    .frame(width: 135, alignment: .leading)
                    .lineLimit(1)
                Spacer()
                Toggle("", isOn: Binding<Bool>(
                    get: { boolNode.readValue(cache) },
                    set: { value in
                        cache.dispatchParameterOperation(
                            ParameterOperation(
                                targetID: boolNode.id,
                                source: .slider,
                                value: .absolute(value ? 1 : 0),
                                frameIndex: operationFrameIndex,
                                smoothing: .init(easing: "ui")
                            )
                        )
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            .frame(height: 32)
        }

        if let floatNode = node as? FloatParameterNode {
            HStack(spacing: 4) {
                EffectSliderRow(
                    icon: floatNode.icon,
                    label: floatNode.name,
                    value: Binding<Float>(
                        get: { floatNode.readValue(cache) },
                        set: { value in
                            cache.dispatchParameterOperation(
                                ParameterOperation(
                                    targetID: floatNode.id,
                                    source: .slider,
                                    value: .absolute(value),
                                    frameIndex: operationFrameIndex,
                                    smoothing: .init(easing: "ui")
                                )
                            )
                        }
                    ),
                    range: floatNode.range,
                    enabled: .constant(true),
                    onChanged: {},
                    showToggle: false
                )

                if floatNode.isGestureMappable, let formulaSlot = floatGestureSlot {
                    Menu {
                        ForEach(FingerPair.allCases, id: \.self) { pair in
                            Button {
                                cache.setFingerAction(formulaSlot, for: pair)
                            } label: {
                                Label(pair.displayName, systemImage: pair.icon)
                            }
                        }
                        if currentGestureAssignment != nil {
                            Divider()
                            Button("Clear Gesture") { clearGestureMapping() }
                        }
                    } label: {
                        Image(systemName: currentGestureAssignment?.icon ?? "hand.point.up.left.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                    }
                    .help("Assign hand gesture")
                }
            }
        }
    }

    private var floatGestureSlot: FingerGestureAction? {
        guard let floatNode = node as? FloatParameterNode else { return nil }
        let pieces = floatNode.id.split(separator: ".")
        guard pieces.count >= 3, let index = Int(pieces[2]) else { return nil }
        return FingerGestureAction(rawValue: Int32(100 + index))
    }

    private var currentGestureAssignment: FingerPair? {
        guard let slot = floatGestureSlot else { return nil }
        return cache.fingerPair(for: slot)
    }

    private func clearGestureMapping() {
        guard let pair = currentGestureAssignment else { return }
        cache.setFingerAction(.none, for: pair)
    }
}
