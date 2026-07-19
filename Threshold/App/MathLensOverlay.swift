//
//  MathLensOverlay.swift
//  Threshold
//
//  A read-only teaching layer over the live renderer. Explanatory rendering stays
//  in SwiftUI so it cannot perturb raymarch state or performance-sensitive Metal
//  pipelines. The concept and cross-reference models are intentionally independent
//  of the view: future depth-aware Metal overlays can consume the same material.
//

import Foundation
import SwiftUI

enum MathLensSettings {
    static let enabledDefaultsKey = "MathLens.isEnabled"
}

/// The three pieces of progressive disclosure shown by Math Lens. `what` gives
/// an intuition, `notice` directs observation, and `formal` names the operation
/// precisely without making notation a prerequisite for using the app.
struct MathLensConcept: Equatable {
    let title: String
    let field: String
    let what: String
    let notice: String
    let formal: String
    let relatedKinds: [SpaceWarpKind]

    static func transform(_ kind: SpaceWarpKind) -> MathLensConcept {
        MathLensConcept(
            title: kind.displayName,
            field: fieldName(for: kind),
            what: sentence(kind.tagline),
            notice: noticeText(for: kind),
            formal: kind.formula,
            relatedKinds: relatedKinds(for: kind)
        )
    }

    static func formula(_ type: FractalModelType) -> MathLensConcept {
        let descriptor = FormulaCatalog.shared.descriptor(for: type)
        return MathLensConcept(
            title: type.displayName,
            field: formulaFieldName(for: type),
            what: sentence(descriptor?.description ?? "The active distance field defines the visible surface."),
            notice: formulaNotice(for: type),
            formal: type.descriptor.primaryEquation() ?? "surface = { p | d(p) = 0 }",
            relatedKinds: relatedKinds(for: type)
        )
    }

    private static func sentence(_ value: String) -> String {
        guard let last = value.last, !".!?".contains(last) else { return value }
        return value + "."
    }

    private static func fieldName(for kind: SpaceWarpKind) -> String {
        switch kind {
        case .mirror, .boxFold, .planeFold, .mengerFold, .offsetFold:
            return "Reflection & folding"
        case .sphereFold, .inversion, .circle, .shells:
            return "Radial geometry"
        case .kaleidoscope, .coxeter, .icosahedralCut:
            return "Symmetry groups"
        case .scaleRepeat, .scale, .mandelboxStep:
            return "Self-similarity"
        case .tiling:
            return "Periodic space"
        case .twist, .bend, .ripple:
            return "Domain deformation"
        }
    }

    private static func noticeText(for kind: SpaceWarpKind) -> String {
        switch kind {
        case .mirror:
            return "Opposite signs become indistinguishable: eight octants collapse into one."
        case .boxFold:
            return "Crossing a fold limit reverses direction while preserving local lengths."
        case .planeFold:
            return "Only points behind the plane move; their signed distance to it changes sign."
        case .mengerFold:
            return "Absolute value removes signs, then coordinate sorting removes permutations."
        case .offsetFold:
            return "Moving the crease breaks origin symmetry while keeping a reflection rule."
        case .sphereFold:
            return "The inner region expands, the middle region scales by radius, and the exterior stays fixed."
        case .inversion:
            return "Pairs of radii trade near and far while their product remains tied to R²."
        case .circle:
            return "The radial fold acts only in the XZ plane, so the untouched Y direction becomes a tube."
        case .shells:
            return "Different radii map to the same repeating band, producing equal-width shells."
        case .scaleRepeat:
            return "Multiplying distance by the scale factor returns the same structure at another size."
        case .kaleidoscope:
            return "Every angular sector is reflected into one fundamental wedge."
        case .coxeter:
            return "Three generating mirrors reduce the scene to one fundamental chamber."
        case .icosahedralCut:
            return "A single chamber generates the full icosahedral symmetry by repeated reflection."
        case .tiling:
            return "Positions separated by a whole cell size become equivalent."
        case .scale:
            return "Placed between folds, scaling makes the next fold recur at a new level of detail."
        case .mandelboxStep:
            return "The output is fed back as the next input while the original point remains the recurrence seed."
        case .twist:
            return "Rotation grows with distance along the axis, turning straight lines into helices."
        case .bend:
            return "Distance along one direction becomes rotation around the bend axis."
        case .ripple:
            return "A sinusoid alternates displacement; frequency controls how often the direction reverses."
        }
    }

    private static func relatedKinds(for kind: SpaceWarpKind) -> [SpaceWarpKind] {
        switch kind {
        case .mirror:          return [.planeFold, .kaleidoscope, .coxeter]
        case .boxFold:         return [.mirror, .sphereFold, .mandelboxStep]
        case .planeFold:       return [.mirror, .coxeter, .icosahedralCut]
        case .mengerFold:      return [.mirror, .scale, .offsetFold]
        case .offsetFold:      return [.planeFold, .mengerFold, .tiling]
        case .sphereFold:      return [.inversion, .circle, .mandelboxStep]
        case .inversion:       return [.sphereFold, .circle, .shells]
        case .circle:          return [.sphereFold, .inversion, .shells]
        case .shells:          return [.circle, .scaleRepeat, .tiling]
        case .scaleRepeat:     return [.scale, .shells, .mandelboxStep]
        case .kaleidoscope:    return [.mirror, .coxeter, .icosahedralCut]
        case .coxeter:         return [.planeFold, .kaleidoscope, .icosahedralCut]
        case .icosahedralCut:  return [.coxeter, .kaleidoscope, .planeFold]
        case .tiling:          return [.offsetFold, .shells, .scaleRepeat]
        case .scale:           return [.scaleRepeat, .mengerFold, .mandelboxStep]
        case .mandelboxStep:   return [.boxFold, .sphereFold, .scale]
        case .twist:           return [.bend, .ripple, .tiling]
        case .bend:            return [.twist, .ripple, .planeFold]
        case .ripple:          return [.twist, .bend, .shells]
        }
    }

    private static func formulaFieldName(for type: FractalModelType) -> String {
        switch type {
        case .mandelbulb, .mandelbulbJulia, .quaternionJulia:
            return "Dynamical systems"
        case .menger, .octahedron, .mengerSphere:
            return "Iterated function systems"
        case .mandelbox, .theliPseudoKleinian, .kleinian, .boxFoldMandelbulb:
            return "Fold dynamics"
        case .constructionPrimitive:
            return "Implicit geometry"
        case .custom:
            return "Custom distance field"
        }
    }

    private static func formulaNotice(for type: FractalModelType) -> String {
        switch type {
        case .mandelbulb, .mandelbulbJulia:
            return "Watch whether the orbit remains bounded or escapes as power and the constant change."
        case .quaternionJulia:
            return "The visible object is a three-dimensional slice through four-dimensional iteration."
        case .menger, .octahedron, .mengerSphere:
            return "Each recurrence folds many regions together, then rescales them into finer copies."
        case .mandelbox, .theliPseudoKleinian, .kleinian, .boxFoldMandelbulb:
            return "Repeated reflections and radial rescaling create structure without a conventional mesh."
        case .constructionPrimitive:
            return "The rendered boundary is the zero level set of an analytic distance function."
        case .custom:
            return "Probe how the custom estimator changes sign and magnitude around its zero level set."
        }
    }

    private static func relatedKinds(for type: FractalModelType) -> [SpaceWarpKind] {
        switch type {
        case .mandelbulb, .mandelbulbJulia:
            return [.mandelboxStep, .scale, .twist]
        case .quaternionJulia:
            return [.mandelboxStep, .scale, .twist]
        case .menger, .octahedron, .mengerSphere:
            return [.mengerFold, .scale, .offsetFold]
        case .mandelbox, .theliPseudoKleinian, .kleinian, .boxFoldMandelbulb:
            return [.boxFold, .sphereFold, .mandelboxStep]
        case .constructionPrimitive:
            return [.tiling, .twist, .bend]
        case .custom:
            return [.tiling, .scale, .ripple]
        }
    }
}

/// Explains function composition in the exact order represented by the live
/// transformation stack. Keeping this pure makes the language testable and lets
/// future inspectors reuse it without depending on SwiftUI.
enum MathLensStackContext {
    static func description(forTransformAt index: Int, in transforms: [SpaceWarpOpValue]) -> String {
        guard transforms.indices.contains(index) else {
            return "The distance formula evaluates the input point directly."
        }

        let current = transforms[index]
        let position = "Step \(index + 1) of \(transforms.count)"
        let route: String
        if transforms.count == 1 {
            route = "maps the input point before the distance formula evaluates it"
        } else if index == 0 {
            route = "maps the input point, then passes it to \(transforms[1].kind.displayName)"
        } else if index == transforms.count - 1 {
            route = "receives \(transforms[index - 1].kind.displayName)'s output, then passes it to the distance formula"
        } else {
            route = "sits between \(transforms[index - 1].kind.displayName) and \(transforms[index + 1].kind.displayName)"
        }

        let groupSuffix: String
        if let iterations = current.groupIterations, iterations > 1 {
            groupSuffix = " Its group feeds output back as input \(iterations) times."
        } else {
            groupSuffix = ""
        }

        return "\(position) \(route). Order matters because g(f(p)) is generally not f(g(p)).\(groupSuffix)"
    }
}

/// A bounded path through the transform-concept graph. Following an already
/// visited node rewinds to it, so reciprocal links backtrack instead of growing
/// cycles forever. With one node per transform kind, maximum depth is naturally
/// bounded by the catalog size.
struct MathLensReferencePath: Equatable {
    private(set) var kinds: [SpaceWarpKind] = []

    var current: SpaceWarpKind? { kinds.last }
    var depth: Int { kinds.count }
    var isEmpty: Bool { kinds.isEmpty }

    func contains(_ kind: SpaceWarpKind) -> Bool {
        kinds.contains(kind)
    }

    mutating func follow(_ kind: SpaceWarpKind) {
        if let existingIndex = kinds.firstIndex(of: kind) {
            rewind(to: existingIndex)
        } else {
            kinds.append(kind)
        }
    }

    mutating func rewind(to index: Int) {
        guard kinds.indices.contains(index) else { return }
        kinds.removeSubrange(kinds.index(after: index)..<kinds.endIndex)
    }

    mutating func goBack() {
        guard !kinds.isEmpty else { return }
        kinds.removeLast()
    }

    mutating func clear() {
        kinds.removeAll(keepingCapacity: true)
    }
}

struct MathLensViewportOverlay: View {
    let appModel: AppModel

    @AppStorage(MathLensSettings.enabledDefaultsKey) private var isEnabled = false
    @State private var selectedTransformIndex = 0
    @State private var isShowingFormula = true
    @State private var referencePath = MathLensReferencePath()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isEnabled {
                TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                    let transforms = appModel.renderSettings.spaceWarpStack.filter(\.isEnabled)
                    let clampedIndex = min(selectedTransformIndex, max(transforms.count - 1, 0))

                    lensCard(
                        transforms: transforms,
                        selectedIndex: isShowingFormula || transforms.isEmpty || !referencePath.isEmpty ? nil : clampedIndex,
                        referencePath: referencePath
                    )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isEnabled.toggle()
                }
            } label: {
                Label(isEnabled ? "Hide Math Lens" : "Math Lens",
                      systemImage: "function")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.cyan.opacity(isEnabled ? 0.65 : 0.28), lineWidth: 1))
                    .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows a live explanation of the active formula and transformation stack")
        }
    }

    @ViewBuilder
    private func lensCard(
        transforms: [SpaceWarpOpValue],
        selectedIndex: Int?,
        referencePath: MathLensReferencePath
    ) -> some View {
        let previewKind = referencePath.current
        let formulaType = appModel.renderSettings.fractalType
        let selected = selectedIndex.flatMap { transforms.indices.contains($0) ? transforms[$0] : nil }
        let displayedKind = previewKind ?? selected?.kind
        let concept = displayedKind.map { MathLensConcept.transform($0) }
            ?? MathLensConcept.formula(formulaType)
        let diagramOperation = selected ?? previewKind.map { SpaceWarpOpValue(kind: $0) }

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text((previewKind == nil ? concept.field : "\(concept.field) · Reference depth \(referencePath.depth)").uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(previewKind == nil ? .cyan : .orange)
                    Text(concept.title)
                        .font(.headline)
                }
                Spacer(minLength: 12)
                if let selectedIndex, !transforms.isEmpty {
                    transformStepper(count: transforms.count, selectedIndex: selectedIndex)
                }
            }

            if !referencePath.isEmpty {
                referencePathBar(referencePath)
            }

            constructionPath(
                formulaType: formulaType,
                transforms: transforms,
                selectedIndex: selectedIndex,
                isFormulaSelected: selectedIndex == nil && previewKind == nil
            )

            MathLensDiagram(kind: displayedKind, operation: diagramOperation)
                .frame(height: 116)
                .accessibilityHidden(true)
            diagramLegend(isFormula: displayedKind == nil)

            VStack(alignment: .leading, spacing: 7) {
                explanationRow("What", text: concept.what)
                explanationRow("Notice", text: concept.notice)
                if let selectedIndex {
                    explanationRow(
                        "Stack",
                        text: MathLensStackContext.description(
                            forTransformAt: selectedIndex,
                            in: transforms
                        )
                    )
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("FORMAL")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(concept.formal)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let selected {
                liveValues(for: selected)
            }

            relatedConcepts(
                concept.relatedKinds,
                transforms: transforms,
                path: referencePath
            )

            Text(footerText(selected: selected, referencePath: referencePath))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
        .frame(width: 390, alignment: .leading)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.cyan.opacity(0.28), lineWidth: 1))
        .shadow(color: .black.opacity(0.36), radius: 18, y: 8)
    }

    private func transformStepper(count: Int, selectedIndex: Int) -> some View {
        HStack(spacing: 4) {
            Button {
                selectedTransformIndex = max(0, selectedIndex - 1)
                isShowingFormula = false
                referencePath.clear()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 28, height: 28)
            }
            .disabled(selectedIndex == 0)

            Text("\(selectedIndex + 1) / \(count)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(minWidth: 38)

            Button {
                selectedTransformIndex = min(count - 1, selectedIndex + 1)
                isShowingFormula = false
                referencePath.clear()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 28, height: 28)
            }
            .disabled(selectedIndex >= count - 1)
        }
        .buttonStyle(.plain)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transformation \(selectedIndex + 1) of \(count)")
    }

    private func constructionPath(
        formulaType: FractalModelType,
        transforms: [SpaceWarpOpValue],
        selectedIndex: Int?,
        isFormulaSelected: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ACTIVE CONSTRUCTION")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    Text("p")
                        .font(.caption.monospaced().weight(.bold))
                        .frame(width: 28, height: 28)
                        .background(Color.orange.opacity(0.22), in: Circle())
                        .accessibilityLabel("Input point")

                    pathArrow

                    ForEach(Array(transforms.enumerated()), id: \.element.id) { index, op in
                        pathButton(
                            title: "\(index + 1) \(op.kind.displayName)",
                            icon: op.kind.icon,
                            isSelected: selectedIndex == index
                        ) {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                selectedTransformIndex = index
                                isShowingFormula = false
                                referencePath.clear()
                            }
                        }
                        pathArrow
                    }

                    pathButton(
                        title: formulaType.displayName,
                        icon: "function",
                        isSelected: isFormulaSelected
                    ) {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isShowingFormula = true
                            referencePath.clear()
                        }
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Active construction path")
    }

    private func referencePathBar(_ path: MathLensReferencePath) -> some View {
        return HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    referencePath.goBack()
                }
            } label: {
                Image(systemName: "chevron.backward")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .background(Color.orange.opacity(0.16), in: Circle())
            .accessibilityLabel("Back one reference")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(path.kinds.enumerated()), id: \.offset) { index, kind in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                referencePath.rewind(to: index)
                            }
                        } label: {
                            Label(kind.displayName, systemImage: kind.icon)
                                .font(.caption2.weight(index == path.depth - 1 ? .bold : .regular))
                                .lineLimit(1)
                                .foregroundStyle(index == path.depth - 1 ? .orange : .secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Rewinds the reference path to this concept")
                    }
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    referencePath.clear()
                }
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Exit reference path")
        }
        .padding(5)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.orange.opacity(0.24), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reference path, depth \(path.depth)")
    }

    private var pathArrow: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private func pathButton(
        title: String,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(minHeight: 30)
                .foregroundStyle(isSelected ? Color.black : Color.primary)
                .background(isSelected ? Color.cyan : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func diagramLegend(isFormula: Bool) -> some View {
        HStack(spacing: 12) {
            legendItem(color: .orange, label: isFormula ? "sample point" : "input")
            legendItem(color: .cyan, label: isFormula ? "equal-distance contour" : "mapped point")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func relatedConcepts(
        _ kinds: [SpaceWarpKind],
        transforms: [SpaceWarpOpValue],
        path: MathLensReferencePath
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("EXPLORE RELATED")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(kinds) { kind in
                        let activeIndex = transforms.firstIndex(where: { $0.kind == kind })
                        let wasVisited = path.contains(kind)
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                if let activeIndex {
                                    selectedTransformIndex = activeIndex
                                    isShowingFormula = false
                                    referencePath.clear()
                                } else {
                                    referencePath.follow(kind)
                                }
                            }
                        } label: {
                            relatedChip(kind, isActive: activeIndex != nil, wasVisited: wasVisited)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(
                            activeIndex != nil
                                ? "Selects this active transformation"
                                : wasVisited
                                    ? "Backtracks the reference path to this concept"
                                    : "Follows this concept without changing the renderer"
                        )
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func relatedChip(_ kind: SpaceWarpKind, isActive: Bool, wasVisited: Bool) -> some View {
        let accent: Color = isActive ? .cyan : wasVisited ? .orange : .secondary
        let detail = isActive
            ? "active · \(MathLensConcept.transform(kind).field)"
            : wasVisited
                ? "backtrack · \(MathLensConcept.transform(kind).field)"
                : MathLensConcept.transform(kind).field

        return HStack(spacing: 6) {
            Image(systemName: kind.icon)
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(accent)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 34)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isActive ? Color.cyan.opacity(0.65) : wasVisited ? Color.orange.opacity(0.55) : Color.clear,
                    lineWidth: 1
                )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(kind.displayName), \(MathLensConcept.transform(kind).field)"
                + (isActive ? ", active in the stack" : wasVisited ? ", already in the reference path" : "")
        )
    }

    private func footerText(selected: SpaceWarpOpValue?, referencePath: MathLensReferencePath) -> String {
        if !referencePath.isEmpty {
            return "Recursive concept depth \(referencePath.depth) · renderer unchanged"
        }
        return selected == nil ? "Live formula · choose a step above" : "Domain schematic · live values"
    }

    private func explanationRow(_ label: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(label == "Notice" ? .orange : .secondary)
                .frame(width: 48, alignment: .leading)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func liveValues(for op: SpaceWarpOpValue) -> some View {
        HStack(spacing: 6) {
            valuePill(op.kind.amountLabel, value: op.strength)
            ForEach(op.kind.params, id: \.slot) { spec in
                valuePill(spec.label, value: spec.slot == 1 ? op.p1 : op.p2)
            }
            if let iterations = op.groupIterations, iterations > 1 {
                Text("\(iterations)×")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(Color.indigo.opacity(0.22), in: Capsule())
            }
        }
        .lineLimit(1)
    }

    private func valuePill(_ label: String, value: Float) -> some View {
        Text("\(label) \(String(format: "%.2f", value))")
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}

private struct MathLensDiagram: View {
    let kind: SpaceWarpKind?
    let operation: SpaceWarpOpValue?

    var body: some View {
        Canvas { context, size in
            drawGrid(context: &context, size: size)
            guard let kind else {
                drawLevelSet(context: &context, size: size)
                return
            }
            switch kind {
            case .mirror, .boxFold, .planeFold, .mengerFold, .offsetFold:
                drawReflection(context: &context, size: size, offset: kind == .offsetFold ? 0.18 : 0)
            case .sphereFold, .inversion, .circle, .shells, .scaleRepeat:
                drawRadial(context: &context, size: size, inversion: kind == .inversion)
            case .kaleidoscope, .coxeter, .icosahedralCut:
                drawChamber(context: &context, size: size, segments: diagramSegments)
            case .tiling:
                drawTiling(context: &context, size: size)
            case .scale, .mandelboxStep:
                drawRecurrence(context: &context, size: size)
            case .twist, .bend, .ripple:
                drawDeformation(context: &context, size: size, kind: kind)
            }
        }
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var diagramSegments: Int {
        let requested = Int((operation?.p1 ?? 6).rounded())
        return min(max(requested, 3), 12)
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        var grid = Path()
        let spacing: CGFloat = 20
        for x in stride(from: CGFloat.zero, through: size.width, by: spacing) {
            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        for y in stride(from: CGFloat.zero, through: size.height, by: spacing) {
            grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(.white.opacity(0.055)), lineWidth: 0.7)
    }

    private func drawLevelSet(context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        for scale in [0.42, 0.62, 0.82] as [CGFloat] {
            let rect = CGRect(x: center.x - size.height * scale * 0.5,
                              y: center.y - size.height * scale * 0.5,
                              width: size.height * scale, height: size.height * scale)
            context.stroke(Path(ellipseIn: rect), with: .color(.cyan.opacity(1 - Double(scale) * 0.55)), lineWidth: 1.4)
        }
        drawPoint(context: &context, at: CGPoint(x: center.x + 5, y: center.y - 2), color: .orange)
    }

    private func drawReflection(context: inout GraphicsContext, size: CGSize, offset: CGFloat) {
        let creaseX = size.width * (0.5 + offset)
        var plane = Path(); plane.move(to: CGPoint(x: creaseX, y: 12)); plane.addLine(to: CGPoint(x: creaseX, y: size.height - 12))
        context.stroke(plane, with: .color(.cyan), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))

        let left = CGPoint(x: size.width * 0.22, y: size.height * 0.34)
        let right = CGPoint(x: creaseX + (creaseX - left.x), y: left.y)
        var link = Path(); link.move(to: left); link.addLine(to: right)
        context.stroke(link, with: .color(.orange.opacity(0.75)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
        drawPoint(context: &context, at: left, color: .orange)
        drawPoint(context: &context, at: right, color: .cyan)
    }

    private func drawRadial(context: inout GraphicsContext, size: CGSize, inversion: Bool) {
        let c = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        let radius = min(size.height * 0.34, size.width * 0.18)
        for multiple in [0.55, 1.0, 1.45] as [CGFloat] {
            let r = radius * multiple
            context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                           with: .color(multiple == 1 ? .cyan : .cyan.opacity(0.28)), lineWidth: multiple == 1 ? 2 : 1)
        }
        let inner = CGPoint(x: c.x + radius * 0.42, y: c.y)
        let outer = CGPoint(x: c.x + radius * (inversion ? 1.85 : 1.25), y: c.y)
        var ray = Path(); ray.move(to: inner); ray.addLine(to: outer)
        context.stroke(ray, with: .color(.orange.opacity(0.8)), lineWidth: 1.5)
        drawPoint(context: &context, at: inner, color: .orange)
        drawPoint(context: &context, at: outer, color: .cyan)
    }

    private func drawChamber(context: inout GraphicsContext, size: CGSize, segments: Int) {
        let c = CGPoint(x: size.width * 0.5, y: size.height * 0.54)
        let radius = size.height * 0.42
        for i in 0..<segments {
            let angle = -Double.pi / 2 + Double(i) * 2 * Double.pi / Double(segments)
            var ray = Path(); ray.move(to: c)
            ray.addLine(to: CGPoint(x: c.x + radius * cos(angle), y: c.y + radius * sin(angle)))
            context.stroke(ray, with: .color(i < 2 ? .cyan : .cyan.opacity(0.22)), lineWidth: i < 2 ? 2 : 1)
        }
        drawPoint(context: &context, at: c, color: .orange)
    }

    private func drawTiling(context: inout GraphicsContext, size: CGSize) {
        let cell: CGFloat = 34
        var path = Path()
        for x in stride(from: size.width * 0.5 - cell * 4, through: size.width, by: cell) {
            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
        }
        for y in stride(from: size.height * 0.5 - cell * 2, through: size.height, by: cell) {
            path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(path, with: .color(.cyan.opacity(0.62)), lineWidth: 1.3)
        drawPoint(context: &context, at: CGPoint(x: size.width * 0.5, y: size.height * 0.5), color: .orange)
    }

    private func drawRecurrence(context: inout GraphicsContext, size: CGSize) {
        let c = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        for (index, scale) in [1.0, 0.65, 0.38].enumerated() {
            let side = size.height * CGFloat(scale) * 0.76
            let rect = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
            context.stroke(Path(roundedRect: rect, cornerRadius: 5),
                           with: .color(index == 0 ? .cyan : .cyan.opacity(0.55)), lineWidth: 1.6)
        }
        drawPoint(context: &context, at: c, color: .orange)
    }

    private func drawDeformation(context: inout GraphicsContext, size: CGSize, kind: SpaceWarpKind) {
        let midY = size.height * 0.5
        var axis = Path(); axis.move(to: CGPoint(x: 14, y: midY)); axis.addLine(to: CGPoint(x: size.width - 14, y: midY))
        context.stroke(axis, with: .color(.cyan.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))

        var curve = Path()
        for step in 0...100 {
            let t = CGFloat(step) / 100
            let x = 14 + t * (size.width - 28)
            let amplitude = size.height * (kind == .bend ? 0.26 * t : 0.25)
            let y: CGFloat
            if kind == .bend {
                y = midY - amplitude * sin(t * .pi)
            } else {
                y = midY + amplitude * sin(t * .pi * (kind == .twist ? 4 : 6))
            }
            if step == 0 { curve.move(to: CGPoint(x: x, y: y)) }
            else { curve.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(curve, with: .color(.orange), lineWidth: 2)
    }

    private func drawPoint(context: inout GraphicsContext, at point: CGPoint, color: Color) {
        let rect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
        context.fill(Path(ellipseIn: rect), with: .color(color))
        context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(color.opacity(0.32)), lineWidth: 1)
    }
}
