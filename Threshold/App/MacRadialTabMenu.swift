#if os(macOS)
import AppKit
import SwiftUI

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
    /// center-to-center room for the resting size plus hover/focus expansion
    /// (42pt and 30pt pills × the 1.035 hover scale). Deeper rings are shorter,
    /// so they can remain denser — hover-to-navigate makes every point of
    /// pointer travel count.
    private func minimumItemSpacing(depth: Int, sliderRing: Bool) -> CGFloat {
        if depth == 0 { return 38 }
        return sliderRing ? 40 : 32
    }

    /// Ring radii. The primary ring hugs the anchor; each deeper ring is a
    /// compact concentric level around the pointer. These are the tightest values
    /// that still clear a 184×46 primary pill against a 120×34 branch pill at
    /// EVERY curvature — at the tightest curvature the primary pills stack
    /// almost vertically, which is the binding constraint (see
    /// MacRadialTabGeometryTests.childRingClearsPrimaryRing).
    static let primaryRadius: CGFloat = 106
    /// Radial center clearance between a selected pill and its child arc.
    /// The value clears the widest compact capsules when the arc points
    /// horizontally, while avoiding the oversized fixed-depth jumps.
    static let concentricRingStep: CGFloat = 116
    static let localBranchRadius: CGFloat = 156
    static let localBranchRadiusStep: CGFloat = 18

    /// Local branches cap their angular spread: a wide arc's end pills swing
    /// back toward the parent column and collide with the parent ring's
    /// vertical neighbors. Excess items get their room from the
    /// minimum-spacing vertical stretch instead, which preserves X.
    static let localBranchMaxSpread: CGFloat = 0.50

    /// Places a compact ring on an exact circle. Unlike the legacy local-branch
    /// placement, every hierarchy level shares the same center; only radius
    /// changes. Angular spacing is derived from pill height so the arc remains
    /// dense without vertically overlapping adjacent hit targets.
    func concentricPositions(
        count: Int,
        anchor: CGPoint,
        radius: CGFloat,
        baseAngle: CGFloat,
        sliderRing: Bool
    ) -> [CGPoint] {
        guard count > 0 else { return [] }
        // This is a hard center-to-center floor, not a curvature-scaled ideal:
        // shrinking it at low curvature made neighboring capsules overlap.
        let linearSpacing: CGFloat = sliderRing ? 40 : 32
        let curvatureScale = min(max(curvature, 0.35), 1.35)
        let minimumAngularStep = 2 * asin(min(linearSpacing / (2 * max(radius, 1)), 0.82))
        // Curvature may open the arc farther, but can never compress it below
        // the capsule/hit-target clearance above.
        let angularStep = minimumAngularStep * (1 + (curvatureScale - 0.35) * 0.28)
        let windingSign: CGFloat = cos(baseAngle) <= 0 ? 1 : -1

        return (0..<count).map { index in
            let progress = CGFloat(index) - CGFloat(count - 1) * 0.5
            let angle = baseAngle - windingSign * progress * angularStep
            return CGPoint(
                x: anchor.x + cos(angle) * radius,
                y: anchor.y + sin(angle) * radius
            )
        }
    }

    func positions(
        count: Int,
        depth: Int,
        anchor: CGPoint,
        availableHeight: CGFloat,
        opensLeft: Bool = true,
        bifurcates: Bool = false,
        localBranch: Bool = false,
        branchBaseAngle: CGFloat? = nil,
        radiusBoost: CGFloat = 0,
        sliderRing: Bool = false,
        availableWidth: CGFloat = .infinity
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
        // outer arc. Larger sets progressively consume the available curvature
        // up to the local-branch cap that keeps a branch inside its own sector
        // instead of curling back into the parent ring.
        let spread = depth == 0
            ? maximumSpread
            : min(maximumSpread, CGFloat(max(count - 1, 0)) * 0.20, Self.localBranchMaxSpread)
        // Branch rings need enough separation for their pills to clear the
        // parent ring's pills, including their hover scale.
        let radius: CGFloat
        if depth == 0 {
            radius = Self.primaryRadius
        } else if localBranch {
            radius = Self.localBranchRadius + CGFloat(depth - 1) * Self.localBranchRadiusStep + radiusBoost
        } else {
            radius = 340 + CGFloat(depth - 1) * 96
        }

        // Local branches fan around their parent pill's own outward direction
        // (radially away from the ring center) rather than straight sideways.
        // A branch from an edge pill therefore extends the fan outward instead
        // of sweeping back across the parent ring's column — that crossing was
        // the geometric source of pill collisions at curvature extremes.
        let baseAngle: CGFloat = {
            guard localBranch, let branchBaseAngle else {
                return opensLeft ? .pi : 0
            }
            return branchBaseAngle
        }()
        // Choose the fan's winding so index order still reads roughly top to
        // bottom; where the fan is near-vertical, the minimum-spacing stretch
        // below re-imposes strict top-to-bottom order by index anyway.
        let windingSign: CGFloat = cos(baseAngle) <= 0 ? 1 : -1

        let raw = (0..<count).map { index -> CGPoint in
            let progress = count == 1 ? 0.5 : CGFloat(index) / CGFloat(count - 1)
            let angle = baseAngle + windingSign * (0.5 - progress) * spread
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
            let requiredSpacing = minimumItemSpacing(depth: depth, sliderRing: sliderRing)
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
        // the same clamped coordinate. Deep branches near a side edge get the
        // same treatment horizontally.
        let verticalMargin: CGFloat = 30
        let minY = spaced.map(\.y).min() ?? anchor.y
        let maxY = spaced.map(\.y).max() ?? anchor.y
        let upperCorrection = max(0, verticalMargin - minY)
        let lowerCorrection = min(0, availableHeight - verticalMargin - maxY)
        let verticalCorrection = upperCorrection > 0 ? upperCorrection : lowerCorrection

        var horizontalCorrection: CGFloat = 0
        if availableWidth.isFinite {
            let horizontalMargin: CGFloat = 76
            let minX = spaced.map(\.x).min() ?? anchor.x
            let maxX = spaced.map(\.x).max() ?? anchor.x
            let leadingCorrection = max(0, horizontalMargin - minX)
            let trailingCorrection = min(0, availableWidth - horizontalMargin - maxX)
            horizontalCorrection = leadingCorrection > 0 ? leadingCorrection : trailingCorrection
        }

        return spaced.map {
            CGPoint(x: $0.x + horizontalCorrection, y: $0.y + verticalCorrection)
        }
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
        // primary and branch pills.
        let radius: CGFloat = depth == 0 ? Self.primaryRadius : 304 + CGFloat(depth - 1) * 72
        let rowCount = Int(ceil(Double(count) / 2.0))
        let curvatureSpacing = depth == 0 ? curvature * 5 : curvature * 3
        let rowSpacing = minimumItemSpacing(depth: depth, sliderRing: false) + curvatureSpacing
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

    /// One already-placed pill, for scoring deeper ring placements.
    struct PlacedPill {
        let center: CGPoint
        let halfWidth: CGFloat
        let halfHeight: CGFloat

        init(center: CGPoint, halfWidth: CGFloat, halfHeight: CGFloat) {
            self.center = center
            self.halfWidth = halfWidth
            self.halfHeight = halfHeight
        }
    }

    /// Places a branch ring by scoring candidate fan directions — radially
    /// outward first, then progressively rotated, then flat horizontal — and
    /// returning the first with zero overlap against already-placed pills (or
    /// the least overlapping one when a corner genuinely has no clean spot).
    /// A second radius tier jumps the branch outside the ring envelope for
    /// edge-clamped anchors at high curvature, where no nearby direction has
    /// room — the successor of the old far-branch radius.
    func branchPlacement(
        count: Int,
        depth: Int,
        anchor: CGPoint,
        baseAngle: CGFloat,
        prior: [PlacedPill],
        parentPillIndex: Int,
        halfWidth: CGFloat,
        halfHeight: CGFloat,
        sliderRing: Bool = false,
        availableHeight: CGFloat,
        availableWidth: CGFloat = .infinity
    ) -> (positions: [CGPoint], baseAngle: CGFloat, radius: CGFloat) {
        let horizontal: CGFloat = cos(baseAngle) <= 0 ? .pi : 0
        // Interior-facing (mirrored) candidates make the free side reachable
        // when the outward side is pinned against a window edge.
        let mirrored: CGFloat = .pi - horizontal
        let candidates: [CGFloat] = [
            baseAngle, baseAngle - 0.30, baseAngle + 0.30,
            baseAngle - 0.60, baseAngle + 0.60, horizontal,
            mirrored - 0.30, mirrored, mirrored + 0.30
        ]
        let baseRadius = Self.localBranchRadius + CGFloat(depth - 1) * Self.localBranchRadiusStep

        var bestPositions: [CGPoint] = []
        var bestAngle = baseAngle
        var bestRadius = baseRadius
        var bestPenalty = CGFloat.infinity
        outer: for radiusBoost: CGFloat in [0, 132] {
            for candidate in candidates {
                let candidatePositions = positions(
                    count: count,
                    depth: depth,
                    anchor: anchor,
                    availableHeight: availableHeight,
                    localBranch: true,
                    branchBaseAngle: candidate,
                    radiusBoost: radiusBoost,
                    sliderRing: sliderRing,
                    availableWidth: availableWidth
                )
                var penalty: CGFloat = 0
                // Penalize edge clamping: a wholesale horizontal shift collapses
                // the branch onto its parent column, so a genuinely-fitting
                // direction must always beat a clamped one.
                if availableWidth.isFinite {
                    let unclamped = positions(
                        count: count,
                        depth: depth,
                        anchor: anchor,
                        availableHeight: availableHeight,
                        localBranch: true,
                        branchBaseAngle: candidate,
                        radiusBoost: radiusBoost,
                        sliderRing: sliderRing
                    )
                    if let clampedX = candidatePositions.first?.x, let freeX = unclamped.first?.x {
                        penalty += abs(clampedX - freeX) * 30
                    }
                }
                for (index, pill) in prior.enumerated() {
                    // The parent pill tolerates contact with its own children;
                    // everything else keeps a little breathing room.
                    let margin: CGFloat = index == parentPillIndex ? 0 : 2
                    for point in candidatePositions {
                        let overlapX = pill.halfWidth + halfWidth + margin - abs(pill.center.x - point.x)
                        let overlapY = pill.halfHeight + halfHeight + margin - abs(pill.center.y - point.y)
                        if overlapX > 0, overlapY > 0 { penalty += overlapX * overlapY }
                    }
                }
                if penalty < bestPenalty {
                    bestPenalty = penalty
                    bestPositions = candidatePositions
                    bestAngle = candidate
                    bestRadius = baseRadius + radiusBoost
                    if penalty == 0 { break outer }
                }
            }
        }
        return (bestPositions, bestAngle, bestRadius)
    }
}

/// Screen-position anchored, tree-driven launcher for the macOS render view.
///
/// Renders one ring per level of the navigation `path` through `roots`.
/// Radial and grid are peer presentations of `hierarchy`: radial places levels
/// on arcs around the pointer, while grid flattens the same routes into right-
/// edge columns. Hovering a branch pill auto-selects it after a short dwell;
/// only fallback leaves and slider drags perform side effects.
struct MacQuickMenu: View {
    let size: CGSize
    let pointerAnchor: CGPoint
    @Binding var curvature: Double
    let hierarchy: MacNavigationHierarchy
    @Binding var path: [String]
    @Binding var layoutStyle: MacTabLauncherStyle
    let sceneAccent: Color
    /// True while the user shift-peeks at the fractal: the menu stays mounted
    /// but hover must not re-navigate underneath the faded pills.
    let suspendsHoverNavigation: Bool
    @Binding var hoveredSlider: MacQuickActiveSlider?
    let onSliderEditingChanged: (Bool) -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedItemID: String?
    /// The single dwell timer for hover-to-select. One task, not one per pill:
    /// hover exit events can be dropped by the system, so navigation always
    /// reconciles from the most recent hover *enter* instead of enter/exit pairs.
    @State private var pendingHoverSelection: Task<Void, Never>?
    /// Which node scheduled the pending dwell. SwiftUI does not order hover
    /// exit/enter between pills, so only the owning pill's exit may cancel —
    /// a trailing exit from the pill just left must not kill the new dwell.
    @State private var pendingHoverNodeID: String?
    /// The layer currently under the pointer. A receded parent layer returns
    /// to full strength while the user moves back through it.
    @State private var hoveredRingDepth: Int?

    /// Focus identifiers for launcher chrome live outside the hierarchy.
    private enum ChromeFocusID {
        static let radialLayout = "launcher.chrome.layout.radial"
        static let gridLayout = "launcher.chrome.layout.grid"
        static let tighterCurvature = "launcher.chrome.curvature.tighter"
        static let widerCurvature = "launcher.chrome.curvature.wider"
    }

    /// Hovering a branch pill this long commits the selection. Long enough that
    /// sweeping across a pill en route to another does not thrash the deeper
    /// rings, short enough to read as instantaneous when aiming at it.
    private let hoverSelectDwell: Duration = .milliseconds(90)

    private struct RingLayout {
        let depth: Int
        let nodes: [MacNavigationNode]
        let positions: [CGPoint]
        /// Center the ring fans around — the pointer anchor for ring 0, the
        /// pointer anchor shared by all concentric rings. Also the pivot radial
        /// sliders measure drag angles against.
        let anchor: CGPoint
        /// Outward direction the ring fans around (radians, screen coords).
        let baseAngle: CGFloat
        /// Arc radius actually used (branch placement may boost it in corners).
        let radius: CGFloat
    }

    private var anchor: CGPoint {
        Self.resolvedAnchor(size: size, pointerAnchor: pointerAnchor, layoutStyle: layoutStyle)
    }

    private var roots: [MacNavigationNode] {
        hierarchy.presentedRoots(for: layoutStyle)
    }

    private var opensLeft: Bool { anchor.x >= size.width * 0.5 }
    private var bifurcates: Bool {
        guard layoutStyle == .radial else { return false }
        // Enough room for the compact slider ring and its 118pt pill.
        let horizontalClearance: CGFloat = 422
        return anchor.x >= horizontalClearance && anchor.x <= size.width - horizontalClearance
    }

    static let gridAnchorTrailingInset: CGFloat = 22
    static let windowDragHandleSize: CGFloat = 44
    static let gridPrimaryWidth: CGFloat = 166
    static let gridRightInset: CGFloat = 30

    private var gridPrimaryWidth: CGFloat { Self.gridPrimaryWidth }
    private let gridChildWidth: CGFloat = 116
    private let gridSliderWidth: CGFloat = 136
    /// Leave a clear rail for the window-drag hub. The old 6pt inset put the
    /// central primary pill underneath the hub in flattened/grid mode.
    private var gridRightInset: CGFloat { Self.gridRightInset }
    private let radialSliderWidth: CGFloat = 118

    static func resolvedAnchor(
        size: CGSize,
        pointerAnchor: CGPoint,
        layoutStyle: MacTabLauncherStyle
    ) -> CGPoint {
        layoutStyle == .radial
            ? pointerAnchor
            : CGPoint(x: size.width - gridAnchorTrailingInset, y: pointerAnchor.y)
    }

    static func windowDragHandleFrame(
        size: CGSize,
        pointerAnchor: CGPoint,
        layoutStyle: MacTabLauncherStyle
    ) -> CGRect {
        let center = resolvedAnchor(size: size, pointerAnchor: pointerAnchor, layoutStyle: layoutStyle)
        return CGRect(
            x: center.x - windowDragHandleSize * 0.5,
            y: center.y - windowDragHandleSize * 0.5,
            width: windowDragHandleSize,
            height: windowDragHandleSize
        )
    }

    /// Frame of the primary grid pill aligned with the hub's row. Used to keep
    /// the draggable window target geometrically separate from menu controls.
    static func gridCenterPrimaryPillFrame(size: CGSize, pointerAnchor: CGPoint) -> CGRect {
        let center = resolvedAnchor(size: size, pointerAnchor: pointerAnchor, layoutStyle: .grid)
        let centerX = center.x - gridRightInset - gridPrimaryWidth * 0.5
        return CGRect(
            x: centerX - gridPrimaryWidth * 0.5,
            y: center.y - 18,
            width: gridPrimaryWidth,
            height: 36
        )
    }

    /// Grid mode is a right-edge rail: every primary capsule and the toolbar
    /// share this trailing boundary regardless of their label length.
    private var gridPrimaryColumnX: CGFloat {
        anchor.x - gridRightInset - gridPrimaryWidth * 0.5
    }

    var body: some View {
        let rings = ringLayouts()
        let focusOrder = keyboardFocusOrder(rings: rings)

        ZStack {
            if layoutStyle == .radial {
                radialGuide(rings: rings)
                    .allowsHitTesting(false)
            }

            ForEach(rings, id: \.depth) { ring in
                ringView(ring)
            }

            layoutPicker(primaryPositions: rings.first?.positions ?? [])

            anchorMark
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: Self.coordinateSpaceName)
        .onAppear {
            focusedItemID = roots.first(where: \.isSelected)?.id ?? roots.first?.id
        }
        .onDisappear {
            pendingHoverSelection?.cancel()
            pendingHoverSelection = nil
            pendingHoverNodeID = nil
        }
        .onChange(of: suspendsHoverNavigation) { _, suspended in
            // Shift-peek must not let an already-armed dwell re-navigate
            // under the faded pills.
            if suspended {
                pendingHoverSelection?.cancel()
                pendingHoverSelection = nil
                pendingHoverNodeID = nil
            }
        }
        .onChange(of: layoutStyle) { _, style in
            path = hierarchy.reconciledPath(path, for: style)
            if let focusedItemID,
               hierarchy.node(withID: focusedItemID, for: style) == nil {
                self.focusedItemID = roots.first(where: \.isSelected)?.id ?? roots.first?.id
            }
        }
        .onKeyPress(.tab, phases: [.down, .repeat]) { press in
            moveFocus(through: focusOrder, backward: press.modifiers.contains(.shift))
            return .handled
        }
        .onKeyPress(
            keys: [.upArrow, .downArrow, .leftArrow, .rightArrow],
            phases: [.down, .repeat]
        ) { press in
            handleDirectionalKey(press, focusOrder: focusOrder)
        }
        .onKeyPress(keys: [.return, .space], phases: .down) { _ in
            activateFocusedItem()
        }
        .onKeyPress(.escape, phases: .down) { _ in
            retreatOrDismiss()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Control launcher")
    }

    static let coordinateSpaceName = "MacQuickMenu"

    // MARK: Ring layout

    /// Walks `path` through the tree, producing one layout per visible ring.
    /// Radial mode uses true concentric arcs: every level shares the pointer
    /// center and advances by one compact fixed radius. Grid mode retains its
    /// parent-relative column behavior.
    private func ringLayouts() -> [RingLayout] {
        var layouts: [RingLayout] = []
        var nodes = roots
        var ringAnchor = anchor
        var ringBaseAngle: CGFloat = opensLeft ? .pi : 0
        var radialRingRadius = MacRadialTabGeometry.primaryRadius
        var depth = 0

        while !nodes.isEmpty {
            let positions: [CGPoint]
            let isSliderRing = nodes.contains { $0.slider != nil }
            let ringRadius: CGFloat
            let layoutCenter: CGPoint
            var resolvedBaseAngle = ringBaseAngle

            if layoutStyle == .radial {
                layoutCenter = anchor
                ringRadius = radialRingRadius
                if depth == 0 {
                    positions = itemPositions(
                        count: nodes.count,
                        depth: depth,
                        centeredAt: anchor,
                        baseAngle: ringBaseAngle,
                        sliderRing: false
                    )
                } else {
                    let resolved = fittedConcentricPositions(
                        count: nodes.count,
                        radius: ringRadius,
                        baseAngle: ringBaseAngle,
                        sliderRing: isSliderRing,
                        priorLayouts: layouts
                    )
                    positions = resolved.positions
                    resolvedBaseAngle = resolved.baseAngle
                }
            } else {
                layoutCenter = ringAnchor
                ringRadius = MacRadialTabGeometry.primaryRadius
                    + CGFloat(depth) * MacRadialTabGeometry.concentricRingStep
                positions = itemPositions(
                    count: nodes.count,
                    depth: depth,
                    centeredAt: ringAnchor,
                    baseAngle: ringBaseAngle,
                    sliderRing: isSliderRing
                )
            }
            layouts.append(RingLayout(
                depth: depth,
                nodes: nodes,
                positions: positions,
                anchor: layoutCenter,
                baseAngle: resolvedBaseAngle,
                radius: ringRadius
            ))

            guard depth < path.count,
                  let selectedIndex = nodes.firstIndex(where: { $0.id == path[depth] }),
                  nodes[selectedIndex].isBranch,
                  positions.indices.contains(selectedIndex) else { break }

            let pill = positions[selectedIndex]
            // Deeper concentric rings stay in the selected pill's angular
            // sector while retaining the shared pointer center.
            let angleCenter = layoutStyle == .radial ? anchor : ringAnchor
            let dx = pill.x - angleCenter.x
            let dy = pill.y - angleCenter.y
            if dx*dx + dy*dy > 1 {
                if layoutStyle == .radial {
                    // Follow the selected sector, but damp its vertical offset
                    // at each hop. Without this, selecting an upper primary
                    // row centered the entire child arc unnecessarily high.
                    ringBaseAngle = atan2(dy * 0.62, dx)
                } else {
                    ringBaseAngle = atan2(dy, dx)
                }
            }
            if layoutStyle == .radial {
                // The primary fan may be bifurcated and vertically offset, so
                // its pills are not all at `primaryRadius`. Derive the next
                // concentric radius from the tab actually being followed.
                radialRingRadius = hypot(dx, dy) + MacRadialTabGeometry.concentricRingStep
            }
            if layoutStyle == .grid {
                ringAnchor = pill
            }
            nodes = nodes[selectedIndex].presentedChildren(for: layoutStyle)
            depth += 1
        }
        return layouts
    }

    /// Rotates a concentric child arc just enough to remain on-screen and clear
    /// already-visible pills. Radius and center never change, so the hierarchy
    /// retains its concentric character instead of jumping to an unrelated fan.
    private func fittedConcentricPositions(
        count: Int,
        radius: CGFloat,
        baseAngle: CGFloat,
        sliderRing: Bool,
        priorLayouts: [RingLayout]
    ) -> (positions: [CGPoint], baseAngle: CGFloat) {
        let geometry = MacRadialTabGeometry(curvature: CGFloat(curvature))
        let offsets: [CGFloat] = [0, 0.10, -0.10, 0.20, -0.20, 0.32, -0.32]
        let halfWidth: CGFloat = sliderRing ? radialSliderWidth * 0.5 : 52
        let halfHeight: CGFloat = sliderRing ? 17 : 16
        let margin: CGFloat = 12

        func score(_ points: [CGPoint], offset: CGFloat) -> CGFloat {
            var total = abs(offset) * 18
            for point in points {
                let frame = CGRect(
                    x: point.x - halfWidth,
                    y: point.y - halfHeight,
                    width: halfWidth * 2,
                    height: halfHeight * 2
                )
                if frame.minX < margin { total += (margin - frame.minX) * 80 }
                if frame.maxX > size.width - margin { total += (frame.maxX - size.width + margin) * 80 }
                if frame.minY < margin { total += (margin - frame.minY) * 80 }
                if frame.maxY > size.height - margin { total += (frame.maxY - size.height + margin) * 80 }

                for prior in priorLayouts {
                    for (priorIndex, priorPoint) in prior.positions.enumerated() {
                        let isSelectedParent = prior.depth == priorLayouts.last?.depth
                            && path.indices.contains(prior.depth)
                            && prior.nodes.indices.contains(priorIndex)
                            && prior.nodes[priorIndex].id == path[prior.depth]
                        if isSelectedParent { continue }
                        let priorHalfWidth: CGFloat = prior.depth == 0 ? 72 : 52
                        let priorHalfHeight: CGFloat = prior.depth == 0 ? 20 : 16
                        let priorFrame = CGRect(
                            x: priorPoint.x - priorHalfWidth - 4,
                            y: priorPoint.y - priorHalfHeight - 3,
                            width: (priorHalfWidth + 4) * 2,
                            height: (priorHalfHeight + 3) * 2
                        )
                        if frame.intersects(priorFrame) {
                            let overlap = frame.intersection(priorFrame)
                            total += overlap.width * overlap.height
                        }
                    }
                }
            }
            return total
        }

        return offsets
            .map { offset -> (positions: [CGPoint], baseAngle: CGFloat, score: CGFloat) in
                let angle = baseAngle + offset
                let points = geometry.concentricPositions(
                    count: count,
                    anchor: anchor,
                    radius: radius,
                    baseAngle: angle,
                    sliderRing: sliderRing
                )
                return (points, angle, score(points, offset: offset))
            }
            .min(by: { $0.score < $1.score })
            .map { ($0.positions, $0.baseAngle) }
            ?? ([], baseAngle)
    }

    @ViewBuilder
    private func ringView(_ ring: RingLayout) -> some View {
        ForEach(Array(ring.nodes.enumerated()), id: \.element.id) { index, node in
            let position = ring.positions[index]
            let transitionDirection: CGFloat = position.x < anchor.x ? 1 : -1
            let selectedPathID = path.indices.contains(ring.depth) ? path[ring.depth] : nil
            let isSelectedPathNode = selectedPathID == node.id
            let recedesBehindChildRing = selectedPathID != nil
                && !isSelectedPathNode
                && hoveredRingDepth != ring.depth

            Group {
                if let slider = node.slider {
                    let width = layoutStyle == .grid ? gridSliderWidth : radialSliderWidth
                    // Hit frame for the NSEvent monitor's geometric check,
                    // inflated past the pill's hit outset and hover scale.
                    let hitFrame = CGRect(
                        x: position.x - width * 0.5 - 8,
                        y: position.y - 15 - 8,
                        width: width + 16,
                        height: 30 + 16
                    )
                    MacQuickSliderPill(
                        node: node,
                        slider: slider,
                        fixedWidth: width,
                        isFocused: focusedItemID == node.id,
                        sceneAccent: sceneAccent,
                        onHoverChanged: { hovering in
                            updateHoveredRing(ring.depth, hovering: hovering)
                            if hovering {
                                hoveredSlider = MacQuickActiveSlider(id: node.id, frame: hitFrame)
                            } else if hoveredSlider?.id == node.id {
                                hoveredSlider = nil
                            }
                        },
                        onEditingChanged: onSliderEditingChanged
                    )
                    .focusable()
                    .focused($focusedItemID, equals: node.id)
                } else {
                    MacQuickMenuButton(
                        item: node,
                        depth: ring.depth,
                        fixedWidth: layoutStyle == .grid
                            ? (ring.depth == 0 ? gridPrimaryWidth : gridChildWidth)
                            : nil,
                        isFocused: focusedItemID == node.id,
                        retreatDirection: position.x < anchor.x ? -1 : 1,
                        sceneAccent: sceneAccent,
                        onActivate: {
                            // Click (or keyboard activation) on a pure branch
                            // navigates immediately — hover-only switching
                            // would strand click-first and keyboard users.
                            if node.isBranch {
                                commitHoverSelection(node, depth: ring.depth)
                            } else {
                                node.fallbackAction?()
                            }
                        },
                        onHoverChanged: { hovering in
                            updateHoveredRing(ring.depth, hovering: hovering)
                            handleNodeHover(node, depth: ring.depth, hovering: hovering)
                        }
                    )
                    .focused($focusedItemID, equals: node.id)
                }
            }
            // Once this layer opens a child arc, fade its siblings back while
            // keeping the chosen parent fully lit. The resulting bright chain
            // makes the active route through a deep hierarchy immediately clear.
            .opacity(recedesBehindChildRing ? 0.24 : 1)
            .saturation(recedesBehindChildRing ? 0.42 : 1)
            .scaleEffect(recedesBehindChildRing ? 0.97 : 1)
            .position(position)
            .animation(.easeOut(duration: 0.16), value: recedesBehindChildRing)
            .transition(
                .offset(x: transitionDirection * (ring.depth == 0 ? 48 : 62))
                    .combined(with: .scale(scale: 0.82, anchor: .trailing))
                    .combined(with: .opacity)
            )
        }
    }

    // MARK: Hover navigation

    private func updateHoveredRing(_ depth: Int, hovering: Bool) {
        if hovering {
            hoveredRingDepth = depth
        } else if hoveredRingDepth == depth {
            hoveredRingDepth = nil
        }
    }

    /// Hover enter on a branch pill schedules the selection after a dwell.
    /// Leaves never re-navigate on hover — only their own click acts — so a
    /// deeper ring stays open while the pointer visits a sibling leaf.
    private func handleNodeHover(_ node: MacNavigationNode, depth: Int, hovering: Bool) {
        guard hovering else {
            if pendingHoverNodeID == node.id {
                pendingHoverSelection?.cancel()
                pendingHoverSelection = nil
                pendingHoverNodeID = nil
            }
            return
        }
        guard !suspendsHoverNavigation, node.isBranch else { return }
        guard path.count <= depth || path[depth] != node.id else { return }

        pendingHoverSelection?.cancel()
        pendingHoverNodeID = node.id
        // Switching a parent after its child is visible gets a wider intent
        // window. This protects diagonal travel toward the child arc without
        // making first-time branch discovery feel sluggish.
        let dwell: Duration = path.count > depth ? .milliseconds(175) : hoverSelectDwell
        pendingHoverSelection = Task { @MainActor in
            try? await Task.sleep(for: dwell)
            guard !Task.isCancelled else { return }
            pendingHoverNodeID = nil
            commitHoverSelection(node, depth: depth)
        }
    }

    private func commitHoverSelection(_ node: MacNavigationNode, depth: Int) {
        pendingHoverSelection?.cancel()
        pendingHoverSelection = nil
        pendingHoverNodeID = nil
        let newPath = Array(path.prefix(depth)) + [node.id]
        if reduceMotion {
            path = newPath
        } else {
            withAnimation(.easeOut(duration: 0.16)) {
                path = newPath
            }
        }
    }

    private func itemPositions(
        count: Int,
        depth: Int,
        centeredAt layoutAnchor: CGPoint,
        baseAngle: CGFloat,
        radiusBoost: CGFloat = 0,
        sliderRing: Bool = false
    ) -> [CGPoint] {
        switch layoutStyle {
        case .radial:
            // The primary ring is exempt from the width clamp: shifting it
            // would divorce the fan from the anchor mark, guide arc, and
            // picker. Only deep branches near a side edge need rescuing, and
            // their decorations are recomputed from the shifted pills.
            return MacRadialTabGeometry(curvature: CGFloat(curvature)).positions(
                count: count,
                depth: depth,
                anchor: layoutAnchor,
                availableHeight: size.height,
                opensLeft: opensLeft,
                bifurcates: depth == 0 ? bifurcates : false,
                localBranch: depth > 0,
                branchBaseAngle: depth > 0 ? baseAngle : nil,
                radiusBoost: radiusBoost,
                sliderRing: sliderRing,
                availableWidth: depth == 0 ? .infinity : size.width
            )
        case .grid:
            return gridPositions(count: count, depth: depth, centerY: layoutAnchor.y, sliderRing: sliderRing)
        }
    }

    private func gridPositions(count: Int, depth: Int, centerY: CGFloat, sliderRing: Bool = false) -> [CGPoint] {
        guard count > 0 else { return [] }
        let preferredSpacing: CGFloat = depth == 0 ? 44 : (sliderRing ? 40 : 32)
        // The flattened formula list can be longer than a readable radial ring.
        // Tighten only as much as needed to retain every 30pt slider hit target
        // inside the window's 30pt center margins.
        let availableSpan = max(size.height - 60, 0)
        let fittingSpacing = count > 1 ? availableSpan / CGFloat(count - 1) : preferredSpacing
        let minimumSpacing: CGFloat = sliderRing ? 32 : 30
        let spacing = min(preferredSpacing, max(minimumSpacing, fittingSpacing))
        // Columns tighten right-to-left: primary rail, branch column, slider
        // column. Centers keep a ~20pt gutter between capsule edges.
        let columnX: CGFloat
        switch depth {
        case 0: columnX = gridPrimaryColumnX
        case 1: columnX = anchor.x - 252
        default: columnX = anchor.x - 252 - (gridChildWidth + gridSliderWidth) * 0.5 - 20
        }
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

    private func layoutPicker(primaryPositions: [CGPoint]) -> some View {
        HStack(spacing: 3) {
            ForEach(MacTabLauncherStyle.allCases, id: \.self) { style in
                let focusID = layoutFocusID(for: style)
                let isKeyboardFocused = focusedItemID == focusID
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
                            layoutStyle == style || isKeyboardFocused
                                ? Color(red: 0.58, green: 0.13, blue: 0.84).opacity(0.88)
                                : Color.clear,
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    isKeyboardFocused ? sceneAccent.opacity(0.92) : Color.clear,
                                    lineWidth: 1.2
                                )
                        )
                }
                .buttonStyle(.plain)
                .focused($focusedItemID, equals: focusID)
                .help("Use \(style.rawValue.lowercased()) tabs")
            }

            if layoutStyle == .radial {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 1)

                curvatureButton(
                    systemImage: "minus",
                    delta: -0.08,
                    focusID: ChromeFocusID.tighterCurvature
                )
                curvatureButton(
                    systemImage: "plus",
                    delta: 0.08,
                    focusID: ChromeFocusID.widerCurvature
                )
            }
        }
        .padding(3)
        .background(Color(red: 0.055, green: 0.012, blue: 0.09).opacity(0.96), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8))
        .frame(
            width: layoutStyle == .grid ? gridPrimaryWidth : nil,
            alignment: .trailing
        )
        .position(layoutPickerPosition(primaryPositions: primaryPositions))
        .accessibilityLabel("Quick menu layout")
    }

    private func layoutPickerPosition(primaryPositions: [CGPoint]) -> CGPoint {
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

    private func curvatureButton(systemImage: String, delta: Double, focusID: String) -> some View {
        let isKeyboardFocused = focusedItemID == focusID
        return Button {
            withAnimation(.easeOut(duration: 0.14)) {
                curvature = min(max(curvature + delta, 0.35), 1.35)
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 19, height: 22)
                .foregroundStyle(isKeyboardFocused ? Color.white : Color.white.opacity(0.72))
                .background(
                    isKeyboardFocused ? sceneAccent.opacity(0.34) : Color.clear,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .focused($focusedItemID, equals: focusID)
        .help(delta < 0 ? "Tighten radial curvature" : "Open radial curvature")
    }

    private func radialGuide(rings: [RingLayout]) -> some View {
        Canvas { context, _ in
            for ring in rings {
                let radius: CGFloat
                let baseAngles: [CGFloat]
                let halfSweep: CGFloat
                let opacity: Double
                if ring.depth == 0 {
                    radius = ring.radius
                    baseAngles = bifurcates ? [.pi, 0] : [ring.baseAngle]
                    halfSweep = .pi * 0.3
                    opacity = 0.34
                } else {
                    radius = ring.radius
                    baseAngles = [ring.baseAngle]
                    halfSweep = MacRadialTabGeometry.localBranchMaxSpread * 0.5 + 0.16
                    opacity = ring.depth == 1 ? 0.20 : 0.15
                }

                for baseAngle in baseAngles {
                    var path = Path()
                    path.addArc(
                        center: ring.anchor,
                        radius: radius,
                        startAngle: .radians(baseAngle - halfSweep),
                        endAngle: .radians(baseAngle + halfSweep),
                        clockwise: false
                    )
                    context.stroke(
                        path,
                        with: .linearGradient(
                            Gradient(colors: [
                                Color(red: 0.20, green: 0.04, blue: 0.34).opacity(0.10),
                                Color(red: 0.78, green: 0.26, blue: 1.00).opacity(opacity)
                            ]),
                            startPoint: CGPoint(
                                x: ring.anchor.x + cos(baseAngle) * radius,
                                y: ring.anchor.y + sin(baseAngle) * radius
                            ),
                            endPoint: ring.anchor
                        ),
                        style: StrokeStyle(lineWidth: ring.depth == 0 ? 1.2 : 0.8, dash: [2, 7])
                    )
                }
            }

            // A single luminous route makes the selected ancestry legible at
            // a glance. It is static Canvas geometry—no blur and no timeline.
            let selectedPoints = rings.compactMap { ring -> CGPoint? in
                guard path.indices.contains(ring.depth),
                      let index = ring.nodes.firstIndex(where: { $0.id == path[ring.depth] }),
                      ring.positions.indices.contains(index) else { return nil }
                return ring.positions[index]
            }
            if !selectedPoints.isEmpty {
                var route = Path()
                route.move(to: anchor)
                for point in selectedPoints {
                    route.addLine(to: point)
                }
                context.stroke(
                    route,
                    with: .linearGradient(
                        Gradient(colors: [
                            sceneAccent.opacity(0.16),
                            sceneAccent.opacity(0.78),
                            Color.white.opacity(0.72)
                        ]),
                        startPoint: anchor,
                        endPoint: selectedPoints.last ?? anchor
                    ),
                    style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round)
                )
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
        .frame(width: Self.windowDragHandleSize, height: Self.windowDragHandleSize)
        .contentShape(Circle())
        .gesture(WindowDragGesture())
        .position(anchor)
        .help("Drag to move the window")
        .accessibilityElement()
        .accessibilityLabel("Window drag handle")
        .accessibilityHint("Drag to move the Threshold window")
    }

    // MARK: Keyboard navigation

    /// Rectangle mode is intentionally flattened for keyboard traversal. Its
    /// preorder contains every node in the tree, and focusing a deep target
    /// reveals the ancestor columns needed to put that control on screen. The
    /// radial fan keeps its spatial, currently-visible ring order.
    private func keyboardFocusOrder(rings: [RingLayout]) -> [MacNavigationKeyboardTarget] {
        let flattened = hierarchy.flattenedKeyboardTargets(for: layoutStyle)
        let nodeTargets: [MacNavigationKeyboardTarget]
        if layoutStyle == .grid {
            nodeTargets = flattened
        } else {
            let targetsByID = Dictionary(uniqueKeysWithValues: flattened.map { ($0.id, $0) })
            nodeTargets = rings.flatMap(\.nodes).compactMap { targetsByID[$0.id] }
        }

        let chromeTargets = chromeFocusIDs.map {
            MacNavigationKeyboardTarget(id: $0, ancestorPath: [])
        }
        return nodeTargets + chromeTargets
    }

    private var chromeFocusIDs: [String] {
        var ids = [ChromeFocusID.radialLayout, ChromeFocusID.gridLayout]
        if layoutStyle == .radial {
            ids += [ChromeFocusID.tighterCurvature, ChromeFocusID.widerCurvature]
        }
        return ids
    }

    private func layoutFocusID(for style: MacTabLauncherStyle) -> String {
        switch style {
        case .radial: ChromeFocusID.radialLayout
        case .grid: ChromeFocusID.gridLayout
        }
    }

    private func moveFocus(through targets: [MacNavigationKeyboardTarget], backward: Bool) {
        guard let nextID = MacNavigationKeyboardTraversal.nextID(
            from: focusedItemID,
            in: targets,
            backward: backward
        ) else { return }
        focusKeyboardTarget(nextID)
    }

    private func focusKeyboardTarget(_ id: String) {
        if layoutStyle == .grid,
           let target = hierarchy.flattenedKeyboardTargets(for: .grid).first(where: { $0.id == id }) {
            setNavigationPath(target.ancestorPath)
        }
        focusedItemID = id
    }

    private func handleDirectionalKey(
        _ press: KeyPress,
        focusOrder: [MacNavigationKeyboardTarget]
    ) -> KeyPress.Result {
        switch press.key {
        case .upArrow:
            moveFocus(through: focusOrder, backward: true)
            return .handled
        case .downArrow:
            moveFocus(through: focusOrder, backward: false)
            return .handled
        case .leftArrow:
            if let slider = focusedNode?.slider {
                slider.step(by: -1)
            } else {
                retreatOrDismiss()
            }
            return .handled
        case .rightArrow:
            if let slider = focusedNode?.slider {
                slider.step(by: 1)
                return .handled
            }
            return expandFocusedBranch() ? .handled : .ignored
        default:
            return .ignored
        }
    }

    private var focusedNode: MacNavigationNode? {
        guard let focusedItemID else { return nil }
        return hierarchy.node(withID: focusedItemID, for: layoutStyle)
    }

    private func activateFocusedItem() -> KeyPress.Result {
        guard let focusedItemID else { return .ignored }

        switch focusedItemID {
        case ChromeFocusID.radialLayout:
            layoutStyle = .radial
            return .handled
        case ChromeFocusID.gridLayout:
            layoutStyle = .grid
            return .handled
        case ChromeFocusID.tighterCurvature:
            curvature = min(max(curvature - 0.08, 0.35), 1.35)
            return .handled
        case ChromeFocusID.widerCurvature:
            curvature = min(max(curvature + 0.08, 0.35), 1.35)
            return .handled
        default:
            break
        }

        guard let node = hierarchy.node(withID: focusedItemID, for: layoutStyle) else { return .ignored }
        if node.slider != nil {
            // Sliders use Left/Right for adjustment. Consuming activation avoids
            // Space falling through to viewport playback while a slider owns focus.
            return .handled
        }
        if expandFocusedBranch() { return .handled }
        if let action = node.fallbackAction {
            action()
            return .handled
        }
        return .ignored
    }

    /// Right Arrow (or activation of a branch) descends through the same quick
    /// inputs that pointer users reveal by hovering.
    @discardableResult
    private func expandFocusedBranch() -> Bool {
        guard let focusedItemID,
              let node = hierarchy.node(withID: focusedItemID, for: layoutStyle),
              node.isBranch,
              let target = hierarchy.flattenedKeyboardTargets(for: layoutStyle)
                .first(where: { $0.id == focusedItemID })
        else { return false }

        setNavigationPath(target.ancestorPath + [node.id])
        if let firstChild = node.children.first {
            self.focusedItemID = firstChild.id
        }
        return true
    }

    private func retreatOrDismiss() {
        if let focusedItemID,
           let target = hierarchy.flattenedKeyboardTargets(for: layoutStyle)
            .first(where: { $0.id == focusedItemID }),
           let parentID = target.ancestorPath.last {
            setNavigationPath(Array(target.ancestorPath.dropLast()))
            self.focusedItemID = parentID
            return
        }

        if let parentID = path.last {
            setNavigationPath(Array(path.dropLast()))
            focusedItemID = parentID
        } else {
            onDismiss()
        }
    }

    private func setNavigationPath(_ newPath: [String]) {
        guard path != newPath else { return }
        if reduceMotion {
            path = newPath
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                path = newPath
            }
        }
    }
}

private struct MacQuickMenuButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let item: MacNavigationNode
    let depth: Int
    let fixedWidth: CGFloat?
    let isFocused: Bool
    let retreatDirection: CGFloat
    let sceneAccent: Color
    let onActivate: () -> Void
    let onHoverChanged: (Bool) -> Void

    @State private var isHovering = false
    @State private var hoverOffset: CGFloat = 0
    @State private var hoverSequence = 0
    @State private var shimmerProgress: CGFloat = -1

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
        Button(action: onActivate) {
            HStack(spacing: depth == 0 ? 7 : 6) {
                Image(systemName: item.systemImage)
                    .font(.system(size: depth == 0 ? 12 : 10.5, weight: .semibold))
                    .frame(width: depth == 0 ? 16 : 13)
                    .symbolEffect(
                        .wiggle.wholeSymbol,
                        options: .repeat(.periodic(delay: wiggleDelay)).speed(0.52),
                        isActive: shouldWiggle
                    )

                Text(item.title)
                    .font(.system(size: depth == 0 ? 11.5 : 10, weight: isEmphasized ? .bold : .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if item.isSelected {
                    Circle()
                        .fill(Color(red: 0.96, green: 0.74, blue: 1.00))
                        .frame(width: 5, height: 5)
                        .shadow(color: .purple, radius: 5)
                }

                // Branch pills advertise that hovering opens a deeper ring.
                if item.isBranch {
                    Image(systemName: "chevron.compact.right")
                        .font(.system(size: depth == 0 ? 10 : 8, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.38))
                }
            }
            .padding(.horizontal, depth == 0 ? 11 : 8)
            .frame(height: depth == 0 ? 36 : 28)
            .frame(
                minWidth: fixedWidth ?? (depth == 0 ? 116 : 84),
                idealWidth: fixedWidth ?? (depth == 0 ? 128 : 92),
                maxWidth: fixedWidth ?? (depth == 0 ? 140 : 100),
                alignment: .leading
            )
            .background(tabFill, in: Capsule())
            .overlay(
                Capsule()
                    .inset(by: 1)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.24), Color.clear, sceneAccent.opacity(0.16)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.7
                    )
            )
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
        .shadow(color: isEmphasized ? Color.white.opacity(0.34) : .clear, radius: 2.5)
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
            onHoverChanged(hovering)
            hoverSequence &+= 1
            let sequence = hoverSequence

            if hovering && !reduceMotion {
                shimmerProgress = -1
                withAnimation(.linear(duration: 0.92).repeatForever(autoreverses: false)) {
                    shimmerProgress = 1
                }
            } else {
                shimmerProgress = -1
            }

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
        .help(item.isBranch
            ? "\(item.title): press Right Arrow to reveal its controls"
            : item.title)
        .accessibilityHint(item.isBranch
            ? "Press Right Arrow or Return to reveal child controls."
            : item.fallbackAction != nil
                ? "Press Return to open the full controls for this section."
                : "Use the available quick control.")
        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
    }

    private var tabFill: LinearGradient {
        let depthLift = min(CGFloat(depth) * 0.025, 0.07)
        return LinearGradient(
            colors: isEmphasized
                ? [
                    Color(red: 0.08 + depthLift, green: 0.012, blue: 0.15 + depthLift).opacity(0.99),
                    Color(red: 0.38 + depthLift, green: 0.055, blue: 0.60 + depthLift).opacity(0.98),
                    sceneAccent.opacity(0.94)
                ]
                : [
                    Color(red: 0.035 + depthLift, green: 0.008, blue: 0.075 + depthLift).opacity(0.97),
                    Color(red: 0.18 + depthLift, green: 0.025, blue: 0.31 + depthLift).opacity(0.95)
                ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    @ViewBuilder
    private var shimmerOverlay: some View {
        if isHovering {
            GeometryReader { proxy in
                let bandWidth = max(30, proxy.size.width * 0.22)
                let travel = proxy.size.width + bandWidth * 2

                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.white.opacity(0.08),
                        sceneAccent.opacity(0.90),
                        Color.white.opacity(0.16),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: bandWidth, height: proxy.size.height * 2.2)
                .rotationEffect(.degrees(18))
                .offset(
                    x: -bandWidth + travel * ((shimmerProgress + 1) * 0.5),
                    y: -proxy.size.height * 0.6
                )
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

/// Terminal-ring slider pill. Horizontal drag follows the conventional slider
/// direction — right increases, left decreases — while trackpad scroll remains
/// available for fine adjustment.
///
/// Static gradients + a proportional fill only — same performance contract as
/// the tab pills: no blur, no control-tree mount, nothing re-rendering the
/// Metal view underneath.
private struct MacQuickSliderPill: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let node: MacNavigationNode
    let slider: MacQuickSliderBinding
    let fixedWidth: CGFloat
    let isFocused: Bool
    let sceneAccent: Color
    let onHoverChanged: (Bool) -> Void
    let onEditingChanged: (Bool) -> Void

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragStartValue: Float = 0

    /// Horizontal points that sweep the complete value range.
    private let fullRangeTravel: CGFloat = 180

    private var isEnabled: Bool { slider.isEnabled() }
    private var isEmphasized: Bool { isFocused || (isEnabled && (isHovering || isDragging)) }

    var body: some View {
        let value = slider.read()
        let normalized = CGFloat(slider.normalized(value))
        let enabled = isEnabled

        sliderInteractions(
            chrome(value: value, normalized: normalized),
            formattedValue: slider.format(value),
            isEnabled: enabled
        )
        .opacity(enabled ? 1 : 0.42)
        .saturation(enabled ? 1 : 0.18)
        .animation(.easeOut(duration: 0.12), value: enabled)
    }

    /// Break the large SwiftUI expression at a concrete type boundary. This
    /// transient overlay has only a few pills, while the boundary keeps Xcode's
    /// type checker from expanding its modifier tree exponentially.
    private func chrome(value: Float, normalized: CGFloat) -> AnyView {
        AnyView(pillChrome(pillLabel(value: value), normalized: normalized))
    }

    private func pillLabel(value: Float) -> some View {
        HStack(spacing: 7) {
            Image(systemName: node.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 14)

            Text(node.title)
                .font(.system(size: 10.5, weight: isEmphasized ? .bold : .semibold))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 3)

            Text(slider.format(value))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(isEmphasized ? sceneAccent : Color.white.opacity(0.62))
        }
    }

    private func pillChrome<Content: View>(
        _ content: Content,
        normalized: CGFloat
    ) -> some View {
        content
        .padding(.horizontal, 10)
        .frame(width: fixedWidth, height: 30, alignment: .leading)
        .background(
            gaugeBackground(normalized: normalized)
                .clipShape(Capsule())
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    isEmphasized ? sceneAccent.opacity(0.78) : Color.white.opacity(0.10),
                    lineWidth: isEmphasized ? 1.2 : 0.8
                )
        )
        .foregroundStyle(isEmphasized ? Color.white : Color.white.opacity(0.72))
        .shadow(
            color: isEmphasized ? sceneAccent.opacity(0.38) : Color.black.opacity(0.28),
            radius: isEmphasized ? 9 : 4,
            x: 0,
            y: 2
        )
        .scaleEffect(isEmphasized && !reduceMotion ? 1.03 : 1)
        .animation(.easeOut(duration: 0.12), value: isEmphasized)
    }

    private func sliderInteractions(
        _ content: AnyView,
        formattedValue: String,
        isEnabled: Bool
    ) -> AnyView {
        AnyView(
            content
                .contentShape(Capsule().inset(by: -2))
                .gesture(dragGesture, including: isEnabled ? .all : .none)
                .onHover { hovering in
                    updateHover(isEnabled && hovering)
                }
                .onDisappear(perform: resetInteractionState)
                .onChange(of: isEnabled) { _, enabled in
                    if !enabled { resetInteractionState() }
                }
                .help(isEnabled
                    ? "\(node.title): use Left/Right, drag, or scroll to adjust"
                    : "\(node.title) is unavailable")
                .accessibilityElement()
                .accessibilityLabel(node.title)
                .accessibilityValue(isEnabled ? formattedValue : "\(formattedValue), unavailable")
                .accessibilityHint(isEnabled
                    ? "Use Left or Right, drag, scroll, or accessibility adjustment actions to change the value."
                    : "This setting is currently unavailable.")
                .accessibilityAdjustableAction { direction in
                    slider.step(by: direction == .increment ? 1 : -1)
                }
        )
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(MacQuickMenu.coordinateSpaceName))
            .onChanged { gesture in
                guard slider.isEnabled() else { return }
                if !isDragging {
                    isDragging = true
                    dragStartValue = slider.read()
                    onEditingChanged(true)
                }
                slider.writeIfEnabled(slider.value(
                    startingAt: dragStartValue,
                    horizontalTranslation: gesture.translation.width,
                    fullRangeTravel: fullRangeTravel
                ))
            }
            .onEnded { _ in
                isDragging = false
                onEditingChanged(false)
            }
    }

    private func gaugeBackground(normalized: CGFloat) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: [
                        Color(red: 0.055, green: 0.012, blue: 0.09).opacity(0.96),
                        Color(red: 0.25, green: 0.04, blue: 0.38).opacity(0.94)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                // Proportional value fill — the pill IS the gauge.
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.45, green: 0.08, blue: 0.67).opacity(0.55),
                                sceneAccent.opacity(isEmphasized ? 0.62 : 0.38)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(proxy.size.width * normalized, normalized > 0 ? 6 : 0))
            }
        }
    }

    private func resetInteractionState() {
        // A branch switch can unmount mid-drag; never leave the menu
        // adjustment bracket open.
        if isDragging {
            isDragging = false
            onEditingChanged(false)
        }
        if isHovering {
            onHoverChanged(false)
        }
    }

    private func updateHover(_ hovering: Bool) {
        let resolved = slider.isEnabled() && hovering
        isHovering = resolved
        onHoverChanged(resolved)
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
    /// Whether the given AppKit locationInWindow rests on a radial slider
    /// pill. Scroll then adjusts that slider instead of accumulating toward
    /// swipe-dismiss, and double-clicks pass through so a quick re-grab of
    /// the slider works. Takes the location so the check stays geometric — a
    /// hover id whose exit event was dropped must not keep matching.
    let isPointerOverSlider: (CGPoint) -> Bool
    /// Keeps double-click dismissal from swallowing the drag hub's second
    /// mouse-down before WindowDragGesture can take ownership.
    let isPointerOverWindowDragHandle: (CGPoint) -> Bool
    /// Physical-up-positive scroll delta to apply to the hovered slider.
    let onSliderScroll: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isPressed: $isPressed,
            isRadialVisible: isRadialVisible,
            onMouseMoved: onMouseMoved,
            onTwoFingerSwipeUp: onTwoFingerSwipeUp,
            onDoubleClick: onDoubleClick,
            isPointerOverSlider: isPointerOverSlider,
            isPointerOverWindowDragHandle: isPointerOverWindowDragHandle,
            onSliderScroll: onSliderScroll
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
        context.coordinator.isPointerOverSlider = isPointerOverSlider
        context.coordinator.isPointerOverWindowDragHandle = isPointerOverWindowDragHandle
        context.coordinator.onSliderScroll = onSliderScroll
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
        var isPointerOverSlider: (CGPoint) -> Bool
        var isPointerOverWindowDragHandle: (CGPoint) -> Bool
        var onSliderScroll: (CGFloat) -> Void
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
            onDoubleClick: @escaping () -> Void,
            isPointerOverSlider: @escaping (CGPoint) -> Bool,
            isPointerOverWindowDragHandle: @escaping (CGPoint) -> Bool,
            onSliderScroll: @escaping (CGFloat) -> Void
        ) {
            self.isPressed = isPressed
            self.isRadialVisible = isRadialVisible
            self.onMouseMoved = onMouseMoved
            self.onTwoFingerSwipeUp = onTwoFingerSwipeUp
            self.onDoubleClick = onDoubleClick
            self.isPointerOverSlider = isPointerOverSlider
            self.isPointerOverWindowDragHandle = isPointerOverWindowDragHandle
            self.onSliderScroll = onSliderScroll
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
                        // A double-click on an interactive drag target is a quick
                        // re-grab, not a dismissal — let it start the second drag.
                        if isPointerOverSlider(event.locationInWindow)
                            || isPointerOverWindowDragHandle(event.locationInWindow) {
                            return event
                        }
                        onDoubleClick()
                        return nil
                    }
                    onMouseMoved(event.locationInWindow)
                } else if event.type == .scrollWheel {
                    guard isRadialVisible else {
                        resetSwipeTracking()
                        return event
                    }

                    // Normalize away the user's natural-scrolling preference so
                    // scrolling stays a physical finger gesture: up = adjust
                    // up / dismiss, regardless of the system setting.
                    let upwardDelta = event.isDirectionInvertedFromDevice
                        ? -event.scrollingDeltaY
                        : event.scrollingDeltaY

                    if isPointerOverSlider(event.locationInWindow) {
                        resetSwipeTracking()
                        if upwardDelta != 0 { onSliderScroll(upwardDelta) }
                        return nil
                    }

                    guard event.hasPreciseScrollingDeltas else { return event }

                    if event.phase == .began {
                        resetSwipeTracking()
                    }

                    // Opposite travel drains the gesture instead of letting a
                    // jittery reversal dismiss the launcher accidentally.
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
