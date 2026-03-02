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
        if let desc = descriptor, !parameterBatch.nodes.isEmpty {
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

    /// When true, shows the sensitivity slider instead of the parameter slider.
    @State private var isFlipped: Bool = false
    /// Local copy of this parameter's gesture sensitivity for the slider binding.
    @State private var sensitivityValue: Float = GestureSensitivityStore.defaultSensitivity

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
                                smoothing: .init()
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
            ZStack {
                // ── FRONT: Normal parameter slider ──
                if !isFlipped {
                    frontFace(floatNode: floatNode)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }

                // ── BACK: Gesture sensitivity slider ──
                if isFlipped {
                    backFace(floatNode: floatNode)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: isFlipped)
            .onAppear {
                sensitivityValue = GestureSensitivityStore.shared.sensitivity(for: floatNode.id)
            }
        }
    }

    // MARK: - Front Face (Parameter Slider)

    @ViewBuilder
    private func frontFace(floatNode: FloatParameterNode) -> some View {
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
                                smoothing: .init()
                            )
                        )
                    }
                ),
                range: floatNode.range,
                enabled: .constant(true),
                onChanged: {},
                showToggle: false
            )

            if floatNode.isGestureMappable {
                if let formulaBinding = floatGestureBinding {
                    Menu {
                        ForEach(FingerPair.allCases, id: \.self) { pair in
                            Button {
                                cache.setFingerBinding(formulaBinding, for: pair)
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

                // Flip to sensitivity
                Button {
                    isFlipped = true
                } label: {
                    Image(systemName: sensitivityIsCustom ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.50percent")
                        .font(.caption)
                        .foregroundStyle(sensitivityIsCustom ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                        .frame(width: 20)
                }
                .buttonStyle(.borderless)
                .help("Adjust gesture sensitivity")
            }
        }
    }

    // MARK: - Back Face (Sensitivity Slider)

    @ViewBuilder
    private func backFace(floatNode: FloatParameterNode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(width: 16)

            Text("Sensitivity")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .frame(width: 80, alignment: .leading)
                .lineLimit(1)

            Slider(value: $sensitivityValue,
                   in: GestureSensitivityStore.range.lowerBound...GestureSensitivityStore.range.upperBound)
                .tint(.orange)
                .onChange(of: sensitivityValue) { _, newVal in
                    GestureSensitivityStore.shared.setSensitivity(newVal, for: floatNode.id)
                }

            Text(String(format: "%.1fx", sensitivityValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36)

            // Reset sensitivity to default
            Button {
                sensitivityValue = GestureSensitivityStore.defaultSensitivity
                GestureSensitivityStore.shared.resetSensitivity(for: floatNode.id)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            .buttonStyle(.borderless)
            .help("Reset sensitivity to default")

            // Flip back to parameter
            Button {
                isFlipped = false
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            .buttonStyle(.borderless)
            .help("Back to parameter")
        }
        .frame(height: 32)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.06))
        )
    }

    // MARK: - Helpers

    private var sensitivityIsCustom: Bool {
        abs(GestureSensitivityStore.shared.sensitivity(for: node.id)
            - GestureSensitivityStore.defaultSensitivity) > 0.01
    }

    private var floatGestureBinding: GestureActionBinding? {
        guard let floatNode = node as? FloatParameterNode else { return nil }
        let pieces = floatNode.id.split(separator: ".")
        guard pieces.count >= 3, let index = Int(pieces[2]) else { return nil }
        return .parameter(GestureBindableParameter(
            fractalType: cache.fractalType,
            parameterNodeID: floatNode.id,
            formulaIndex: index,
            display: GestureDisplayMetadata(title: floatNode.name, subtitle: floatNode.group?.title, icon: floatNode.icon)
        ))
    }

    private var currentGestureAssignment: FingerPair? {
        guard let binding = floatGestureBinding else { return nil }
        return cache.fingerPair(for: binding)
    }

    private func clearGestureMapping() {
        guard let pair = currentGestureAssignment else { return }
        cache.setFingerBinding(.core(.none), for: pair)
    }
}
