//
//  PrimitivesSection.swift
//  Threshold
//
//  Dedicated analytic-solid library. Primitive selection changes the base
//  distance estimator while deliberately preserving the composable Transform
//  stack that is edited in TransformationsSection.
//

import SwiftUI

struct PrimitivesSection: View {
    let cache: ControlStateStore

    private var selectedPrimitive: FractalPrimitiveKind? {
        guard cache.fractalType == .constructionPrimitive else { return nil }
        // rawSelector: scene files carry slot 0 unclamped; a plain Int(Float)
        // here traps on a corrupt/hand-edited file the moment this section opens.
        return FractalPrimitiveKind(
            rawSelector: FormulaCatalog.getParam(cache.formulaParams, index: 0)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Primitives", systemImage: "cube.transparent")
                    .font(.headline)
                Text("Choose an analytic base solid, tune its dimensions, then shape it further in Transform. Your transformation stack is preserved when you switch primitives.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 145), spacing: 8)],
                spacing: 8
            ) {
                ForEach(FractalPrimitiveKind.analyticCases) { primitive in
                    primitiveCard(primitive)
                }
            }

            if let selectedPrimitive {
                dimensionsEditor(for: selectedPrimitive)
            } else {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "cursorarrow.click.2")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Choose a primitive to begin")
                            .font(.subheadline.weight(.semibold))
                        Text("This replaces the active formula with an analytic solid; it does not clear Transform, color, lighting, or animation settings.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Construction Seeds", systemImage: "repeat.circle")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("SPECIALIZED")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                }

                Text("Seeds are terminal shapes intended for a particular transformation recipe.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                primitiveCard(.mandelboxSeed)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.06)))
    }

    private func primitiveCard(_ primitive: FractalPrimitiveKind) -> some View {
        let isSelected = selectedPrimitive == primitive

        return Button {
            cache.pushConstructionPrimitive(primitive)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: primitive.icon)
                    .font(.title3)
                    .frame(width: 24, height: 24)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(primitive.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(primitive.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 9).fill(
                    isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.045)
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9).stroke(
                    isSelected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Primitive: \(primitive.name)")
        .accessibilityHint(primitive.summary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func dimensionsEditor(for primitive: FractalPrimitiveKind) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("\(primitive.name) Dimensions", systemImage: "ruler")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    cache.pushConstructionPrimitive(primitive)
                } label: {
                    Label("Reset", systemImage: AppIcons.arrowCounterclockwise)
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reset \(primitive.name.lowercased()) dimensions")
            }

            ForEach(primitive.dimensions) { dimension in
                EffectSliderRow(
                    icon: dimension.icon,
                    label: dimension.name,
                    value: dimensionBinding(dimension),
                    range: dimension.range,
                    enabled: .constant(true),
                    onChanged: {},
                    showToggle: false,
                    valueFormat: { String(format: "%.2f", $0) }
                )
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
        )
    }

    private func dimensionBinding(_ dimension: FractalPrimitiveKind.Dimension) -> Binding<Float> {
        Binding(
            get: { FormulaCatalog.getParam(cache.formulaParams, index: dimension.index) },
            set: { newValue in
                guard cache.fractalType == .constructionPrimitive,
                      let node = ParameterNodeRegistry.shared.node(
                        for: .constructionPrimitive,
                        formulaIndex: dimension.index
                      ) else { return }

                cache.dispatchParameterOperation(ParameterOperation(
                    targetID: node.id,
                    source: .slider,
                    value: min(max(newValue, dimension.range.lowerBound), dimension.range.upperBound),
                    frameIndex: UInt64(Date().timeIntervalSince1970 * 1_000)
                ))
            }
        )
    }
}
