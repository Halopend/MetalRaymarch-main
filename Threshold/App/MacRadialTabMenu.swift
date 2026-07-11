#if os(macOS)
import AppKit
import SwiftUI

/// A lightweight navigation value rendered by ``MacRadialTabMenu``.
///
/// The launcher deliberately owns no control content. Keeping it to buttons and
/// static gradients means revealing the navigation does not mount the large
/// control tree or add a live blur pass over the Metal view.
struct MacRadialTabItem: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void
}

enum MacTabLauncherStyle: String, CaseIterable {
    case radial = "Radial"
    case grid = "Grid"

    var systemImage: String {
        switch self {
        case .radial: return "circle.grid.cross"
        case .grid: return "rectangle.grid.2x2"
        }
    }
}

/// Derives a bright UI accent from the active scene gradient while preserving
/// enough contrast against the launcher's dark-purple capsule surface.
enum MacTabSceneAccent {
    static func color(from gradient: GradientColorMap) -> Color {
        let samples = gradient.stops.map(\.color) + [
            gradient.evaluate(at: 0.28),
            gradient.evaluate(at: 0.58),
            gradient.evaluate(at: 0.82)
        ]
        let source = samples.max(by: { accentScore($0) < accentScore($1) })
            ?? SIMD3<Float>(0.92, 0.62, 1.00)
        let tuned = contrastTuned(source)
        return Color(
            red: Double(tuned.x),
            green: Double(tuned.y),
            blue: Double(tuned.z)
        )
    }

    private static func accentScore(_ color: SIMD3<Float>) -> Float {
        let clamped = simdClamp(color)
        let maximum = max(clamped.x, max(clamped.y, clamped.z))
        let minimum = min(clamped.x, min(clamped.y, clamped.z))
        let chroma = maximum - minimum
        return chroma * 1.4 + maximum * 0.3
    }

    private static func contrastTuned(_ source: SIMD3<Float>) -> SIMD3<Float> {
        var result = simdClamp(source)
        let background = SIMD3<Float>(0.16, 0.025, 0.25)
        let targetContrast: Float = 3.2

        // Grayscale or near-black palettes should still produce a visible,
        // neutral glint instead of inventing an unrelated hue.
        if max(result.x, max(result.y, result.z)) < 0.12 {
            result = SIMD3<Float>(repeating: 0.78)
        }

        for _ in 0..<8 where contrastRatio(result, background) < targetContrast {
            result += (SIMD3<Float>(repeating: 1) - result) * 0.18
        }
        return simdClamp(result)
    }

    private static func contrastRatio(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Float {
        let light = max(relativeLuminance(lhs), relativeLuminance(rhs))
        let dark = min(relativeLuminance(lhs), relativeLuminance(rhs))
        return (light + 0.05) / (dark + 0.05)
    }

    private static func relativeLuminance(_ color: SIMD3<Float>) -> Float {
        func linearized(_ component: Float) -> Float {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearized(color.x)
            + 0.7152 * linearized(color.y)
            + 0.0722 * linearized(color.z)
    }

    private static func simdClamp(_ color: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(
            min(max(color.x, 0), 1),
            min(max(color.y, 0), 1),
            min(max(color.z, 0), 1)
        )
    }
}

/// Pure radial layout used by the macOS edge launcher.
///
/// `curvature` is intentionally a parameter rather than a visual constant. A
/// larger value opens the fan farther, while `depth` adds a restrained amount of
/// extra bend so nested controls read as a deeper ring in the hierarchy.
struct MacRadialTabGeometry {
    let curvature: CGFloat

    /// Capsules are taller than the raw arc spacing near its ends. Keep enough
    /// center-to-center room for the resting size plus hover/focus expansion.
    /// The child ring is shorter, so it can remain a little denser.
    private func minimumItemSpacing(depth: Int) -> CGFloat {
        depth == 0 ? 46 : 34
    }

    func positions(
        count: Int,
        depth: Int,
        anchor: CGPoint,
        availableHeight: CGFloat,
        opensLeft: Bool = true,
        bifurcates: Bool = false,
        localBranch: Bool = false
    ) -> [CGPoint] {
        guard count > 0 else { return [] }

        if bifurcates, count > 1 {
            return bifurcatedPositions(
                count: count,
                depth: depth,
                anchor: anchor,
                availableHeight: availableHeight,
                startsLeft: opensLeft
            )
        }

        let clampedCurvature = min(max(curvature, 0.35), 1.35)
        let depthBend = 1 + CGFloat(depth) * 0.06
        let maximumSpread = (.pi * 0.66) * clampedCurvature * depthBend
        // Small child sets should form a compact branch, not occupy the whole
        // outer arc. Larger sets progressively consume the available curvature.
        let spread = depth == 0
            ? maximumSpread
            : min(maximumSpread, CGFloat(max(count - 1, 0)) * 0.20)
        // The child ring needs enough horizontal separation for its 116pt pills
        // to clear the primary ring's 180pt pills, including their hover scale.
        let radius: CGFloat
        if depth == 0 {
            radius = 146
        } else if localBranch {
            radius = 164 + CGFloat(depth - 1) * 72
        } else {
            radius = 340 + CGFloat(depth - 1) * 96
        }

        let raw = (0..<count).map { index -> CGPoint in
            let progress = count == 1 ? 0.5 : CGFloat(index) / CGFloat(count - 1)
            // Preserve reading order from top to bottom in screen coordinates.
            let angle = opensLeft
                ? .pi + (0.5 - progress) * spread
                : (progress - 0.5) * spread
            return CGPoint(
                x: anchor.x + cos(angle) * radius,
                y: anchor.y + sin(angle) * radius
            )
        }

        // Equal angular steps bunch up vertically near the ends of an arc. That
        // made the seven 42pt primary capsules overlap at the default curvature
        // (and collapse almost completely at the tightest setting). Stretch only
        // the vertical component when necessary; retaining the original X values
        // preserves the fan silhouette while guaranteeing readable hit targets.
        let spaced: [CGPoint]
        if count > 1 {
            let requiredSpacing = minimumItemSpacing(depth: depth)
            let rawTop = raw.first?.y ?? anchor.y
            let rawBottom = raw.last?.y ?? anchor.y
            let rawSpan = max(rawBottom - rawTop, 0)
            let requiredSpan = requiredSpacing * CGFloat(count - 1)
            let resolvedSpan = max(rawSpan, requiredSpan)
            let centerY = (rawTop + rawBottom) * 0.5

            spaced = raw.enumerated().map { index, point in
                let progress = CGFloat(index) / CGFloat(count - 1)
                return CGPoint(
                    x: point.x,
                    y: centerY + (progress - 0.5) * resolvedSpan
                )
            }
        } else {
            spaced = raw
        }

        // Keep the complete ring on-screen as a group. The anchor still follows
        // the pointer, but a top/bottom edge cannot collapse multiple tabs onto
        // the same clamped coordinate.
        let verticalMargin: CGFloat = 30
        let minY = spaced.map(\.y).min() ?? anchor.y
        let maxY = spaced.map(\.y).max() ?? anchor.y
        let upperCorrection = max(0, verticalMargin - minY)
        let lowerCorrection = min(0, availableHeight - verticalMargin - maxY)
        let verticalCorrection = upperCorrection > 0 ? upperCorrection : lowerCorrection

        return spaced.map { CGPoint(x: $0.x, y: $0.y + verticalCorrection) }
    }

    /// Splits the ordered tabs into paired horizontal rows on both sides of the
    /// pointer. Each branch still follows an arc, but the pills themselves stay
    /// level and the hierarchy reads left-to-right instead of as a long column.
    private func bifurcatedPositions(
        count: Int,
        depth: Int,
        anchor: CGPoint,
        availableHeight: CGFloat,
        startsLeft: Bool
    ) -> [CGPoint] {
        // Paired branches do not bunch together at the arc ends, so their
        // second layer can sit materially closer without colliding with the
        // 180pt primary and 116pt child pills.
        let radius: CGFloat = depth == 0 ? 146 : 304 + CGFloat(depth - 1) * 72
        let rowCount = Int(ceil(Double(count) / 2.0))
        let curvatureSpacing = depth == 0 ? curvature * 5 : curvature * 3
        let rowSpacing = minimumItemSpacing(depth: depth) + curvatureSpacing
        let span = rowSpacing * CGFloat(max(rowCount - 1, 0))
        let top = anchor.y - span * 0.5

        let raw = (0..<count).map { index -> CGPoint in
            let row = index / 2
            let yOffset = top + CGFloat(row) * rowSpacing - anchor.y
            let clampedYOffset = min(max(yOffset, -radius * 0.82), radius * 0.82)
            let xMagnitude = sqrt(max(radius * radius - clampedYOffset * clampedYOffset, 0))
            let usesLeftBranch = index.isMultiple(of: 2) ? startsLeft : !startsLeft
            return CGPoint(
                x: anchor.x + (usesLeftBranch ? -xMagnitude : xMagnitude),
                y: anchor.y + clampedYOffset
            )
        }

        let verticalMargin: CGFloat = 30
        let minY = raw.map(\.y).min() ?? anchor.y
        let maxY = raw.map(\.y).max() ?? anchor.y
        let upperCorrection = max(0, verticalMargin - minY)
        let lowerCorrection = min(0, availableHeight - verticalMargin - maxY)
        let verticalCorrection = upperCorrection > 0 ? upperCorrection : lowerCorrection
        return raw.map { CGPoint(x: $0.x, y: $0.y + verticalCorrection) }
    }
}

/// Screen-position anchored, two-ring tab launcher for the macOS render view.
struct MacRadialTabMenu: View {
    let size: CGSize
    let pointerAnchor: CGPoint
    @Binding var curvature: Double
    let primaryItems: [MacRadialTabItem]
    let childItems: [MacRadialTabItem]
    @Binding var layoutStyle: MacTabLauncherStyle
    let sceneAccent: Color

    @FocusState private var focusedItemID: String?

    private var allItems: [MacRadialTabItem] { primaryItems + childItems }

    private var anchor: CGPoint {
        layoutStyle == .radial
            ? pointerAnchor
            : CGPoint(x: size.width - 18, y: pointerAnchor.y)
    }

    private var opensLeft: Bool { anchor.x >= size.width * 0.5 }
    private var bifurcates: Bool {
        guard layoutStyle == .radial else { return false }
        let horizontalClearance: CGFloat = 378
        return anchor.x >= horizontalClearance && anchor.x <= size.width - horizontalClearance
    }

    private let gridPrimaryWidth: CGFloat = 166
    private let gridChildWidth: CGFloat = 116
    private let gridRightInset: CGFloat = 6

    /// Grid mode is a right-edge rail: every primary capsule and the toolbar
    /// share this trailing boundary regardless of their label length.
    private var gridPrimaryColumnX: CGFloat {
        anchor.x - gridRightInset - gridPrimaryWidth * 0.5
    }

    var body: some View {
        ZStack {
            if layoutStyle == .radial {
                radialGuide
                    .allowsHitTesting(false)
            }

            ring(items: primaryItems, depth: 0)
            ring(items: childItems, depth: 1)

            layoutPicker

            anchorMark
                .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        .onAppear {
            focusedItemID = primaryItems.first(where: \.isSelected)?.id ?? primaryItems.first?.id
        }
        .onKeyPress(.tab) {
            moveFocus(backward: NSEvent.modifierFlags.contains(.shift))
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Radial control tabs")
    }

    @ViewBuilder
    private func ring(items: [MacRadialTabItem], depth: Int) -> some View {
        let positions = itemPositions(
            count: items.count,
            depth: depth,
            centeredAt: depth == 0 ? anchor : childBranchAnchor
        )

        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            let transitionDirection: CGFloat = positions[index].x < anchor.x ? 1 : -1
            MacRadialTabButton(
                item: item,
                depth: depth,
                fixedWidth: layoutStyle == .grid
                    ? (depth == 0 ? gridPrimaryWidth : gridChildWidth)
                    : nil,
                isFocused: focusedItemID == item.id,
                retreatDirection: positions[index].x < anchor.x ? -1 : 1,
                sceneAccent: sceneAccent
            )
            .focused($focusedItemID, equals: item.id)
            .position(positions[index])
            .transition(
                .offset(x: transitionDirection * (depth == 0 ? 48 : 62))
                    .combined(with: .scale(scale: 0.82, anchor: .trailing))
                    .combined(with: .opacity)
            )
        }
    }

    private var childBranchAnchor: CGPoint {
        let primaryPositions = itemPositions(count: primaryItems.count, depth: 0, centeredAt: anchor)
        let selectedIndex = primaryItems.firstIndex(where: \.isSelected) ?? 0
        guard primaryPositions.indices.contains(selectedIndex) else { return anchor }
        return primaryPositions[selectedIndex]
    }

    private func itemPositions(count: Int, depth: Int, centeredAt layoutAnchor: CGPoint) -> [CGPoint] {
        switch layoutStyle {
        case .radial:
            let isLocalChildBranch = depth > 0
            let branchOpensLeft = isLocalChildBranch ? layoutAnchor.x < anchor.x : opensLeft
            return MacRadialTabGeometry(curvature: CGFloat(curvature)).positions(
                count: count,
                depth: depth,
                anchor: layoutAnchor,
                availableHeight: size.height,
                opensLeft: branchOpensLeft,
                bifurcates: isLocalChildBranch ? false : bifurcates,
                localBranch: isLocalChildBranch
            )
        case .grid:
            return gridPositions(count: count, depth: depth, centerY: layoutAnchor.y)
        }
    }

    private func gridPositions(count: Int, depth: Int, centerY: CGFloat) -> [CGPoint] {
        guard count > 0 else { return [] }
        let spacing: CGFloat = depth == 0 ? 48 : 34
        let columnX = depth == 0 ? gridPrimaryColumnX : anchor.x - 292
        let rawTop = centerY - CGFloat(count - 1) * spacing * 0.5
        let margin: CGFloat = 30
        let rawBottom = rawTop + CGFloat(count - 1) * spacing
        let correction: CGFloat
        if rawTop < margin {
            correction = margin - rawTop
        } else if rawBottom > size.height - margin {
            correction = size.height - margin - rawBottom
        } else {
            correction = 0
        }
        return (0..<count).map { index in
            CGPoint(x: columnX, y: rawTop + CGFloat(index) * spacing + correction)
        }
    }

    private var layoutPicker: some View {
        HStack(spacing: 3) {
            ForEach(MacTabLauncherStyle.allCases, id: \.self) { style in
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        layoutStyle = style
                    }
                } label: {
                    Image(systemName: style.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 22)
                        .foregroundStyle(layoutStyle == style ? Color.white : Color.white.opacity(0.52))
                        .background(
                            layoutStyle == style
                                ? Color(red: 0.58, green: 0.13, blue: 0.84).opacity(0.88)
                                : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .help("Use \(style.rawValue.lowercased()) tabs")
            }

            if layoutStyle == .radial {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 1)

                curvatureButton(systemImage: "minus", delta: -0.08)
                curvatureButton(systemImage: "plus", delta: 0.08)
            }
        }
        .padding(3)
        .background(Color(red: 0.055, green: 0.012, blue: 0.09).opacity(0.96), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8))
        .frame(
            width: layoutStyle == .grid ? gridPrimaryWidth : nil,
            alignment: .trailing
        )
        .position(layoutPickerPosition)
        .accessibilityLabel("Tab layout")
    }

    private var layoutPickerPosition: CGPoint {
        let primaryPositions = itemPositions(count: primaryItems.count, depth: 0, centeredAt: anchor)
        let top = primaryPositions.map(\.y).min() ?? anchor.y
        let bottom = primaryPositions.map(\.y).max() ?? anchor.y
        let desiredY = top - 32
        let resolvedY = desiredY >= 24 ? desiredY : min(bottom + 32, size.height - 24)
        return CGPoint(
            x: layoutStyle == .grid
                ? gridPrimaryColumnX
                : bifurcates ? anchor.x : anchor.x + (opensLeft ? -70 : 70),
            y: resolvedY
        )
    }

    private func curvatureButton(systemImage: String, delta: Double) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.14)) {
                curvature = min(max(curvature + delta, 0.35), 1.35)
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 19, height: 22)
                .foregroundStyle(Color.white.opacity(0.72))
        }
        .buttonStyle(.plain)
        .help(delta < 0 ? "Tighten radial curvature" : "Open radial curvature")
    }

    private var radialGuide: some View {
        Canvas { context, _ in
            let guideLayers: [(center: CGPoint, radius: CGFloat, branches: [Bool], opacity: Double)] = [
                (anchor, 146, bifurcates ? [true, false] : [opensLeft], 0.34),
                (childBranchAnchor, 164, [childBranchAnchor.x < anchor.x], 0.20)
            ]

            for layer in guideLayers {
                if layer.radius != 146, childItems.isEmpty { continue }
                let center = layer.center
                let radius = layer.radius
                for drawsLeft in layer.branches {
                    var path = Path()
                    path.addArc(
                        center: center,
                        radius: radius,
                        startAngle: .degrees(drawsLeft ? 126 : -54),
                        endAngle: .degrees(drawsLeft ? 234 : 54),
                        clockwise: false
                    )
                    context.stroke(
                        path,
                        with: .linearGradient(
                            Gradient(colors: [
                                Color(red: 0.20, green: 0.04, blue: 0.34).opacity(0.10),
                                Color(red: 0.78, green: 0.26, blue: 1.00).opacity(layer.opacity)
                            ]),
                            startPoint: CGPoint(
                                x: center.x + (drawsLeft ? -radius : radius),
                                y: center.y
                            ),
                            endPoint: center
                        ),
                        style: StrokeStyle(lineWidth: radius == 146 ? 1.2 : 0.8, dash: [2, 7])
                    )
                }
            }
        }
    }

    private var anchorMark: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.54, green: 0.12, blue: 0.82).opacity(0.22))
                .frame(width: 34, height: 34)
            Circle()
                .fill(Color(red: 0.92, green: 0.62, blue: 1.00))
                .frame(width: 6, height: 6)
                .shadow(color: Color.purple.opacity(0.9), radius: 7)
        }
        .position(anchor)
    }

    private func moveFocus(backward: Bool) {
        guard !allItems.isEmpty else { return }
        let currentIndex = focusedItemID.flatMap { id in allItems.firstIndex(where: { $0.id == id }) } ?? 0
        let delta = backward ? -1 : 1
        let nextIndex = (currentIndex + delta + allItems.count) % allItems.count
        focusedItemID = allItems[nextIndex].id
    }
}

private struct MacRadialTabButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let item: MacRadialTabItem
    let depth: Int
    let fixedWidth: CGFloat?
    let isFocused: Bool
    let retreatDirection: CGFloat
    let sceneAccent: Color

    @State private var isHovering = false
    @State private var hoverOffset: CGFloat = 0
    @State private var hoverSequence = 0

    private var isEmphasized: Bool { item.isSelected || isHovering || isFocused }
    private var shouldWiggle: Bool { !reduceMotion && !item.isSelected && !isHovering && !isFocused }

    /// Different rests keep the symbols from moving as a synchronized block.
    /// The animation itself is handled by the system symbol compositor, so it
    /// does not drive layout or rebuild the Metal-backed content underneath.
    private var wiggleDelay: Double {
        let phase = item.id.utf8.reduce(0) { (partial, byte) in
            (partial + Int(byte)) % 9
        }
        return 0.32 + Double(phase) * 0.09
    }

    var body: some View {
        Button(action: item.action) {
            HStack(spacing: depth == 0 ? 9 : 7) {
                Image(systemName: item.systemImage)
                    .font(.system(size: depth == 0 ? 14 : 12, weight: .semibold))
                    .frame(width: depth == 0 ? 18 : 15)
                    .symbolEffect(
                        .wiggle.wholeSymbol,
                        options: .repeat(.periodic(delay: wiggleDelay)).speed(0.52),
                        isActive: shouldWiggle
                    )

                Text(item.title)
                    .font(.system(size: depth == 0 ? 13 : 11, weight: isEmphasized ? .bold : .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if item.isSelected {
                    Circle()
                        .fill(Color(red: 0.96, green: 0.74, blue: 1.00))
                        .frame(width: 5, height: 5)
                        .shadow(color: .purple, radius: 5)
                }
            }
            .padding(.horizontal, depth == 0 ? 14 : 10)
            .frame(height: depth == 0 ? 42 : 30)
            .frame(
                minWidth: fixedWidth ?? (depth == 0 ? 142 : 104),
                idealWidth: fixedWidth ?? (depth == 0 ? 154 : 112),
                maxWidth: fixedWidth ?? (depth == 0 ? 180 : 116),
                alignment: .leading
            )
            .background(tabFill, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        isEmphasized ? emphasisAccent.opacity(0.78) : Color.white.opacity(0.10),
                        lineWidth: isEmphasized ? 1.2 : 0.8
                    )
            )
            .overlay(shimmerOverlay)
            // Move only the painted pill, leaving the button's layout and hit
            // target fixed. The cursor can therefore catch the pill when it
            // springs back instead of chasing a moving target.
            .offset(x: hoverOffset)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEmphasized ? Color.white : Color.white.opacity(0.68))
        .shadow(
            color: isEmphasized ? emphasisAccent.opacity(0.44) : Color.black.opacity(0.28),
            radius: isEmphasized ? 11 : 4,
            x: 0,
            y: 2
        )
        .scaleEffect(isHovering ? 1.035 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isFocused)
        .onHover { hovering in
            isHovering = hovering
            hoverSequence &+= 1
            let sequence = hoverSequence

            guard hovering, !reduceMotion else {
                withAnimation(.easeOut(duration: 0.08)) {
                    hoverOffset = 0
                }
                return
            }

            // A six-point retreat reads as a playful flinch without escaping
            // the stable hit target, then a short spring lands it under the mouse.
            withAnimation(.easeOut(duration: 0.06)) {
                hoverOffset = retreatDirection * 6
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(55))
                guard hoverSequence == sequence, isHovering else { return }
                withAnimation(.spring(response: 0.19, dampingFraction: 0.58)) {
                    hoverOffset = 0
                }
            }
        }
        .help(item.title)
        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
    }

    private var tabFill: LinearGradient {
        LinearGradient(
            colors: isEmphasized
                ? [
                    Color(red: 0.10, green: 0.015, blue: 0.17).opacity(0.98),
                    Color(red: 0.45, green: 0.08, blue: 0.67).opacity(0.97),
                    Color(red: 0.76, green: 0.22, blue: 0.98).opacity(0.96)
                ]
                : [
                    Color(red: 0.055, green: 0.012, blue: 0.09).opacity(0.96),
                    Color(red: 0.25, green: 0.04, blue: 0.38).opacity(0.94)
                ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    @ViewBuilder
    private var shimmerOverlay: some View {
        if isHovering {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
                GeometryReader { proxy in
                    let bandWidth = max(34, proxy.size.width * 0.26)
                    let cycleDuration = 1.25
                    let elapsed = timeline.date.timeIntervalSinceReferenceDate
                    let progress = reduceMotion
                        ? 0.5
                        : elapsed.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
                    let travel = proxy.size.width + bandWidth * 2

                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color.white.opacity(0.05),
                            sceneAccent.opacity(0.82),
                            Color.white.opacity(0.08),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: bandWidth, height: proxy.size.height * 2.2)
                    .rotationEffect(.degrees(18))
                    .offset(
                        x: -bandWidth + travel * progress,
                        y: -proxy.size.height * 0.6
                    )
                }
            }
            .clipShape(Capsule())
            .blendMode(.screen)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private var emphasisAccent: Color {
        isHovering || isFocused
            ? sceneAccent
            : Color(red: 0.92, green: 0.62, blue: 1.00)
    }
}

/// Tracks window-local pointer motion and Shift without polling. Unlike a thin
/// SwiftUI hover strip, this sees the pointer's full rightward approach to the
/// edge, including a single fast event that crosses the reveal threshold.
struct MacTabInputMonitor: NSViewRepresentable {
    @Binding var isPressed: Bool
    let isRadialVisible: Bool
    let onMouseMoved: (CGPoint) -> Void
    let onTwoFingerSwipeUp: () -> Void
    let onDoubleClick: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isPressed: $isPressed,
            isRadialVisible: isRadialVisible,
            onMouseMoved: onMouseMoved,
            onTwoFingerSwipeUp: onTwoFingerSwipeUp,
            onDoubleClick: onDoubleClick
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.isPressed = $isPressed
        context.coordinator.isRadialVisible = isRadialVisible
        context.coordinator.onMouseMoved = onMouseMoved
        context.coordinator.onTwoFingerSwipeUp = onTwoFingerSwipeUp
        context.coordinator.onDoubleClick = onDoubleClick
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        var isPressed: Binding<Bool>
        var isRadialVisible: Bool
        var onMouseMoved: (CGPoint) -> Void
        var onTwoFingerSwipeUp: () -> Void
        var onDoubleClick: () -> Void
        weak var hostView: NSView?
        private var monitor: Any?
        private var swipeUpDistance: CGFloat = 0
        private var didTriggerSwipe = false
        private let swipeDismissThreshold: CGFloat = 24

        init(
            isPressed: Binding<Bool>,
            isRadialVisible: Bool,
            onMouseMoved: @escaping (CGPoint) -> Void,
            onTwoFingerSwipeUp: @escaping () -> Void,
            onDoubleClick: @escaping () -> Void
        ) {
            self.isPressed = isPressed
            self.isRadialVisible = isRadialVisible
            self.onMouseMoved = onMouseMoved
            self.onTwoFingerSwipeUp = onTwoFingerSwipeUp
            self.onDoubleClick = onDoubleClick
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseDragged, .scrollWheel]
            ) { [weak self] event in
                guard let self else { return event }
                guard let hostWindow = hostView?.window, event.window === hostWindow else { return event }

                if event.type == .flagsChanged {
                    isPressed.wrappedValue = event.modifierFlags.contains(.shift)
                } else if event.type == .leftMouseDown {
                    if isRadialVisible, event.clickCount >= 2 {
                        onDoubleClick()
                        return nil
                    }
                    onMouseMoved(event.locationInWindow)
                } else if event.type == .scrollWheel {
                    guard event.hasPreciseScrollingDeltas else { return event }
                    guard isRadialVisible else {
                        resetSwipeTracking()
                        return event
                    }

                    if event.phase == .began {
                        resetSwipeTracking()
                    }

                    // Normalize away the user's natural-scrolling preference so
                    // this remains a physical upward finger gesture. Opposite
                    // travel drains the gesture instead of letting a jittery
                    // reversal dismiss the launcher accidentally.
                    let upwardDelta = event.isDirectionInvertedFromDevice
                        ? -event.scrollingDeltaY
                        : event.scrollingDeltaY
                    if upwardDelta > 0 {
                        swipeUpDistance += upwardDelta
                    } else if upwardDelta < 0 {
                        swipeUpDistance = max(0, swipeUpDistance + upwardDelta)
                    }

                    if !didTriggerSwipe, swipeUpDistance >= swipeDismissThreshold {
                        didTriggerSwipe = true
                        onTwoFingerSwipeUp()
                    }

                    if event.phase == .ended || event.phase == .cancelled {
                        resetSwipeTracking()
                    }
                    return nil
                } else {
                    onMouseMoved(event.locationInWindow)
                }
                return event
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
            resetSwipeTracking()
            isPressed.wrappedValue = false
        }

        private func resetSwipeTracking() {
            swipeUpDistance = 0
            didTriggerSwipe = false
        }
    }
}
#endif
